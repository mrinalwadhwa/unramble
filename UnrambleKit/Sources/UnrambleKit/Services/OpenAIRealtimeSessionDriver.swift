import Foundation

/// Client-side orchestration of one Realtime dictation session over an injected
/// send/receive pair. Streams audio to the commit session, reads and applies
/// server events, and drives the finish and same-connection polish sequence.
/// Every function is stateless and takes the `OpenAIRealtimeCommitSession` actor
/// plus the transport closures, so it drives a live socket or an in-memory
/// exchange identically.
enum OpenAIRealtimeSessionDriver {

    static func sendRealtimeAudio(
        _ pcm16k: Data,
        session: OpenAIRealtimeCommitSession,
        send: @escaping @Sendable (String) async throws -> Void,
        eventID: @escaping @Sendable () -> String = { UUID().uuidString },
        onAppendSent: (@Sendable (Int, Int) -> Void)? = nil,
        onCommitSent: (@Sendable () -> Void)? = nil
    ) async throws {
        guard !pcm16k.isEmpty else { return }
        var ownsTransportTurn = false
        do {
            guard pcm16k.count.isMultiple(of: MemoryLayout<Int16>.size) else {
                _ = try await session.appendSucceeded(
                    byteCount: pcm16k.count,
                    containsSpeech: false)
                return
            }
            try await session.acquireTransportTurn()
            ownsTransportTurn = true
            try Task.checkCancellation()

            var offset = 0
            while offset < pcm16k.count {
                let requested = pcm16k.count - offset
                let appendCount = try await session.maximumAppendByteCount(
                    requested: requested)
                if appendCount == 0 {
                    try await submitBufferedAudio(
                        session: session,
                        force: false,
                        send: send,
                        eventID: eventID,
                        onAppendSent: onAppendSent,
                        onCommitSent: onCommitSent)
                    continue
                }

                let source = pcm16k.subdata(
                    in: offset..<(offset + appendCount))
                let pcm24k = try await session.resampleForAppend(source)
                try await send(
                    OpenAIRealtimeWireCodec.buildAudioAppend(
                        pcm24k: pcm24k,
                        eventID: eventID()))
                try Task.checkCancellation()
                onAppendSent?(appendCount, pcm24k.count)
                let trailingSilenceByteCount =
                    AudioLevelAnalyzer.trailingSilenceByteCount(
                        pcm16: source,
                        threshold: OpenAIStreamingProvider.pauseSilenceThreshold)
                let shouldCommit = try await session.appendSucceeded(
                    byteCount: appendCount,
                    trailingSilenceByteCount: trailingSilenceByteCount)
                offset += appendCount

                if shouldCommit {
                    try await submitBufferedAudio(
                        session: session,
                        force: false,
                        send: send,
                        eventID: eventID,
                        onAppendSent: onAppendSent,
                        onCommitSent: onCommitSent)
                }
            }
            await session.releaseTransportTurn()
        } catch {
            await session.fail(error)
            if ownsTransportTurn {
                await session.releaseTransportTurn()
            }
            throw error
        }
    }

    static func finishRealtimeSession(
        session: OpenAIRealtimeCommitSession,
        send: @escaping @Sendable (String) async throws -> Void,
        eventID: @escaping @Sendable () -> String = { UUID().uuidString },
        onAppendSent: (@Sendable (Int, Int) -> Void)? = nil,
        onCommitSent: (@Sendable () -> Void)? = nil,
        onEvidence: OpenAIStreamingProvider.EvidenceObserver? = nil
    ) async throws -> String {
        let result = try await finishRealtimeSessionResult(
            session: session,
            send: send,
            eventID: eventID,
            includeEvidence: onEvidence != nil,
            onAppendSent: onAppendSent,
            onCommitSent: onCommitSent)
        try await notifyEvidenceObserver(onEvidence, evidence: result.evidence)
        return result.response
    }

    static func notifyEvidenceObserver(
        _ observer: OpenAIStreamingProvider.EvidenceObserver?,
        evidence: OpenAIRealtimeCommitSession.EvidenceSnapshot?
    ) async throws {
        if let observer, let evidence {
            await observer(evidence)
        }
        try Task.checkCancellation()
    }

    static func finishRealtimeSessionResult(
        session: OpenAIRealtimeCommitSession,
        send: @escaping @Sendable (String) async throws -> Void,
        eventID: @escaping @Sendable () -> String = { UUID().uuidString },
        includeEvidence: Bool = false,
        onAppendSent: (@Sendable (Int, Int) -> Void)? = nil,
        onCommitSent: (@Sendable () -> Void)? = nil
    ) async throws -> OpenAIStreamingProvider.RealtimeFinishResult {
        var ownsTransportTurn = false
        do {
            try await session.acquireTransportTurn()
            ownsTransportTurn = true
            try Task.checkCancellation()
            try await submitBufferedAudio(
                session: session,
                force: true,
                send: send,
                eventID: eventID,
                onAppendSent: onAppendSent,
                onCommitSent: onCommitSent)
            try await session.sealCapture()
            let transcript = try await session.waitForRawTranscript()
            let evidence = includeEvidence
                ? try await session.resolvedEvidenceSnapshot() : nil
            if transcript.isEmpty {
                await session.releaseTransportTurn()
                return OpenAIStreamingProvider.RealtimeFinishResult(
                    response: "",
                    evidence: evidence)
            }

            try await session.beginPolish()
            try await send(
                OpenAIRealtimeWireCodec.buildPolishRequest(
                    transcript: transcript,
                    eventID: eventID()))
            try await send(OpenAIRealtimeWireCodec.buildResponseCreate(eventID: eventID()))
            let response = try await session.waitForPolishedResponse()
            let validatedResponse = validatedRealtimePolish(
                response,
                rawTranscript: transcript)
            await session.releaseTransportTurn()
            return OpenAIStreamingProvider.RealtimeFinishResult(
                response: validatedResponse,
                evidence: evidence)
        } catch {
            await session.fail(error)
            if ownsTransportTurn {
                await session.releaseTransportTurn()
            }
            throw error
        }
    }

    /// Reject a same-connection polish that drops, invents, or truncates
    /// dictated content. The commit session's ordered transcript is the
    /// fidelity source of truth, so every failed guard returns it unchanged.
    static func validatedRealtimePolish(
        _ polished: String,
        rawTranscript: String
    ) -> String {
        guard !rawTranscript.isEmpty else { return polished }
        let candidate = polished.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            Log.debug(
                "[REALTIME_POLISH_RAW_FALLBACK] empty polished response")
            return rawTranscript
        }

        let guardFires = PolishPipeline.guardAgainstHallucination(
                polished: candidate,
                preprocessed: rawTranscript) != nil
            || PolishPipeline.guardAgainstTruncation(
                polished: candidate,
                preprocessed: rawTranscript) != nil
            || PolishPipeline.guardAgainstContentLoss(
                polished: candidate,
                preprocessed: rawTranscript) != nil
            || PolishPipeline.guardAgainstFabrication(
                polished: candidate,
                preprocessed: rawTranscript) != nil
            // A substituted number is the costliest fidelity failure. The
            // check compares numeric values, so a faithful digitization
            // ("five" -> "5") passes and only a real substitution (a value
            // dropped while another is invented) falls back to the transcript.
            || PolishPipeline.guardAgainstNumberChange(
                polished: candidate,
                preprocessed: rawTranscript) != nil
        if guardFires {
            Log.debug(
                "[REALTIME_POLISH_RAW_FALLBACK] fidelity guard rejected polish")
            return rawTranscript
        }
        return candidate
    }

    static func readRealtimeSessionEvents(
        session: OpenAIRealtimeCommitSession,
        receive: @escaping @Sendable () async throws -> String,
        onTranscriptCompleted: (@Sendable (String) -> Void)? = nil,
        onFirstResponseDelta: (@Sendable () -> Void)? = nil
    ) async throws {
        do {
            while true {
                try Task.checkCancellation()
                switch OpenAIRealtimeWireCodec.parseEvent(try await receive()) {
                case .transcription(let event):
                    try await session.apply(event)
                    if case .completed(_, _, _, let transcript) = event {
                        onTranscriptCompleted?(transcript)
                    }
                case .responseTextDelta(
                    let outputIndex,
                    let contentIndex,
                    let delta):
                    if try await session.appendResponseDelta(
                        delta,
                        outputIndex: outputIndex,
                        contentIndex: contentIndex)
                    {
                        onFirstResponseDelta?()
                    }
                case .responseTextDone(
                    let outputIndex,
                    let contentIndex,
                    let text):
                    try await session.completeResponseText(
                        text,
                        outputIndex: outputIndex,
                        contentIndex: contentIndex)
                case .responseDone:
                    try await session.completeResponse()
                    return
                case .error(let message):
                    throw DictationError.networkError(
                        "Realtime API error: \(message)")
                case .serverError(let error):
                    throw DictationError.networkError(
                        "Realtime API error: \(error.diagnosticMessage)")
                case .protocolError(let message):
                    throw DictationError.networkError(
                        "Realtime protocol error: \(message)")
                case .transcriptionDelta, .other:
                    continue
                }
            }
        } catch {
            await session.fail(error)
            throw error
        }
    }

    static func withRealtimeSessionTimeout<Value: Sendable>(
        seconds: TimeInterval,
        waitingFor description: String,
        session: OpenAIRealtimeCommitSession,
        onTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        precondition(seconds > 0 && seconds.isFinite)
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(seconds * 1_000_000_000))
                let error = DictationError.networkError(
                    "Timed out waiting for \(description)"
                        + " after \(Int(seconds))s")
                await session.fail(error)
                await onTimeout()
                throw error
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw DictationError.networkError(
                    "No result while waiting for \(description)")
            }
            return result
        }
    }

    private static func submitBufferedAudio(
        session: OpenAIRealtimeCommitSession,
        force: Bool,
        send: @escaping @Sendable (String) async throws -> Void,
        eventID: @escaping @Sendable () -> String,
        onAppendSent: (@Sendable (Int, Int) -> Void)?,
        onCommitSent: (@Sendable () -> Void)?
    ) async throws {
        while true {
            switch try await session.prepareCommit(force: force) {
            case .noAudio:
                return
            case .blocked:
                try await session.waitForCommitCapacity()
            case .ready(let commit):
                let tail = try await session.finishResamplingForCommit()
                if !tail.isEmpty {
                    try await send(
                        OpenAIRealtimeWireCodec.buildAudioAppend(
                            pcm24k: tail,
                            eventID: eventID()))
                    onAppendSent?(0, tail.count)
                }
                try await send(OpenAIRealtimeWireCodec.buildCommit(eventID: eventID()))
                onCommitSent?()
                try await session.waitForAcknowledgement(
                    sequence: commit.sequence)
                try Task.checkCancellation()
                return
            }
        }
    }
}
