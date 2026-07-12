import Foundation

/// On-device streaming dictation with committed, rolling injection.
///
/// Accumulate PCM audio during recording. Every `cycleInterval` seconds,
/// re-transcribe the accumulated audio and hand it to a `CommitTracker`,
/// which returns the sentences that have become stable (unchanged since
/// the previous cycle and followed by more text). Those committed
/// sentences are polished and emitted through the chunk handler, so they
/// are injected at the cursor while the user keeps talking. This gives
/// hands-free rolling injection for long dictations.
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

    private let sttEngine: any LocalSTTEngine
    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String
    private let cycleInterval: TimeInterval

    /// The STT engine when it supports incremental streaming. When set,
    /// each cycle feeds only new audio instead of re-transcribing all of
    /// it, and finish only flushes the pending tail.
    private let incremental: NemotronEngine?

    // MARK: - State (guarded by lock)

    private let lock = NSLock()
    private var accumulatedAudio = Data()
    private var currentContext: AppContext = .empty

    /// Raw STT transcript from the last `finishStreaming()` call.
    public private(set) var lastRawTranscript: String = ""

    /// Full polished transcript (committed chunks plus final tail) from
    /// the last `finishStreaming()` call. Useful for diagnostics and
    /// sample collection even when `finishStreaming` returns only the
    /// tail because chunks were injected live.
    public private(set) var lastPolishedTranscript: String = ""

    /// Tracks which sentences have stabilized and been committed.
    private var commitTracker = CommitTracker()

    /// Incremental transcription session, when the engine supports it.
    private var streamingState: NemotronStreamingState?

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

    private var finishing = false
    private var backgroundTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        sttEngine: any LocalSTTEngine,
        polishChatClient: (any PolishChatClient)?,
        polishModel: String = PolishPipeline.polishModel,
        cycleInterval: TimeInterval = 3
    ) {
        self.sttEngine = sttEngine
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
        self.cycleInterval = cycleInterval
        self.incremental = sttEngine as? NemotronEngine
    }

    // MARK: - StreamingDictationProviding

    public var uncommittedAudioDuration: TimeInterval {
        let bytes = lock.withLock { accumulatedAudio.count }
        return Double(bytes) / 32_000.0
    }

    public func setChunkHandler(
        _ handler: (@Sendable (String) async -> Void)?
    ) {
        lock.withLock { chunkHandler = handler }
    }

    public func startStreaming(
        context: AppContext, language: String?, micProximity: MicProximity
    ) async throws {
        if !sttEngine.isReady {
            Log.debug("[LocalStreaming] Loading STT engine \(sttEngine.name)")
            try await sttEngine.load()
            Log.debug("[LocalStreaming] STT engine loaded")
        }
        let newState = try incremental?.makeStreamingState()
        lock.withLock {
            accumulatedAudio = Data()
            currentContext = context
            commitTracker = CommitTracker()
            committedPolished = ""
            lastRawTranscript = ""
            lastPolishedTranscript = ""
            didEmitChunks = false
            finishing = false
            streamingState = newState
            fedBytes = 0
        }

        backgroundTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runBackgroundCycles()
        }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        lock.withLock { accumulatedAudio.append(pcmData) }
    }

    public func finishStreaming() async throws -> String {
        lock.withLock { finishing = true }
        backgroundTask?.cancel()
        await backgroundTask?.value
        backgroundTask = nil

        let (audio, context, rolling, committedSoFar) = lock.withLock {
            (accumulatedAudio, currentContext, didEmitChunks, committedPolished)
        }

        guard !audio.isEmpty else {
            Log.debug("[LocalStreaming] No audio accumulated")
            lock.withLock { lastPolishedTranscript = committedSoFar }
            return rolling ? "" : committedSoFar
        }

        // Final transcription. With incremental streaming only the
        // pending tail is flushed; otherwise re-transcribe all audio.
        let sttStart = CFAbsoluteTimeGetCurrent()
        let raw: String
        if let incremental, let state = streamingState {
            let newAudio = lock.withLock { () -> Data in
                let end = accumulatedAudio.count
                let start = min(fedBytes, end)
                fedBytes = end
                return accumulatedAudio.subdata(in: start..<end)
            }
            if !newAudio.isEmpty {
                try incremental.feed(Self.pcmToFloat(newAudio), into: state)
            }
            raw = try incremental.finishStreaming(state)
        } else {
            let wav = WAVEncoder.encode(
                pcmData: audio, sampleRate: 16000, channels: 1,
                bitsPerSample: 16)
            raw = try await sttEngine.transcribe(audio: wav)
        }
        let sttElapsed = CFAbsoluteTimeGetCurrent() - sttStart

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { lastRawTranscript = trimmed }
        guard !trimmed.isEmpty else {
            lock.withLock { lastPolishedTranscript = committedSoFar }
            return rolling ? "" : committedSoFar
        }

        // Commit and polish everything not yet committed as one tail unit
        // so it gets full cross-sentence context.
        let tailSentences = lock.withLock {
            commitTracker.commitRemaining(trimmed)
        }
        let tailText = tailSentences.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let polishStart = CFAbsoluteTimeGetCurrent()
        var tailPolished = ""
        if !tailText.isEmpty {
            tailPolished = await polishWithPreceding(
                tailText, preceding: committedSoFar, context: context)
        }
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart

        let full = [committedSoFar, tailPolished]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        lock.withLock {
            lastPolishedTranscript = full
            accumulatedAudio = Data()
        }

        Log.debug("[LocalStreaming] Finish (committed=\(commitTracker.committed) tailSentences=\(tailSentences.count) rolling=\(rolling) stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")

        // When committed chunks were injected live, return only the tail.
        // Otherwise return the whole transcript.
        return rolling ? tailPolished : full
    }

    public func cancelStreaming() async {
        lock.withLock {
            accumulatedAudio = Data()
            didEmitChunks = false
            finishing = true
            streamingState = nil
            fedBytes = 0
        }
        backgroundTask?.cancel()
        await backgroundTask?.value
        backgroundTask = nil
    }

    // MARK: - Background Cycles

    private func runBackgroundCycles() async {
        try? await Task.sleep(nanoseconds: UInt64(cycleInterval * 1_000_000_000))

        while !Task.isCancelled {
            let isFinishing = lock.withLock { finishing }
            if isFinishing { break }

            await runOneCycle()

            try? await Task.sleep(nanoseconds: UInt64(cycleInterval * 1_000_000_000))
        }
    }

    private func runOneCycle() async {
        let context = lock.withLock { currentContext }

        let sttStart = CFAbsoluteTimeGetCurrent()
        let trimmed: String
        if let incremental, let state = streamingState {
            // Feed only audio arrived since the last cycle.
            let newAudio = lock.withLock { () -> Data in
                let end = accumulatedAudio.count
                let start = min(fedBytes, end)
                fedBytes = end
                return accumulatedAudio.subdata(in: start..<end)
            }
            if !newAudio.isEmpty {
                try? incremental.feed(Self.pcmToFloat(newAudio), into: state)
            }
            trimmed = incremental.transcript(state)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let audio = lock.withLock { accumulatedAudio }
            guard audio.count > 16_000 else { return }
            let wav = WAVEncoder.encode(
                pcmData: audio, sampleRate: 16000, channels: 1,
                bitsPerSample: 16)
            guard let raw = try? await sttEngine.transcribe(audio: wav)
            else { return }
            trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sttElapsed = CFAbsoluteTimeGetCurrent() - sttStart
        guard !trimmed.isEmpty else { return }

        // Commit any sentences that have stabilized since the last cycle.
        let (newly, preceding, isFinishing) = lock.withLock {
            (commitTracker.ingest(trimmed), committedPolished, finishing)
        }
        if isFinishing { return }
        guard !newly.isEmpty else {
            Log.debug("[LocalStreaming] Cycle: no new committed sentences (committed=\(commitTracker.committed), stt=\(String(format: "%.2f", sttElapsed))s)")
            return
        }

        let text = newly.joined(separator: " ")
        let polishStart = CFAbsoluteTimeGetCurrent()
        let polished = await polishWithPreceding(
            text, preceding: preceding, context: context)
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart

        let handler = lock.withLock {
            committedPolished = committedPolished.isEmpty
                ? polished : committedPolished + " " + polished
            return chunkHandler
        }

        Log.debug("[LocalStreaming] Committed +\(newly.count) sentences (total=\(commitTracker.committed), stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")

        // Emit for live injection. Skipped when no handler is set.
        if let handler {
            lock.withLock { didEmitChunks = true }
            await handler(polished)
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
            precedingText: precedingText)
    }
}
