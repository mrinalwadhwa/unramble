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
/// faithful.
public final class LocalStreamingProvider: LocalAudioReplayProviding,
    @unchecked Sendable
{

    // MARK: - Configuration

    private let sttEngine: any LocalStreamingRecognizer
    private let loadSTT: @Sendable () async throws -> Void
    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String
    private let cycleInterval: TimeInterval
    private let unitPolicy: LocalUnitPolicy
    private var silenceThreshold: Float

    // MARK: - State (guarded by lock)

    private let lock = NSLock()
    private var accumulatedAudio = Data()
    private var currentContext: AppContext = .empty

    /// Audio byte offset where the current, not-yet-closed unit began.
    private var unitStartByte = 0

    /// Running count of trailing silence bytes at the live edge. A long
    /// enough run closes the current unit.
    private var trailingSilenceBytes = 0

    /// The recognition transcript already turned into closed units.
    private var committedTranscript = ""

    /// The last polished sentence, held provisional until the following unit
    /// confirms it is complete. It is carried onto the next unit's input so a
    /// sentence split across a pause is re-polished whole. Empty when nothing
    /// is pending.
    private var carry = ""

    /// Incremental transcription session for the current dictation.
    private var recognitionSession: (any LocalRecognitionSession)?

    /// The first incremental feed failure. A feed can partially mutate model
    /// state, so it is terminal and must never be retried on the same session.
    private var recognitionError: (any Error)?

    /// Identifies the current recognition session across async cycle work.
    private var sessionGeneration: UInt64 = 0
    private var activeSessionID: DictationSessionID?

    /// Bytes of accumulated audio already fed to the streaming session.
    private var fedBytes = 0

    /// Accumulated polished text for all committed sentences. Used as
    /// preceding context for later chunks and as part of the full result.
    private var committedPolished = ""

    private struct Finalization {
        let id: UUID
        let generation: UInt64
        let task: Task<String, Error>
    }

    private struct SetupOperation {
        let id: UUID
        let sessionID: DictationSessionID
        let generation: UInt64
        let task: Task<UInt64, Error>
    }

    private struct FinishSnapshot {
        let audio: Data
        let context: AppContext
        let committed: String
        let committedTranscript: String
        let carry: String
        let recognitionError: (any Error)?
        let session: (any LocalRecognitionSession)?
        let newAudio: Data
        let fedEnd: Int
    }

    private var finishing = false
    private var cancelling = false
    private var setupOperation: SetupOperation?
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

    /// Set the energy threshold below which a 20 ms window counts as silence
    /// when detecting the pauses that close units. The pipeline supplies its
    /// ambient-adaptive value per dictation; the default is the speech floor.
    public func setSilenceThreshold(_ threshold: Float) {
        lock.withLock { silenceThreshold = threshold }
    }

    public func startStreaming(
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity: MicProximity
    ) async throws {
        let generation = try await prepareSession(
            context: context,
            sessionID: sessionID)

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runBackgroundCycles(generation: generation)
        }
        let installed = lock.withLock {
            guard activeSessionID == sessionID,
                sessionGeneration == generation,
                !finishing, !cancelling, !Task.isCancelled
            else {
                return false
            }
            backgroundTask = task
            return true
        }
        guard installed else {
            task.cancel()
            await task.value
            await cancelStreaming(sessionID: sessionID)
            throw CancellationError()
        }
    }

    public func sendAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID
    ) async throws {
        let accepted = lock.withLock {
            guard activeSessionID == sessionID,
                recognitionSession != nil, !finishing, !cancelling
            else {
                return false
            }
            accumulatedAudio.append(pcmData)
            return true
        }
        guard accepted else { throw CancellationError() }
    }

    public func finishStreaming(
        sessionID: DictationSessionID
    ) async throws -> String {
        try await finishStreaming(
            expectedGeneration: nil,
            sessionID: sessionID)
    }

    public func cancelActiveStreaming() async {
        guard let sessionID = lock.withLock({ activeSessionID }) else { return }
        await cancelStreaming(sessionID: sessionID)
    }

    public func cancelStreaming(sessionID: DictationSessionID) async {
        let state: (
            generation: UInt64,
            setup: SetupOperation?,
            background: Task<Void, Never>?,
            finalization: Finalization?
        )? = lock.withLock {
            guard activeSessionID == sessionID else {
                return nil
            }
            sessionGeneration &+= 1
            finishing = true
            cancelling = true
            return (
                sessionGeneration, setupOperation, backgroundTask,
                finalization)
        }
        guard let state else { return }
        state.setup?.task.cancel()
        state.background?.cancel()
        state.finalization?.task.cancel()
        if let setup = state.setup {
            _ = await setup.task.result
        }
        await state.background?.value
        if let activeFinalization = state.finalization {
            _ = await activeFinalization.task.result
        }
        lock.withLock {
            guard sessionGeneration == state.generation else { return }
            clearSessionContentLocked()
            recognitionSession = nil
            if setupOperation?.id == state.setup?.id {
                setupOperation = nil
            }
            backgroundTask = nil
            if finalization?.id == state.finalization?.id {
                finalization = nil
            }
            finishing = false
            cancelling = false
            activeSessionID = nil
        }
    }

    // MARK: - Session Lifecycle

    private func prepareSession(
        context: AppContext,
        sessionID: DictationSessionID,
        silenceThreshold: Float? = nil
    ) async throws -> UInt64 {
        let operation = lock.withLock { () -> SetupOperation? in
            guard !cancelling, activeSessionID == nil,
                setupOperation == nil, backgroundTask == nil,
                finalization == nil,
                recognitionSession == nil || finishing
            else { return nil }
            sessionGeneration &+= 1
            let generation = sessionGeneration
            let id = UUID()
            activeSessionID = sessionID
            let task = Task { [self] in
                if !sttEngine.isReady {
                    Log.debug(
                        "[LocalStreaming] Loading STT engine \(sttEngine.name)")
                    try await loadSTT()
                    Log.debug("[LocalStreaming] STT engine loaded")
                }
                try Task.checkCancellation()

                let installed = try lock.withLock { () -> Bool in
                    guard !cancelling,
                        sessionGeneration == generation,
                        activeSessionID == sessionID,
                        setupOperation?.id == id,
                        backgroundTask == nil, finalization == nil,
                        recognitionSession == nil || finishing,
                        !Task.isCancelled
                    else { return false }

                    // Creation is synchronous. Keep it in the ownership lock so
                    // cancellation cannot claim this generation between the
                    // final stale check and model-session allocation.
                    let newSession = try sttEngine.makeRecognitionSession()
                    clearSessionContentLocked()
                    currentContext = context
                    if let silenceThreshold {
                        self.silenceThreshold = silenceThreshold
                    }
                    finishing = false
                    recognitionSession = newSession
                    setupOperation = nil
                    return true
                }
                guard installed else { throw CancellationError() }
                return generation
            }
            let operation = SetupOperation(
                id: id,
                sessionID: sessionID,
                generation: generation,
                task: task)
            setupOperation = operation
            return operation
        }
        guard let operation else { throw CancellationError() }

        do {
            return try await withTaskCancellationHandler {
                try await operation.task.value
            } onCancel: {
                operation.task.cancel()
            }
        } catch {
            lock.withLock {
                guard setupOperation?.id == operation.id else { return }
                setupOperation = nil
                if !cancelling,
                    activeSessionID == sessionID,
                    sessionGeneration == operation.generation
                {
                    activeSessionID = nil
                    finishing = false
                }
            }
            throw error
        }
    }

    private func finishStreaming(
        expectedGeneration: UInt64?,
        sessionID: DictationSessionID
    ) async throws -> String {
        let operation = lock.withLock { () -> Finalization? in
            guard activeSessionID == sessionID, !cancelling else { return nil }
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
        let result: String
        do {
            result = try await withTaskCancellationHandler {
                try await operation.task.value
            } onCancel: {
                operation.task.cancel()
            }
        } catch {
            await cancelStreaming(sessionID: sessionID)
            throw error
        }
        let cleaned = lock.withLock { () -> Bool in
            guard activeSessionID == sessionID,
                sessionGeneration == operation.generation,
                !cancelling,
                finalization?.id == operation.id
            else { return false }
            clearSessionContentLocked()
            activeSessionID = nil
            recognitionSession = nil
            backgroundTask = nil
            finishing = false
            return true
        }
        guard cleaned else { throw CancellationError() }
        return result
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
                carry: carry,
                recognitionError: recognitionError,
                session: recognitionSession,
                newAudio: accumulatedAudio.subdata(in: start..<end),
                fedEnd: end)
        }
        guard let snapshot else { throw CancellationError() }
        if let error = snapshot.recognitionError { throw error }

        guard !snapshot.audio.isEmpty else {
            Log.debug("[LocalStreaming] No audio accumulated")
            return Self.joinPolished(snapshot.committed, snapshot.carry)
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
            try requireCurrentSession(generation)
            return Self.joinPolished(snapshot.committed, snapshot.carry)
        }

        // Close the final unit: the held sentence plus everything recognized
        // since the last unit boundary, polished and committed in full — no
        // sentence is held past the end.
        let finalUnit = Self.unitText(
            from: trimmed, committed: snapshot.committedTranscript)
            .trimmingCharacters(in: .whitespaces)
        let combined: String
        var finalPolished = ""
        if finalUnit.isEmpty {
            // No new speech; commit the held sentence as it already stands. The
            // carry can hold un-normalized text (a raw seam fragment carried for
            // the next unit to complete) and there is no next unit to re-polish
            // it, so normalize casing/formatting before it is injected.
            combined = ""
            let casual = PolishPipeline.toneLabel(
                for: snapshot.context.bundleID) == "casual"
            finalPolished = PolishPipeline.normalizeFormatting(
                snapshot.carry, casual: casual)
        } else if snapshot.carry.isEmpty {
            combined = finalUnit
        } else {
            combined = Self.joinCarryUnit(
                carry: snapshot.carry, unit: finalUnit)
        }

        let polishStart = CFAbsoluteTimeGetCurrent()
        if !combined.isEmpty {
            finalPolished = await polishWithPreceding(
                combined, preceding: snapshot.committed,
                context: snapshot.context)
        }
        try requireCurrentSession(generation)
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart
        // A lone "i" is always the pronoun "I"; guarantee it on the final text
        // regardless of which internal path produced each piece.
        let full = Self.reconcileSplitWords(
            Self.capitalizePronounI(
                Self.joinPolished(snapshot.committed, finalPolished)),
            raw: trimmed)

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

    /// Replay a retained production capture through the same cycle and unit
    /// machinery as live local dictation, without a wall-clock timer.
    public func replayCapturedAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity: MicProximity,
        silenceThreshold: Float
    ) async throws -> String {
        let sourceBytesPerCycle = max(
            MemoryLayout<Int16>.size,
            Int(cycleInterval * Double(LocalUnitPolicy.sourceBytesPerSecond)))
        let alignedStep = sourceBytesPerCycle
            - sourceBytesPerCycle % MemoryLayout<Int16>.size
        return try await replayCapturedAudio(
            pcmData,
            sessionID: sessionID,
            context: context,
            stepBytes: alignedStep,
            silenceThreshold: silenceThreshold)
    }

    private func replayCapturedAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID,
        context: AppContext,
        stepBytes: Int,
        silenceThreshold: Float?
    ) async throws -> String {
        let generation = try await prepareSession(
            context: context,
            sessionID: sessionID,
            silenceThreshold: silenceThreshold)

        do {
            return try await withTaskCancellationHandler {
                var offset = 0
                let step = max(1, stepBytes)
                while offset < pcmData.count {
                    try requireCurrentSession(generation)
                    let end = min(offset + step, pcmData.count)
                    let slice = pcmData.subdata(in: offset..<end)
                    let appended = lock.withLock {
                        guard activeSessionID == sessionID,
                            sessionGeneration == generation,
                            !finishing, !cancelling
                        else {
                            return false
                        }
                        accumulatedAudio.append(slice)
                        return true
                    }
                    guard appended else { throw CancellationError() }
                    offset = end
                    await runOneCycle(generation: generation)
                    try requireCurrentSession(generation)
                    if let error = lock.withLock({ recognitionError }) {
                        throw error
                    }
                }
                return try await finishStreaming(
                    expectedGeneration: generation,
                    sessionID: sessionID)
            } onCancel: { [weak self] in
                Task {
                    await self?.cancelStreaming(sessionID: sessionID)
                }
            }
        } catch {
            await cancelStreaming(sessionID: sessionID)
            throw error
        }
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

    /// Clear all user content owned by a terminal session. Call with `lock`
    /// held; session ownership and task handles are cleared by the caller.
    private func clearSessionContentLocked() {
        accumulatedAudio = Data()
        currentContext = .empty
        committedPolished = ""
        committedTranscript = ""
        carry = ""
        unitStartByte = 0
        trailingSilenceBytes = 0
        recognitionError = nil
        fedBytes = 0
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
            () -> (LocalUnitPolicy.Boundary, String, String, String)? in
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
            return (boundary, unit, committedPolished, carry)
        }
        guard let (boundary, unitText, preceding, heldCarry) = decision,
            !unitText.isEmpty
        else { return }

        // Never split a break command across a unit boundary: if a soft-closed
        // unit ends with a bare "new" (the start of "new paragraph"/"new line"),
        // hold it back so the next unit sees the whole command and substitution
        // can convert it. This only moves where the boundary falls; it never
        // adds a conversion, so it introduces no command false positives. A hard
        // pause resets recognition, so a real pause mid-command is not treated
        // as one.
        var unit = unitText
        var heldStarter = ""
        if boundary != .hardPause {
            let starter = Self.trailingBreakCommandStarter(unitText)
            let remainder = String(unitText.dropLast(starter.count))
                .trimmingCharacters(in: .whitespaces)
            if !starter.isEmpty, !remainder.isEmpty {
                unit = remainder
                heldStarter = starter
            }
        }

        // Prepend the held sentence so a sentence split across this boundary is
        // re-polished whole; the model, seeing the full clause, decides where
        // the real sentence break is. Dedup any span the unit re-recognizes from
        // the carry (a size-cap soft-close can fall mid-word and the recognizer,
        // not reset, re-emits it).
        let combined = heldCarry.isEmpty
            ? unit
            : Self.joinCarryUnit(carry: heldCarry, unit: unit)

        let polishStart = CFAbsoluteTimeGetCurrent()
        let polished = await polishWithPreceding(
            combined, preceding: preceding, context: context)
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart

        // Commit every sentence but the last; hold the last until the next unit
        // (or finish) confirms it is complete.
        let (commit, splitCarry) = Self.splitTrailingSentence(polished)
        var newCarry = splitCarry

        // Seam guard: when a unit boundary falls mid-sentence, `combined` ends in
        // an un-terminated fragment. The per-unit polish sometimes drops that
        // fragment — wholly (a fresh clause, e.g. "We're now") or just its tail
        // (a long clause it partly kept, e.g. "...senior roles and to revisit
        // the") — and the content-loss guard misses it when the words are
        // low-content, losing it at the seam because only terminated sentences
        // carry forward. Recover the dropped suffix and carry it so the next unit
        // prepends and completes it. (A pre-polish strip of the fragment was
        // tried and reverted: it made polish trim now-trailing hedges — "so bear
        // with me", "I think" — a worse, content-dropping regression.)
        let inputTail = Self.splitTrailingSentence(combined).carry
            .trimmingCharacters(in: .whitespaces)
        if Self.isUnterminatedFragment(inputTail),
            let drop = Self.droppedTailSuffix(
                inputTail: inputTail, polished: polished) {
            // A dropped suffix that continues the kept sentence rejoins it (the
            // premature terminator is stripped); a wholly dropped clause is a new
            // sentence appended after the carry.
            newCarry = drop.continuation
                ? Self.joinPolished(Self.stripTerminator(newCarry), drop.suffix)
                : Self.joinPolished(newCarry, drop.suffix)
        }
        // The polish can also complete an un-terminated fragment by inventing a
        // trailing word ("...the internet" -> "...the internet blinked"); that
        // fabrication would carry forward and corrupt the next join. Drop any
        // content the carry adds past the raw fragment's last content word.
        if Self.isUnterminatedFragment(inputTail) {
            newCarry = Self.stripFabricatedCarryTail(
                carry: newCarry, inputTail: inputTail)
        }

        // A hard pause is a safe point to reset recognition and shed the audio
        // already recognized, bounding memory across a long dictation. Build
        // the fresh session outside the lock because it can throw; a size-cap
        // close is not safe to reset (it can fall mid-word).
        let fresh: (any LocalRecognitionSession)? =
            boundary == .hardPause
            ? try? sttEngine.makeRecognitionSession() : nil

        let published = lock.withLock {
            () -> Bool in
            guard sessionGeneration == generation, !finishing,
                recognitionError == nil
            else { return false }
            if !commit.isEmpty {
                committedPolished = Self.joinPolished(committedPolished, commit)
            }
            carry = newCarry
            if boundary == .hardPause, let fresh {
                recognitionSession = fresh
                let end = accumulatedAudio.count
                accumulatedAudio = fedBytes < end
                    ? accumulatedAudio.subdata(in: fedBytes..<end) : Data()
                fedBytes = 0
                unitStartByte = 0
                committedTranscript = ""
            } else {
                // Hold a straddling break-command starter out of the committed
                // baseline so the next unit re-emits it whole.
                committedTranscript = heldStarter.isEmpty
                    ? trimmed
                    : trimmed.replacingOccurrences(
                        of: #"\s*\bnew\s*$"#, with: "",
                        options: [.regularExpression, .caseInsensitive])
                unitStartByte = fedBytes
            }
            trailingSilenceBytes = 0
            return true
        }
        guard published else { return }

        Log.debug("[LocalStreaming] Closed unit (\(unitText.count) chars, reset=\(boundary == .hardPause), stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")
    }

    // MARK: - Joining

    /// Join two polished pieces with a space, unless the next piece
    /// begins with a line or paragraph break (then the break is the
    /// separator, so no space is inserted before it).
    private static func joinPolished(_ acc: String, _ piece: String) -> String {
        if acc.isEmpty { return piece }
        if piece.isEmpty { return acc }
        // A break already at the seam is the separator; drop any leading spaces
        // the next piece carries so a paragraph does not start indented.
        if piece.hasPrefix("\n") { return acc + piece }
        if acc.hasSuffix("\n") {
            return acc + String(piece.drop(while: { $0 == " " }))
        }
        // Otherwise separate with a single space, unless one side already has one.
        if acc.hasSuffix(" ") || piece.hasPrefix(" ") { return acc + piece }
        return acc + " " + piece
    }

    private static let sentenceBoundary = try! NSRegularExpression(
        pattern: #"([.!?]["'”’)\]]?\s+|\n+)"#)

    /// Split polished text into the part to commit (every sentence but the
    /// last) and the last sentence to hold. The model terminates every unit,
    /// so its last sentence may be an unfinished fragment; holding it lets the
    /// next unit complete it.
    private static func splitTrailingSentence(
        _ text: String
    ) -> (committed: String, carry: String) {
        let ns = text as NSString
        let matches = sentenceBoundary.matches(
            in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return ("", text) }
        let split = last.range.location + last.range.length
        return (ns.substring(to: split), ns.substring(from: split))
    }

    /// Capitalize the standalone pronoun "i" ("i think" -> "I think", "i'll" ->
    /// "I'll"). A lone "i" is never correct in dictated prose.
    private static func capitalizePronounI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\bi\\b", with: "I", options: [.regularExpression])
    }

    /// True when `text` is a non-empty tail that does not end at a sentence
    /// terminator — i.e. an incomplete fragment left when a unit boundary falls
    /// mid-sentence, which must be carried rather than dropped.
    private static func isUnterminatedFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(
            in: CharacterSet(charactersIn: " \t\"'”’)]"))
        guard let last = trimmed.last else { return false }
        return !".!?".contains(last)
    }

    /// Words that do not by themselves make a dropped fragment worth carrying: a
    /// trailing bare connector polish trims when it terminates a kept fragment is
    /// not a content loss.
    private static let seamStopwords: Set<String> = [
        "and", "but", "or", "so", "then", "now", "the", "a", "an", "on", "in",
        "to", "of", "for", "with", "at", "by", "is", "are", "was", "were",
        "be", "been", "it", "its", "up",
    ]

    /// Spoken number/time words the polish converts to digits, so a fragment word
    /// like "thirty" is present in the output as part of "9:30" rather than a
    /// literal match.
    private static let seamNumberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
        "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion",
    ]

    private static func seamNorm(_ s: Substring) -> String {
        s.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".,!?;:\"'”’)]"))
    }

    /// Given the input's un-terminated trailing fragment and the polished output,
    /// return the suffix of the fragment the polish dropped, plus whether it
    /// continues the kept sentence (a partial-tail drop) rather than starting a
    /// new one (a wholly dropped clause) — or nil when nothing meaningful was
    /// dropped. The polish keeps a prefix of the fragment and drops a suffix, so
    /// the drop begins at the first content word missing from the output. Keying
    /// off the missing word (not the last output word) is robust to a polish that
    /// completes the fragment by inventing a trailing word.
    static func droppedTailSuffix(
        inputTail: String, polished: String
    ) -> (suffix: String, continuation: Bool)? {
        let tailWords = inputTail.split(separator: " ").map(String.init)
        guard !tailWords.isEmpty else { return nil }
        let polishedSet = Set(polished.split(separator: " ").map { seamNorm($0) })
        // Presence is robust to the surface-form changes the polish makes, so a
        // word the polish KEPT (in a different form) is not mistaken for a drop:
        //  - a partial word it completed ("grabb" -> "grabbed") — prefix of an
        //    output word;
        //  - a word re-tokenized or hyphenated ("stand up" -> "stand-up") — its
        //    alnum key is a substring of the output's alnum key;
        //  - a spoken number/time it converted to digits ("nine thirty" -> "9:30")
        //    — a number word when the output holds a digit.
        let polishedAlnum = String(seamAlnum(polished))
        let polishedHasDigit = polished.contains { $0.isNumber }
        func present(_ n: String) -> Bool {
            if polishedSet.contains(n) { return true }
            if n.count >= 3, polishedSet.contains(where: {
                $0.count > n.count && $0.hasPrefix(n)
            }) { return true }
            if n.count >= 3, polishedAlnum.contains(n) { return true }
            if polishedHasDigit, seamNumberWords.contains(n) { return true }
            return false
        }
        // Walk the fragment; stop at the first CONTENT word missing from the
        // output — that is where the drop begins. Stopwords are ignored (a
        // trimmed trailing connector is not a drop). `lastKept` is -1 when polish
        // kept none of the fragment (a wholly dropped clause).
        var lastKept = -1
        for (i, w) in tailWords.enumerated() {
            let n = seamNorm(Substring(w))
            if seamStopwords.contains(n) { continue }
            if present(n) { lastKept = i } else { break }
        }
        let suffixWords = Array(tailWords[(lastKept + 1)...])
        guard !suffixWords.isEmpty, suffixWords.count <= 6 else { return nil }
        // Only carry when the dropped suffix holds real content (a trailing bare
        // connector polish trimmed is not a loss).
        let contentSuffix = suffixWords.filter {
            !seamStopwords.contains(seamNorm(Substring($0)))
        }
        guard !contentSuffix.isEmpty else { return nil }
        // A suffix whose content words are already present in the output was not
        // dropped — it is a merge, reorder, or form-change artifact (e.g. polish
        // rendering "nine thirty" as "9:30"); re-appending it would duplicate
        // content. Only recover a genuine loss: a majority of the content absent.
        let absent = contentSuffix.filter { !present(seamNorm(Substring($0))) }
        guard absent.count * 2 > contentSuffix.count else { return nil }
        return (suffixWords.joined(separator: " "), lastKept >= 0)
    }

    /// Alphanumeric-only lowercase key, used to detect a re-recognized overlap at
    /// a unit seam across tokenization, hyphenation, and punctuation differences.
    private static func seamAlnum(_ s: String) -> [Character] {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
    }

    /// Smallest overlap, in alphanumeric characters, treated as a re-recognized
    /// repeat rather than coincidence.
    private static let minSeamOverlapChars = 3

    /// Join a held carry fragment to the next unit, removing the leading span the
    /// unit re-recognizes from the carry. A size-cap soft-close can fall mid-word:
    /// the recognizer, not reset, re-emits the completed word, so the carry's
    /// polished tail ("...grabbed it") and the unit's raw head ("ed it for...")
    /// name the same speech. Match on an alphanumeric-only key so a mid-word split
    /// or a hyphenation/comma difference cannot hide the repeat, then drop the
    /// duplicated head of `unit` — but only when the drop ends on a word boundary
    /// in `unit`, so a legitimate word ("sawdust" after "saw") is never chopped.
    /// With no overlap this is exactly the previous behavior:
    /// `stripTerminator(carry) + " " + unit`.
    static func joinCarryUnit(carry: String, unit: String) -> String {
        let c = stripTerminator(carry)
        let u = unit.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return u }
        guard !u.isEmpty else { return c }
        let ck = seamAlnum(c)
        // Map each alphanumeric position in `u` back to its original index, so the
        // overlap can be dropped while the remainder keeps casing and punctuation.
        let uChars = Array(u)
        var alnumIndex: [Int] = []
        for (i, ch) in uChars.enumerated()
        where String(ch).rangeOfCharacter(from: .alphanumerics) != nil {
            alnumIndex.append(i)
        }
        let uk = alnumIndex.map { Character(uChars[$0].lowercased()) }
        let maxL = min(ck.count, uk.count)
        guard maxL >= minSeamOverlapChars else { return c + " " + u }
        var overlap = 0
        var length = maxL
        while length >= minSeamOverlapChars {
            if Array(ck.suffix(length)) == Array(uk.prefix(length)) {
                // The dropped head must end on a word boundary in `u` (a non-
                // alphanumeric follows, or the string ends); otherwise the match
                // fell mid-word and is coincidental, not a repeat.
                let boundary = length >= alnumIndex.count
                    || alnumIndex[length] > alnumIndex[length - 1] + 1
                if boundary { overlap = length; break }
            }
            length -= 1
        }
        guard overlap > 0 else { return c + " " + u }
        let dropTo = alnumIndex[overlap - 1] + 1
        let rest = String(uChars[dropTo...]).drop(while: { $0 == " " })
        return rest.isEmpty ? c : c + " " + String(rest)
    }

    /// After a mid-sentence soft-close, the polish sometimes completes the
    /// un-terminated fragment by appending a trailing word ("...the internet" ->
    /// "...the internet blinked"), which would carry forward and corrupt the next
    /// join. Drop content the carry adds past the raw fragment's last content
    /// word; align on that word so a word the polish legitimately kept stays, and
    /// only strip a short completion (a long tail means the anchor is unreliable).
    static func stripFabricatedCarryTail(
        carry: String, inputTail: String
    ) -> String {
        let rawContent = inputTail.split(separator: " ")
            .map { seamNorm($0) }
            .filter { !$0.isEmpty && !seamStopwords.contains($0) }
        guard let lastRaw = rawContent.last else { return carry }
        let tokens = carry.split(separator: " ").map(String.init)
        guard let anchor = tokens.lastIndex(where: {
            seamNorm(Substring($0)) == lastRaw
        }), anchor < tokens.count - 1 else { return carry }
        let tailContent = tokens[(anchor + 1)...].filter {
            let n = seamNorm(Substring($0))
            return !n.isEmpty && !seamStopwords.contains(n)
        }
        guard !tailContent.isEmpty, tailContent.count <= 3 else { return carry }
        return tokens[...anchor].joined(separator: " ")
    }

    /// Rejoin a word a size-cap boundary split across a space ("relev ance" ->
    /// "relevance"): when two adjacent output tokens concatenate to a single token
    /// in the raw transcript AND the first is not itself a whole raw word, the
    /// space is a seam artifact from a mid-word unit boundary. Keyed on the raw
    /// recognizer output, so no dictionary is needed and a genuine two-word
    /// sequence ("saw dust", heard as two words) is never merged.
    static func reconcileSplitWords(_ text: String, raw: String) -> String {
        let rawTokens = Set(
            raw.split(whereSeparator: { $0 == " " || $0 == "\n" })
                .map { String(seamAlnum(String($0))) }
                .filter { !$0.isEmpty })
        guard !rawTokens.isEmpty else { return text }
        // Per line, so a merge never crosses a newline (paragraph) break.
        let rejoined = text.components(separatedBy: "\n").map { line -> String in
            var toks = line.split(separator: " ", omittingEmptySubsequences: false)
                .map(String.init)
            var i = 0
            while i + 1 < toks.count {
                let a = toks[i], b = toks[i + 1]
                let ak = String(seamAlnum(a)), bk = String(seamAlnum(b))
                // `a` must be a bare fragment (no terminal punctuation), `b` a
                // lowercase continuation, and `a` + `b` a raw word that `a` alone
                // is not — otherwise the space is a real word boundary.
                let aClean = !a.isEmpty && !".!?".contains(a.last!)
                let bLower = b.first.map { $0.isLowercase } ?? false
                if !ak.isEmpty, !bk.isEmpty, aClean, bLower,
                    rawTokens.contains(ak + bk), !rawTokens.contains(ak) {
                    toks[i] = a + b
                    toks.remove(at: i + 1)
                    continue
                }
                i += 1
            }
            return toks.joined(separator: " ")
        }
        return rejoined.joined(separator: "\n")
    }

    private static let trailingNewPattern = try! NSRegularExpression(
        pattern: #"\bnew\s*$"#, options: .caseInsensitive)

    /// The trailing bare "new" that begins a "new paragraph"/"new line" command,
    /// or "" when the text does not end with one. Held back at a unit boundary
    /// so a break command is not split across two units.
    private static func trailingBreakCommandStarter(_ text: String) -> String {
        let ns = text as NSString
        guard let match = trailingNewPattern.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length))
        else { return "" }
        return ns.substring(with: match.range)
    }

    /// Remove trailing sentence punctuation so a held sentence continues into
    /// the next unit rather than reading as already finished.
    private static func stripTerminator(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"[.!?…]+\s*$"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    /// The part of a prefix-monotonic transcript not yet assigned to a closed
    /// unit. Nemotron appends tokens and therefore preserves this invariant.
    /// The common-prefix calculation is defensive only; it cannot reconcile a
    /// recognizer that revises text already represented by polished output.
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
