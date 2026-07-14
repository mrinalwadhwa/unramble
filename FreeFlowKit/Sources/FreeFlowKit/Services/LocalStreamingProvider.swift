import Foundation

/// On-device streaming dictation with committed, rolling injection.
///
/// Accumulate PCM audio during recording and feed each new slice to one
/// incremental recognition session. Every `cycleInterval` seconds, hand the
/// running transcript to a `CommitTracker`, which returns the sentences that
/// have become stable (unchanged since the previous cycle and followed by
/// more text). Those committed sentences are polished and emitted through the
/// chunk handler, so they are injected while the user keeps talking.
///
/// Because streaming recognition revises text near the live edge, only
/// sentences that have stopped changing are committed — never the
/// volatile tail. At finish, the remaining tail is polished and returned
/// as the final chunk. When no chunk handler is set (single-commit
/// callers and unit tests), nothing is emitted mid-session and the whole
/// polished transcript is returned from `finishStreaming`.
public final class LocalStreamingProvider: StreamingDictationProviding,
    @unchecked Sendable
{

    // MARK: - Configuration

    private let sttEngine: any LocalStreamingRecognizer
    private let loadSTT: @Sendable () async throws -> Void
    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String
    private let cycleInterval: TimeInterval

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

    /// Tracks which sentences have stabilized and been committed.
    private var commitTracker = CommitTracker()

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

    /// Whether any committed chunk was emitted through the handler this
    /// session. The pipeline clears the handler before `finishStreaming`,
    /// so this — not the current handler — decides whether committed text
    /// was already injected and thus must be omitted from the return.
    private var didEmitChunks = false

    private struct Finalization {
        let id: UUID
        let generation: UInt64
        let task: Task<String, Error>
    }

    private struct FinishSnapshot {
        let audio: Data
        let context: AppContext
        let rolling: Bool
        let committed: String
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
        loadSTT: (@Sendable () async throws -> Void)? = nil
    ) {
        self.sttEngine = sttEngine
        self.loadSTT = loadSTT ?? { try await sttEngine.load() }
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
        self.cycleInterval = cycleInterval
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
            commitTracker = CommitTracker()
            committedPolished = ""
            rawTranscript = ""
            polishedTranscript = ""
            didEmitChunks = false
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
            commitTracker = CommitTracker()
            committedPolished = ""
            rawTranscript = ""
            polishedTranscript = ""
            didEmitChunks = false
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
                rolling: didEmitChunks,
                committed: committedPolished,
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
            return snapshot.rolling ? "" : snapshot.committed
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
            return snapshot.rolling ? "" : snapshot.committed
        }

        // Keep commit tracking transactional across the async polish call.
        let transaction = lock.withLock {
            () -> (CommitTracker, [String])? in
            guard sessionGeneration == generation, !Task.isCancelled else {
                return nil
            }
            var candidate = commitTracker
            let remaining = candidate.commitRemaining(trimmed)
            return (candidate, remaining)
        }
        guard let (candidateTracker, tailSentences) = transaction else {
            throw CancellationError()
        }
        let tailText = tailSentences.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let polishStart = CFAbsoluteTimeGetCurrent()
        var tailPolished = ""
        if !tailText.isEmpty {
            tailPolished = await polishWithPreceding(
                tailText, preceding: snapshot.committed,
                context: snapshot.context)
        }
        try requireCurrentSession(generation)
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart
        let full = Self.joinPolished(snapshot.committed, tailPolished)

        let published = lock.withLock {
            guard sessionGeneration == generation, !Task.isCancelled else {
                return false
            }
            commitTracker = candidateTracker
            rawTranscript = trimmed
            polishedTranscript = full
            accumulatedAudio = Data()
            return true
        }
        guard published else { throw CancellationError() }

        Log.debug("[LocalStreaming] Finish (committed=\(candidateTracker.committed) tailSentences=\(tailSentences.count) rolling=\(snapshot.rolling) stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")

        // When committed chunks were injected live, return only the tail.
        // Otherwise return the whole transcript.
        return snapshot.rolling ? tailPolished : full
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

    /// Drive the real commit + polish pipeline deterministically, without
    /// the wall-clock background timer, to reproduce offline exactly what a
    /// live dictation would inject. Feed `audio` in `stepBytes` increments,
    /// running one cycle per step (each cycle feeds only the new audio,
    /// commits stabilized sentences, polishes them, and emits them through
    /// the chunk handler), then finish and return the tail. Set a chunk
    /// handler with `setChunkHandler` first to collect the injected chunks.
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

        // Commit any sentences that have stabilized since the last cycle.
        let transaction = lock.withLock {
            () -> (CommitTracker, [String], String)? in
            guard sessionGeneration == generation, !finishing,
                recognitionError == nil
            else { return nil }
            var candidate = commitTracker
            let newly = candidate.ingest(trimmed)
            return (candidate, newly, committedPolished)
        }
        guard let (candidateTracker, newly, preceding) = transaction else {
            return
        }
        guard !newly.isEmpty else {
            lock.withLock {
                guard sessionGeneration == generation, !finishing,
                    recognitionError == nil
                else { return }
                commitTracker = candidateTracker
            }
            Log.debug("[LocalStreaming] Cycle: no new committed sentences (committed=\(candidateTracker.committed), stt=\(String(format: "%.2f", sttElapsed))s)")
            return
        }

        let text = newly.joined(separator: " ")
        let polishStart = CFAbsoluteTimeGetCurrent()
        let polished = await polishWithPreceding(
            text, preceding: preceding, context: context)
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart

        let publication = lock.withLock {
            () -> (Bool, (@Sendable (String) async -> Void)?) in
            guard sessionGeneration == generation, !finishing,
                recognitionError == nil
            else { return (false, nil) }
            commitTracker = candidateTracker
            committedPolished = Self.joinPolished(committedPolished, polished)
            if chunkHandler != nil { didEmitChunks = true }
            return (true, chunkHandler)
        }
        guard publication.0 else { return }
        let handler = publication.1

        Log.debug("[LocalStreaming] Committed +\(newly.count) sentences (total=\(candidateTracker.committed), stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")

        // Emit for live injection. Skipped when no handler is set.
        if let handler {
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
