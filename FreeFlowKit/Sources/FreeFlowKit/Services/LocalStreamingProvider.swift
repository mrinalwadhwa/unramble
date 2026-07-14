import Foundation

/// On-device streaming dictation that assembles one final transcript.
///
/// Accumulate PCM audio during recording and feed each new slice to one
/// incremental recognition session. Every `cycleInterval` seconds, decide
/// whether the current unit has ended — an acoustic pause or a size cap, per
/// `LocalUnitPolicy` — and if so polish that unit and append it to an internal
/// transcript. Nothing is injected mid-stream; `finishStreaming` closes the
/// final unit and returns the whole polished transcript for one injection.
///
/// A pause bounds each unit so the polish model sees short input and stays
/// faithful. A chunk handler, if set, mirrors each closed unit for a preview
/// but never changes what `finishStreaming` returns.
public final class LocalStreamingProvider: StreamingDictationProviding,
    @unchecked Sendable
{

    // MARK: - Configuration

    private let sttEngine: any LocalStreamingRecognizer
    private let loadSTT: @Sendable () async throws -> Void
    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String
    private let cycleInterval: TimeInterval
    private let unitPolicy: LocalUnitPolicy
    private let silenceThreshold: Float

    // MARK: - State (guarded by lock)

    private let lock = NSLock()
    private var accumulatedAudio = Data()
    private var currentContext: AppContext = .empty

    private var rawTranscript = ""

    /// Raw STT transcript from the last `finishStreaming()` call.
    public var lastRawTranscript: String {
        lock.withLock { rawTranscript }
    }

    private var polishedTranscript = ""

    /// Full polished transcript (committed chunks plus final tail) from
    /// the last `finishStreaming()` call. Useful for diagnostics and
    /// sample collection even when `finishStreaming` returns only the
    /// tail because chunks were injected live.
    public var lastPolishedTranscript: String {
        lock.withLock { polishedTranscript }
    }

    /// Audio byte offset where the current, not-yet-closed unit began.
    private var unitStartByte = 0

    /// Running count of trailing silence bytes at the live edge. A long
    /// enough run closes the current unit.
    private var trailingSilenceBytes = 0

    /// The recognition transcript already turned into closed units.
    private var committedTranscript = ""

    /// Incremental transcription session for the current dictation.
    private var recognitionSession: (any LocalRecognitionSession)?

    /// The first incremental feed failure. A feed can partially mutate model
    /// state, so it is terminal and must never be retried on the same session.
    private var recognitionError: (any Error)?

    /// Identifies the current recognition session across async cycle work.
    private var sessionGeneration: UInt64 = 0

    /// Bytes of accumulated audio already fed to the streaming session.
    private var fedBytes = 0

    /// Accumulated polished text for all committed sentences. Used as
    /// preceding context for later chunks and as the full result when no
    /// chunk handler is set.
    private var committedPolished = ""

    /// Receives each committed chunk's polished text for live injection.
    private var chunkHandler: (@Sendable (String) async -> Void)?

    private struct Finalization {
        let id: UUID
        let generation: UInt64
        let task: Task<String, Error>
    }

    private struct FinishSnapshot {
        let audio: Data
        let context: AppContext
        let committed: String
        let committedTranscript: String
        let recognitionError: (any Error)?
        let session: (any LocalRecognitionSession)?
        let newAudio: Data
        let fedEnd: Int
    }

    private var finishing = false
    private var cancelling = false
    private var backgroundTask: Task<Void, Never>?
    private var finalization: Finalization?

    // MARK: - Init

    public init(
        sttEngine: any LocalStreamingRecognizer,
        polishChatClient: (any PolishChatClient)?,
        polishModel: String = PolishPipeline.polishModel,
        cycleInterval: TimeInterval = 3,
        unitPolicy: LocalUnitPolicy = LocalUnitPolicy(),
        silenceThreshold: Float? = nil,
        loadSTT: (@Sendable () async throws -> Void)? = nil
    ) {
        self.sttEngine = sttEngine
        self.loadSTT = loadSTT ?? { try await sttEngine.load() }
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
        self.cycleInterval = cycleInterval
        self.unitPolicy = unitPolicy
        self.silenceThreshold = silenceThreshold
            ?? AudioLevelAnalyzer.minimumAcceptedSpeechRMS
    }

    // MARK: - StreamingDictationProviding

    public func setChunkHandler(
        _ handler: (@Sendable (String) async -> Void)?
    ) {
        lock.withLock { chunkHandler = handler }
    }

    public func startStreaming(
        context: AppContext, language: String?, micProximity: MicProximity
    ) async throws {
        let generation = try await prepareSession(context: context)

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runBackgroundCycles(generation: generation)
        }
        let installed = lock.withLock {
            guard sessionGeneration == generation, !finishing else {
                return false
            }
            backgroundTask = task
            return true
        }
        guard installed else {
            task.cancel()
            await task.value
            throw CancellationError()
        }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        let accepted = lock.withLock {
            guard recognitionSession != nil, !finishing, !cancelling else {
                return false
            }
            accumulatedAudio.append(pcmData)
            return true
        }
        guard accepted else { throw CancellationError() }
    }

    public func finishStreaming() async throws -> String {
        try await finishStreaming(expectedGeneration: nil)
    }

    public func cancelStreaming() async {
        let (cancellationGeneration, background, activeFinalization) = lock.withLock {
            sessionGeneration &+= 1
            finishing = true
            cancelling = true
            chunkHandler = nil
            return (sessionGeneration, backgroundTask, finalization)
        }
        background?.cancel()
        activeFinalization?.task.cancel()
        await background?.value
        if let activeFinalization {
            _ = await activeFinalization.task.result
        }
        lock.withLock {
            guard sessionGeneration == cancellationGeneration else { return }
            accumulatedAudio = Data()
            committedPolished = ""
            committedTranscript = ""
            unitStartByte = 0
            trailingSilenceBytes = 0
            rawTranscript = ""
            polishedTranscript = ""
            recognitionSession = nil
            recognitionError = nil
            fedBytes = 0
            backgroundTask = nil
            if finalization?.id == activeFinalization?.id {
                finalization = nil
            }
            cancelling = false
        }
    }

    // MARK: - Session Lifecycle

    private func prepareSession(context: AppContext) async throws -> UInt64 {
        let startingGeneration = lock.withLock { () -> UInt64? in
            guard !cancelling, backgroundTask == nil, finalization == nil,
                recognitionSession == nil || finishing
            else { return nil }
            return sessionGeneration
        }
        guard let startingGeneration else { throw CancellationError() }

        if !sttEngine.isReady {
            Log.debug("[LocalStreaming] Loading STT engine \(sttEngine.name)")
            try await loadSTT()
            Log.debug("[LocalStreaming] STT engine loaded")
        }
        try Task.checkCancellation()
        let newSession = try sttEngine.makeRecognitionSession()
        try Task.checkCancellation()

        let generation = lock.withLock { () -> UInt64? in
            guard !cancelling, sessionGeneration == startingGeneration,
                backgroundTask == nil, finalization == nil,
                recognitionSession == nil || finishing,
                !Task.isCancelled
            else { return nil }
            sessionGeneration &+= 1
            accumulatedAudio = Data()
            currentContext = context
            committedPolished = ""
            committedTranscript = ""
            unitStartByte = 0
            trailingSilenceBytes = 0
            rawTranscript = ""
            polishedTranscript = ""
            finishing = false
            recognitionSession = newSession
            recognitionError = nil
            fedBytes = 0
            return sessionGeneration
        }
        guard let generation else { throw CancellationError() }
        return generation
    }

    private func finishStreaming(
        expectedGeneration: UInt64?
    ) async throws -> String {
        let operation = lock.withLock { () -> Finalization? in
            guard !cancelling else { return nil }
            if let finalization {
                guard expectedGeneration == nil
                    || expectedGeneration == finalization.generation
                else { return nil }
                return finalization
            }

            let generation = sessionGeneration
            guard expectedGeneration == nil || expectedGeneration == generation
            else { return nil }
            finishing = true
            let background = backgroundTask
            let id = UUID()
            let task = Task { [self] in
                try await finalizeSession(
                    generation: generation, background: background)
            }
            let operation = Finalization(
                id: id, generation: generation, task: task)
            finalization = operation
            return operation
        }
        guard let operation else { throw CancellationError() }
        defer {
            lock.withLock {
                if finalization?.id == operation.id { finalization = nil }
            }
        }
        return try await withTaskCancellationHandler {
            try await operation.task.value
        } onCancel: {
            operation.task.cancel()
        }
    }

    private func finalizeSession(
        generation: UInt64, background: Task<Void, Never>?
    ) async throws -> String {
        background?.cancel()
        await background?.value
        try requireCurrentSession(generation)

        let snapshot = lock.withLock { () -> FinishSnapshot? in
            guard sessionGeneration == generation, !Task.isCancelled else {
                return nil
            }
            backgroundTask = nil
            let end = accumulatedAudio.count
            let start = min(fedBytes, end)
            return FinishSnapshot(
                audio: accumulatedAudio,
                context: currentContext,
                committed: committedPolished,
                committedTranscript: committedTranscript,
                recognitionError: recognitionError,
                session: recognitionSession,
                newAudio: accumulatedAudio.subdata(in: start..<end),
                fedEnd: end)
        }
        guard let snapshot else { throw CancellationError() }
        if let error = snapshot.recognitionError { throw error }

        guard !snapshot.audio.isEmpty else {
            Log.debug("[LocalStreaming] No audio accumulated")
            let published = lock.withLock {
                guard sessionGeneration == generation, !Task.isCancelled else {
                    return false
                }
                polishedTranscript = snapshot.committed
                return true
            }
            guard published else { throw CancellationError() }
            return snapshot.committed
        }

        guard let session = snapshot.session else {
            throw LocalModelError.modelNotLoaded
        }

        // Feed audio received since the last cycle, then flush the pending
        // recognition tail.
        let sttStart = CFAbsoluteTimeGetCurrent()
        if !snapshot.newAudio.isEmpty {
            do {
                try session.feed(Self.pcmToFloat(snapshot.newAudio))
            } catch {
                guard recordRecognitionError(error, generation: generation)
                else { throw CancellationError() }
                throw error
            }
            try requireCurrentSession(generation)
            let recorded = lock.withLock {
                guard sessionGeneration == generation, !Task.isCancelled else {
                    return false
                }
                fedBytes = snapshot.fedEnd
                return true
            }
            guard recorded else { throw CancellationError() }
        }

        let raw: String
        do {
            raw = try session.finish()
        } catch {
            guard recordRecognitionError(error, generation: generation)
            else { throw CancellationError() }
            throw error
        }
        try requireCurrentSession(generation)
        let sttElapsed = CFAbsoluteTimeGetCurrent() - sttStart

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let published = lock.withLock {
                guard sessionGeneration == generation, !Task.isCancelled else {
                    return false
                }
                rawTranscript = ""
                polishedTranscript = snapshot.committed
                accumulatedAudio = Data()
                return true
            }
            guard published else { throw CancellationError() }
            return snapshot.committed
        }

        // Close the final unit: everything recognized since the last unit
        // boundary. Polish it, append to the accumulated transcript, and
        // return the whole transcript for one injection.
        let finalUnit = Self.unitText(
            from: trimmed, committed: snapshot.committedTranscript)
            .trimmingCharacters(in: .whitespaces)

        let polishStart = CFAbsoluteTimeGetCurrent()
        var finalPolished = ""
        if !finalUnit.isEmpty {
            finalPolished = await polishWithPreceding(
                finalUnit, preceding: snapshot.committed,
                context: snapshot.context)
        }
        try requireCurrentSession(generation)
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart
        let full = Self.joinPolished(snapshot.committed, finalPolished)

        let published = lock.withLock {
            guard sessionGeneration == generation, !Task.isCancelled else {
                return false
            }
            committedPolished = full
            committedTranscript = trimmed
            rawTranscript = trimmed
            polishedTranscript = full
            accumulatedAudio = Data()
            return true
        }
        guard published else { throw CancellationError() }

        Log.debug("[LocalStreaming] Finish (stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")

        return full
    }

    private func requireCurrentSession(_ generation: UInt64) throws {
        try Task.checkCancellation()
        let isCurrent = lock.withLock { sessionGeneration == generation }
        guard isCurrent else { throw CancellationError() }
    }

    private func recordRecognitionError(
        _ error: any Error, generation: UInt64
    ) -> Bool {
        lock.withLock {
            guard sessionGeneration == generation else { return false }
            if recognitionError == nil { recognitionError = error }
            return true
        }
    }

    // MARK: - Offline Replay

    /// Drive the real unit + polish pipeline deterministically, without the
    /// wall-clock background timer, to reproduce offline exactly what a live
    /// dictation produces. Feed `audio` in `stepBytes` increments, running one
    /// cycle per step (each cycle feeds the new audio, closes a unit when the
    /// policy fires, polishes it, and appends it internally), then finish and
    /// return the whole polished transcript.
    ///
    /// `stepBytes` mimics how much audio arrives per cycle in production
    /// (default 96 000 = ~3 s at 16 kHz mono 16-bit, matching the 3 s
    /// cycle interval). Intended for replay tests only.
    func replay(
        audio: Data, stepBytes: Int = 96_000, context: AppContext = .empty
    ) async throws -> String {
        let generation = try await prepareSession(context: context)

        var offset = 0
        let step = max(1, stepBytes)
        while offset < audio.count {
            let end = min(offset + step, audio.count)
            let slice = audio.subdata(in: offset..<end)
            let appended = lock.withLock {
                guard sessionGeneration == generation, !finishing else {
                    return false
                }
                accumulatedAudio.append(slice)
                return true
            }
            guard appended else { throw CancellationError() }
            offset = end
            await runOneCycle(generation: generation)
            if let error = lock.withLock({ recognitionError }) { throw error }
        }

        try requireCurrentSession(generation)
        return try await finishStreaming(expectedGeneration: generation)
    }

    // MARK: - Background Cycles

    private func runBackgroundCycles(generation: UInt64) async {
        try? await Task.sleep(nanoseconds: UInt64(cycleInterval * 1_000_000_000))

        while !Task.isCancelled {
            let isFinishing = lock.withLock {
                finishing || sessionGeneration != generation
            }
            if isFinishing { break }

            await runOneCycle(generation: generation)

            try? await Task.sleep(nanoseconds: UInt64(cycleInterval * 1_000_000_000))
        }
    }

    private func runOneCycle(generation: UInt64) async {
        let context = lock.withLock { currentContext }

        let sttStart = CFAbsoluteTimeGetCurrent()
        let (session, priorError, isCurrent) = lock.withLock {
            (
                recognitionSession, recognitionError,
                sessionGeneration == generation && !finishing
            )
        }
        guard let session, priorError == nil, isCurrent else { return }

        // Feed only audio that arrived since the last successful cycle.
        let (newAudio, fedEnd) = lock.withLock { () -> (Data, Int) in
            let end = accumulatedAudio.count
            let start = min(fedBytes, end)
            return (accumulatedAudio.subdata(in: start..<end), end)
        }
        if !newAudio.isEmpty {
            do {
                try session.feed(Self.pcmToFloat(newAudio))
                lock.withLock {
                    if sessionGeneration == generation { fedBytes = fedEnd }
                }
            } catch {
                lock.withLock {
                    guard sessionGeneration == generation else { return }
                    if recognitionError == nil { recognitionError = error }
                    finishing = true
                }
                Log.debug("[LocalStreaming] Incremental feed failed: \(error)")
                return
            }
        }
        let trimmed = session.transcript()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sttElapsed = CFAbsoluteTimeGetCurrent() - sttStart
        guard !trimmed.isEmpty else { return }

        // Update the trailing-silence run and decide whether a unit closes.
        let decision = lock.withLock {
            () -> (LocalUnitPolicy.Boundary, String, String)? in
            guard sessionGeneration == generation, !finishing,
                recognitionError == nil
            else { return nil }
            Self.applyTrailingSilence(
                &trailingSilenceBytes, slice: newAudio,
                threshold: silenceThreshold)
            let unitBytes = fedBytes - unitStartByte
            guard let boundary = unitPolicy.boundary(
                unitByteCount: unitBytes,
                trailingSilenceByteCount: trailingSilenceBytes)
            else { return nil }
            let unit = Self.unitText(
                from: trimmed, committed: committedTranscript)
                .trimmingCharacters(in: .whitespaces)
            return (boundary, unit, committedPolished)
        }
        guard let (boundary, unitText, preceding) = decision,
            !unitText.isEmpty
        else { return }

        let polishStart = CFAbsoluteTimeGetCurrent()
        let polished = await polishWithPreceding(
            unitText, preceding: preceding, context: context)
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart

        // A hard pause is a safe point to reset recognition and shed the audio
        // already recognized, bounding memory across a long dictation. Build
        // the fresh session outside the lock because it can throw; a size-cap
        // close is not safe to reset (it can fall mid-word).
        let fresh: (any LocalRecognitionSession)? =
            boundary == .hardPause
            ? try? sttEngine.makeRecognitionSession() : nil

        let publication = lock.withLock {
            () -> (Bool, (@Sendable (String) async -> Void)?) in
            guard sessionGeneration == generation, !finishing,
                recognitionError == nil
            else { return (false, nil) }
            committedPolished = Self.joinPolished(committedPolished, polished)
            if boundary == .hardPause, let fresh {
                recognitionSession = fresh
                let end = accumulatedAudio.count
                accumulatedAudio = fedBytes < end
                    ? accumulatedAudio.subdata(in: fedBytes..<end) : Data()
                fedBytes = 0
                unitStartByte = 0
                committedTranscript = ""
            } else {
                committedTranscript = trimmed
                unitStartByte = fedBytes
            }
            trailingSilenceBytes = 0
            return (true, chunkHandler)
        }
        guard publication.0 else { return }

        Log.debug("[LocalStreaming] Closed unit (\(unitText.count) chars, reset=\(boundary == .hardPause), stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")

        // A preview handler may mirror the unit; it does not gate the return.
        if let handler = publication.1 {
            await handler(polished)
        }
    }

    // MARK: - Joining

    /// Join two polished pieces with a space, unless the next piece
    /// begins with a line or paragraph break (then the break is the
    /// separator, so no space is inserted before it).
    private static func joinPolished(_ acc: String, _ piece: String) -> String {
        if acc.isEmpty { return piece }
        if piece.isEmpty { return acc }
        return piece.hasPrefix("\n") ? acc + piece : acc + " " + piece
    }

    /// The part of `transcript` not yet emitted as a closed unit. Uses the
    /// longest common prefix with the already-committed transcript, so a
    /// revision inside the committed region re-emits only the changed tail
    /// rather than duplicating settled text.
    private static func unitText(
        from transcript: String, committed: String
    ) -> String {
        let commonLength = transcript.commonPrefix(with: committed).count
        return String(transcript.dropFirst(commonLength))
    }

    /// Extend or reset the running trailing-silence count from one fed slice.
    /// A fully silent slice extends the run; any speech resets it to that
    /// slice's own trailing silence.
    private static func applyTrailingSilence(
        _ trailing: inout Int, slice: Data, threshold: Float
    ) {
        guard !slice.isEmpty else { return }
        let sliceTrailing = AudioLevelAnalyzer.trailingSilenceByteCount(
            pcm16: slice, threshold: threshold)
        if sliceTrailing == slice.count {
            trailing += slice.count
        } else {
            trailing = sliceTrailing
        }
    }

    // MARK: - Audio

    /// Convert 16-bit little-endian PCM to normalized float samples.
    private static func pcmToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let i16 = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                samples[i] = Float(i16[i]) / 32768.0
            }
        }
        return samples
    }

    // MARK: - Polishing

    private func polishWithPreceding(
        _ raw: String, preceding: String, context: AppContext
    ) async -> String {
        let precedingText = preceding.isEmpty
            ? context.focusedFieldContent
            : preceding
        return await PolishPipeline.polish(
            raw,
            chatClient: polishChatClient,
            model: polishModel,
            tone: PolishPipeline.toneLabel(for: context.bundleID),
            precedingText: precedingText,
            breakMode: .commandsOnly)
    }
}
