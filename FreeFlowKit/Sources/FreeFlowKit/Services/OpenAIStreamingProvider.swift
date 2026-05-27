import Foundation

/// Stream audio directly to the OpenAI Realtime API for real-time
/// transcription.
///
/// Opens a WebSocket to `wss://api.openai.com/v1/realtime` per dictation
/// session. To avoid paying the handshake cost on every dictation, a
/// fresh connection is pre-opened in the background immediately after a
/// successful session, and adopted by the next `startStreaming` call.
/// A warm backup typically cuts `startStreaming` from ~300 ms to < 5 ms.
///
/// `startStreaming` is non-blocking: it kicks off the connection and
/// session.update in a background task and returns immediately. The
/// `sendAudio` and `finishStreaming` calls await the setup future
/// internally, so the audio forwarding task can begin draining chunks
/// into a buffer as soon as the pipeline starts it. Chunks that arrive
/// before the connection is configured are held and flushed once it is.
///
/// Session protocol:
///
///   1. Open WSS; send `session.update` to configure transcription-only
///      mode, manual commit, and mic-specific noise reduction.
///   2. Forward audio chunks as `input_audio_buffer.append` with
///      base64-encoded 24 kHz PCM (resampled from the 16 kHz capture).
///   3. On finish, send `input_audio_buffer.commit` and read events
///      until `conversation.item.input_audio_transcription.completed`.
///   4. Tear down the connection and polish the transcript locally.
///   5. Pre-open a new backup connection in the background.
public final class OpenAIStreamingProvider: StreamingDictationProviding, @unchecked Sendable {

    // MARK: - Configuration

    private let apiKeyProvider: @Sendable () -> String
    private let realtimeModel: String
    private let sttModel: String
    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String
    private let chunkingStrategy: ChunkingStrategy

    /// How long after the last detected speech to keep reporting the
    /// speaker as "still speaking". Set high (10 s) so only a genuine
    /// extended silence triggers a chunk commit — not thinking pauses
    /// or natural breaks between sentences.
    private let speechDebounceSeconds: TimeInterval = 10.0

    // MARK: - State (guarded by lock)

    private let lock = NSLock()

    /// Active session's WebSocket task, if any.
    private var webSocketTask: URLSessionWebSocketTask?

    /// Active session's URLSession, kept alive with the task.
    private var urlSession: URLSession?

    /// Background task that opens the connection and sends session.update.
    /// `sendAudio` and `finishStreaming` await this future before using
    /// the active task.
    private var setupTask: Task<Void, Error>?

    /// Chunks that arrive before the setup task finishes. Flushed in
    /// order once the connection is ready.
    private var pendingAudio: [Data] = []

    /// Raw transcript text accumulated from intermediate chunks that
    /// have not yet reached a sentence boundary. Flushed when the
    /// buffer ends with sentence-ending punctuation, or prepended to
    /// the final transcript in `finishStreaming`.
    private var rawChunkBuffer: String = ""

    /// AppContext for the current session (captured at startStreaming).
    private var currentContext: AppContext = .empty

    /// Language hint for the current session.
    private var currentLanguage: String?

    /// Monotonically increasing session counter for diagnostic logging.
    private var nextSessionID: Int = 1

    /// Timing breakdown for the active `startStreaming`/`finishStreaming`
    /// session. Lives under the lock; a fresh struct is installed in
    /// `startStreaming` and emitted as a summary line at the end of
    /// `finishStreaming` (or on error).
    private var currentTiming: SessionTiming?

    /// Per-session timing and decision breakdown. Every timestamp is
    /// populated as the session progresses; the summary log line in
    /// `emitSessionSummary` prints every field that was set.
    struct SessionTiming {
        var id: Int
        var startedAt: Date
        var setupKind: SetupKind = .pending
        var setupCompletedAt: Date?
        var audioBytesSent: Int = 0
        var audioChunksSent: Int = 0
        var commitSentAt: Date?
        var firstDeltaAt: Date?
        var transcriptCompletedAt: Date?
        var polishStartedAt: Date?
        var polishKind: PolishKind = .pending
        var polishFinishedAt: Date?
        var endedAt: Date?
        var error: String?

        enum SetupKind: String {
            case pending
            case freshConnection = "fresh"
            case adoptedBackup = "backup"
            case adoptedStaleBackup = "stale-backup"
        }

        enum PolishKind: String {
            case pending
            case skip = "skip"
            case llmOK = "llm-ok"
            case llmFailed = "llm-failed"
            case llmEmpty = "llm-empty"
            case noChatClient = "no-llm"
        }
    }

    // MARK: - Chunking (rolling commits during a streaming session)

    /// Called with each intermediate chunk's polished text. When nil,
    /// no mid-session commits fire and the session behaves like a
    /// single-commit run.
    private var chunkHandler: (@Sendable (String) async -> Void)?

    /// When the current chunk started accumulating audio. Reset on
    /// each commit (intermediate or final) and at session start.
    private var currentChunkStartedAt: Date?

    /// Bytes appended to the Realtime buffer since the last commit.
    /// Only fire a commit when this is > 0 to avoid the server-side
    /// "empty buffer" error.
    private var audioBytesSinceLastCommit: Int = 0

    /// Last time speech (RMS above the default silence threshold) was
    /// detected in an incoming audio chunk.
    private var lastSpeechAt: Date?

    /// Total commits issued on the current session's WebSocket.
    private var commitsSentCount: Int = 0

    /// Set to true when `finishStreaming` sends its final commit.
    /// The reader uses this to recognize the last completion.
    private var finalCommitSent: Bool = false

    /// Reader task that processes `transcription.completed` events on
    /// the WebSocket and routes each one to either the chunk handler
    /// (intermediate) or the final-chunk stream (last).
    private var chunkReaderTask: Task<Void, Never>?

    /// One-shot stream used by the reader to deliver the final
    /// chunk's polished text to `finishStreaming`.
    private var finalChunkStream: AsyncThrowingStream<String, Error>?
    private var finalChunkContinuation: AsyncThrowingStream<String, Error>.Continuation?

    // MARK: - Backup connection (warm standby)

    /// Pre-opened connection ready to be adopted by the next session.
    private var backupTask: URLSessionWebSocketTask?
    private var backupSession: URLSession?
    private var backupOpenedAt: Date?
    private var backupOpenTask: Task<Void, Never>?

    /// Background task that refreshes the backup before it goes stale.
    private var backupRefreshTask: Task<Void, Never>?

    /// Maximum age for an idle backup connection. After this, the backup
    /// is discarded on use and a fresh one is opened.
    private let maxBackupAge: TimeInterval = 180

    // MARK: - Init

    public init(
        apiKey: @autoclosure @escaping @Sendable () -> String,
        realtimeModel: String = "gpt-realtime",
        sttModel: String = "gpt-4o-mini-transcribe",
        polishChatClient: (any PolishChatClient)?,
        polishModel: String = PolishPipeline.polishModel,
        chunkingStrategy: ChunkingStrategy = TimeAndSilenceChunkingStrategy()
    ) {
        self.apiKeyProvider = apiKey
        self.realtimeModel = realtimeModel
        self.sttModel = sttModel
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
        self.chunkingStrategy = chunkingStrategy
    }

    deinit {
        let (reader, ws, session, bOpen, bTask, bSession, bRefresh) = lock.withLock {
            (chunkReaderTask, webSocketTask, urlSession,
             backupOpenTask, backupTask, backupSession, backupRefreshTask)
        }
        reader?.cancel()
        bOpen?.cancel()
        bRefresh?.cancel()
        bTask?.cancel(with: .normalClosure, reason: nil)
        bSession?.invalidateAndCancel()
        ws?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - StreamingDictationProviding

    public var uncommittedAudioDuration: TimeInterval {
        // audioBytesSinceLastCommit is 24 kHz 16-bit mono = 48,000 bytes/sec.
        lock.withLock { TimeInterval(self.audioBytesSinceLastCommit) / 48_000.0 }
    }

    public func setChunkHandler(_ handler: (@Sendable (String) async -> Void)?) {
        lock.withLock { self.chunkHandler = handler }
    }

    public func startStreaming(
        context: AppContext, language: String?, micProximity: MicProximity
    ) async throws {
        try Task.checkCancellation()

        // Warn if a session is already active — callers should cancel
        // or finish the previous session before starting a new one.
        if lock.withLock({ currentTiming != nil }) {
            Log.debug("[OpenAIRealtime] startStreaming called while a session is active")
            assertionFailure("startStreaming called while a session is active")
        }

        // Install a fresh timing record and reset chunking state.
        let sessionID: Int = lock.withLock {
            let id = self.nextSessionID
            self.nextSessionID += 1
            self.currentContext = context
            self.currentLanguage = language
            self.pendingAudio.removeAll()
            self.rawChunkBuffer = ""
            self.currentTiming = SessionTiming(id: id, startedAt: Date())
            self.currentChunkStartedAt = Date()
            self.audioBytesSinceLastCommit = 0
            self.lastSpeechAt = nil
            self.commitsSentCount = 0
            self.finalCommitSent = false
            return id
        }

        // Set up the one-shot stream used by the reader to deliver the
        // final chunk to finishStreaming.
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        lock.withLock {
            self.finalChunkStream = stream
            self.finalChunkContinuation = continuation
        }

        // Try to adopt a fresh backup connection. If the backup is missing
        // or stale, open a new one. Either way, store the setup future so
        // sendAudio and finishStreaming can await it.
        let adoption = adoptBackupIfFresh()
        let adopted = adoption.adopted
        let staleBackup = adoption.discardedStale

        lock.withLock {
            self.currentTiming?.setupKind =
                adopted != nil
                ? .adoptedBackup
                : (staleBackup ? .adoptedStaleBackup : .freshConnection)
        }

        let freshModel = realtimeModel
        let freshAPIKey = apiKeyProvider()
        let freshSTTModel = sttModel

        let setup = Task { [weak self] in
            try Task.checkCancellation()
            guard let self else { return }

            let task: URLSessionWebSocketTask
            let session: URLSession

            if let adopted {
                task = adopted.task
                session = adopted.session
            } else {
                let (newTask, newSession) = try Self.buildWebSocketTask(
                    apiKey: freshAPIKey, model: freshModel)
                newTask.resume()
                task = newTask
                session = newSession
            }

            // If cancelled after building but before publishing, clean
            // up the locally held task/session and bail. Without this,
            // cancelStreaming running between these lines could leave a
            // stale task in webSocketTask for the next session.
            if Task.isCancelled {
                task.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
                throw CancellationError()
            }

            // Publish the task immediately so tearDown can reach it even
            // if session.update fails.
            self.lock.withLock {
                self.webSocketTask = task
                self.urlSession = session
            }

            // Send session.update to configure transcription-only mode.
            let update = Self.buildSessionUpdate(
                sttModel: freshSTTModel,
                language: language,
                micProximity: micProximity)
            try await task.send(.string(update))

            // Record setup completion for the diagnostic summary.
            self.lock.withLock {
                if self.currentTiming?.id == sessionID {
                    self.currentTiming?.setupCompletedAt = Date()
                }
            }
        }
        lock.withLock { self.setupTask = setup }

        // Spawn a reader that processes transcription.completed events
        // for the lifetime of the session. Intermediate chunks (commits
        // from sendAudio) go to the chunk handler; the final chunk
        // (commit from finishStreaming) goes to the finalChunkStream.
        let reader = Task { [weak self] in
            guard let self else { return }
            do {
                // Wait for the WS to be ready before reading.
                try await self.awaitSetup()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let task: URLSessionWebSocketTask? = self.lock.withLock { self.webSocketTask }
            guard let task else {
                continuation.finish(
                    throwing: DictationError.networkError("No active WebSocket"))
                return
            }

            var chunksRead = 0
            do {
                while !Task.isCancelled {
                    let transcript = try await Self.readTranscriptUntilCompleted(
                        on: task,
                        onFirstDelta: { [weak self] in
                            self?.lock.withLock {
                                if self?.currentTiming?.firstDeltaAt == nil {
                                    self?.currentTiming?.firstDeltaAt = Date()
                                }
                            }
                        }
                    )
                    chunksRead += 1

                    let (isFinal, handler) = self.lock.withLock {
                        () -> (Bool, (@Sendable (String) async -> Void)?) in
                        let isFinal =
                            self.finalCommitSent
                            && chunksRead == self.commitsSentCount
                        return (isFinal, isFinal ? nil : self.chunkHandler)
                    }

                    let trimmed = transcript
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if isFinal {
                        self.lock.withLock {
                            self.currentTiming?.transcriptCompletedAt = Date()
                        }
                        continuation.yield(trimmed)
                        continuation.finish()
                        return
                    }

                    // Intermediate chunk — buffer until sentence boundary.
                    if !trimmed.isEmpty, let handler {
                        let accumulated: String = self.lock.withLock {
                            if self.rawChunkBuffer.isEmpty {
                                self.rawChunkBuffer = trimmed
                            } else {
                                self.rawChunkBuffer += " " + trimmed
                            }
                            return self.rawChunkBuffer
                        }

                        if PolishPipeline.endsAtSentenceBoundary(accumulated) {
                            self.lock.withLock { self.rawChunkBuffer = "" }
                            let polished = await self.polishChunk(accumulated)
                            Log.debug(
                                "[RealtimeChunk] session=\(sessionID)"
                                + " chunk=\(chunksRead)"
                                + " chars=\(polished.count)"
                                + " raw=\(accumulated.count)")
                            await handler(polished)
                        } else {
                            Log.debug(
                                "[RealtimeChunk] session=\(sessionID)"
                                + " chunk=\(chunksRead)"
                                + " buffered, len=\(accumulated.count)")
                        }
                    }
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        lock.withLock { self.chunkReaderTask = reader }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        guard !pcmData.isEmpty else { return }

        // Track speech for the chunking strategy's silence trigger.
        let rms = AudioLevelAnalyzer.rmsLevel(pcm16: pcmData)
        if rms > 0.005 {
            lock.withLock { self.lastSpeechAt = Date() }
        }

        // Resample from 16 kHz capture rate to 24 kHz required by the
        // Realtime API.
        let pcm24k = AudioResampler.resample16kTo24k(pcmData)

        // Await the setup future. If setup failed, drop the chunk —
        // the caller will see the error and stop sending.
        try await awaitSetup()

        let task: URLSessionWebSocketTask? = lock.withLock { self.webSocketTask }
        guard let task else {
            throw DictationError.networkError("No active WebSocket")
        }

        do {
            // Flush any buffered chunks first to preserve order.
            try await flushPendingAudio(to: task)
            try await sendChunk(pcm24k, to: task)
        } catch {
            // A send failure almost always means the WebSocket is dead.
            // Record the error on the current session so it appears in
            // the summary when `finishStreaming` (or `cancelStreaming`)
            // eventually emits it, rather than leaving the timing
            // record orphaned.
            lock.withLock {
                if self.currentTiming?.error == nil {
                    self.currentTiming?.error = error.localizedDescription
                }
            }
            throw error
        }

        // Check whether the chunking strategy wants to commit now.
        let shouldCommit: Bool = lock.withLock {
            guard self.chunkHandler != nil,
                self.audioBytesSinceLastCommit > 0,
                let chunkStart = self.currentChunkStartedAt
            else { return false }
            let sinceLastCommit = Date().timeIntervalSince(chunkStart)
            let lastSpeech = self.lastSpeechAt ?? Date.distantPast
            let isSpeaking =
                Date().timeIntervalSince(lastSpeech) < self.speechDebounceSeconds
            return self.chunkingStrategy.shouldCommitNow(
                sinceLastCommitSeconds: sinceLastCommit,
                isSpeaking: isSpeaking)
        }

        if shouldCommit {
            do {
                try await task.send(.string(Self.buildCommit()))
                lock.withLock {
                    self.commitsSentCount += 1
                    self.audioBytesSinceLastCommit = 0
                    self.currentChunkStartedAt = Date()
                }
            } catch {
                lock.withLock {
                    if self.currentTiming?.error == nil {
                        self.currentTiming?.error = error.localizedDescription
                    }
                }
                throw error
            }
        }
    }

    public func finishStreaming() async throws -> String {
        // Emit the session summary on every error path so a dropped
        // primary session is always visible in the log. Collects the
        // error on the timing record before tearing down.
        func fail(_ error: Error) async -> Error {
            lock.withLock {
                if self.currentTiming?.error == nil {
                    self.currentTiming?.error = error.localizedDescription
                }
                self.currentTiming?.endedAt = Date()
            }
            emitSessionSummary()
            let reader = lock.withLock { () -> Task<Void, Never>? in
                let r = self.chunkReaderTask
                self.chunkReaderTask = nil
                return r
            }
            reader?.cancel()
            await tearDown()
            return error
        }

        do {
            try await awaitSetup()
        } catch {
            throw await fail(error)
        }

        let task: URLSessionWebSocketTask? = lock.withLock { self.webSocketTask }
        guard let task else {
            throw await fail(
                DictationError.networkError("No active WebSocket"))
        }

        // Flush any remaining buffered audio before committing.
        do {
            try await flushPendingAudio(to: task)
        } catch {
            throw await fail(error)
        }

        // Send the final commit if there is audio to commit. Mark
        // finalCommitSent so the reader knows the next completion
        // is the last one.
        let hasAudio: Bool = lock.withLock { self.audioBytesSinceLastCommit > 0 }
        if hasAudio {
            do {
                try await task.send(.string(Self.buildCommit()))
                lock.withLock {
                    self.commitsSentCount += 1
                    self.audioBytesSinceLastCommit = 0
                    self.finalCommitSent = true
                    self.currentTiming?.commitSentAt = Date()
                }
            } catch {
                throw await fail(error)
            }
        } else {
            // No new audio since the last chunk commit — nothing to
            // transcribe. Tell the reader to stop and return empty.
            lock.withLock { self.finalCommitSent = true }
            let cont = lock.withLock { self.finalChunkContinuation }
            cont?.yield("")
            cont?.finish()
        }

        // Wait for the reader to deliver the final chunk through the
        // one-shot stream, with a scaled timeout.
        let bytesSent: Int = lock.withLock {
            self.currentTiming?.audioBytesSent ?? 0
        }
        let transcriptTimeout = Self.transcriptTimeout(forAudioBytes: bytesSent)
        let transcript: String
        do {
            transcript = try await withThrowingTaskGroup(of: String.self) { [weak self] group in
                group.addTask {
                    guard let stream = self?.lock.withLock({ self?.finalChunkStream }) else {
                        throw DictationError.networkError("No final chunk stream")
                    }
                    for try await text in stream {
                        return text
                    }
                    return ""
                }
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64(transcriptTimeout * 1_000_000_000))
                    task.cancel(with: .abnormalClosure, reason: nil)
                    throw DictationError.networkError(
                        "Timed out waiting for transcript after \(Int(transcriptTimeout))s")
                }
                guard let result = try await group.next() else {
                    group.cancelAll()
                    throw DictationError.networkError(
                        "No result from transcript race")
                }
                group.cancelAll()
                return result
            }
        } catch {
            throw await fail(error)
        }

        // Tear down the current session's connection and spawn a new
        // backup in the background for the next session.
        let doneReader = lock.withLock { () -> Task<Void, Never>? in
            let r = self.chunkReaderTask
            self.chunkReaderTask = nil
            return r
        }
        doneReader?.cancel()
        await tearDown()
        warmBackup()

        // Prepend any buffered raw text from intermediate chunks that
        // did not reach a sentence boundary before the session ended.
        let bufferedRaw: String = lock.withLock {
            let buf = self.rawChunkBuffer
            self.rawChunkBuffer = ""
            return buf
        }
        let fullTranscript: String
        if bufferedRaw.isEmpty {
            fullTranscript = transcript
        } else if transcript.isEmpty {
            fullTranscript = bufferedRaw
        } else {
            fullTranscript = bufferedRaw + " " + transcript
        }

        // Polish the raw transcript locally.
        if fullTranscript.isEmpty {
            lock.withLock {
                self.currentTiming?.polishKind = .skip
                self.currentTiming?.endedAt = Date()
            }
            emitSessionSummary()
            return ""
        }
        let polished = await polish(fullTranscript)
        lock.withLock {
            self.currentTiming?.endedAt = Date()
        }
        emitSessionSummary()
        return polished
    }

    public func cancelStreaming() async {
        let cancelSetup: Task<Void, Error>? = lock.withLock {
            let s = self.setupTask
            self.setupTask = nil
            return s
        }
        cancelSetup?.cancel()
        lock.withLock {
            self.rawChunkBuffer = ""
            self.finalChunkContinuation?.finish()
            self.finalChunkContinuation = nil
            self.finalChunkStream = nil
            if self.currentTiming != nil {
                self.currentTiming?.endedAt = Date()
                if self.currentTiming?.error == nil {
                    self.currentTiming?.error = "cancelled"
                }
            }
        }
        emitSessionSummary()
        // Tear down the WebSocket before cancelling the reader task.
        // URLSessionWebSocketTask.receive() does not respond to Swift
        // task cancellation — it only returns when the WebSocket is
        // closed or receives a message. Closing the socket first
        // unblocks the reader immediately.
        await tearDown()
        let cancelReader: Task<Void, Never>? = lock.withLock {
            let r = self.chunkReaderTask
            self.chunkReaderTask = nil
            return r
        }
        cancelReader?.cancel()
    }

    /// Disconnect and release all connections. Call at app shutdown.
    public func disconnect() async {
        lock.withLock { self.setupTask }?.cancel()
        backupOpenTask?.cancel()
        await tearDown()
        await discardBackup()
    }

    // MARK: - Setup future

    /// Await the setup task, returning when the connection is ready and
    /// session.update has been sent. Throws any setup error.
    private func awaitSetup() async throws {
        guard let task = lock.withLock({ self.setupTask }) else {
            throw DictationError.networkError("No active streaming session")
        }
        try await task.value
    }

    // MARK: - Session diagnostics

    /// Emit a structured single-line summary of the current session's
    /// timing and decisions to the debug log, then clear the timing
    /// record. Call at the end of `finishStreaming` and on error paths.
    ///
    /// Format (fields without data are omitted):
    ///
    ///     [RealtimeSession] id=42 setup=backup setup_wait=0.001 bytes=64000
    ///     chunks=5 commit_wait=0.352 first_delta=0.087 transcript=0.410
    ///     polish=llm-ok(0.318) total=0.674
    private func emitSessionSummary() {
        let timing: SessionTiming? = lock.withLock {
            let t = self.currentTiming
            self.currentTiming = nil
            return t
        }
        guard let t = timing else { return }
        Log.debug(Self.formatSessionSummary(t))
    }

    /// Format a session summary line. Pure function so the behavior is
    /// unit-testable without having to run a live session.
    static func formatSessionSummary(_ t: SessionTiming) -> String {
        func fmt(_ seconds: TimeInterval) -> String {
            String(format: "%.3f", seconds)
        }

        var parts: [String] = ["[RealtimeSession] id=\(t.id)"]
        parts.append("setup=\(t.setupKind.rawValue)")

        if let setupCompleted = t.setupCompletedAt {
            parts.append("setup_wait=\(fmt(setupCompleted.timeIntervalSince(t.startedAt)))")
        }
        if t.audioBytesSent > 0 {
            parts.append("bytes=\(t.audioBytesSent)")
            parts.append("chunks=\(t.audioChunksSent)")
        }
        if let commitSent = t.commitSentAt {
            if let firstDelta = t.firstDeltaAt {
                parts.append("first_delta=\(fmt(firstDelta.timeIntervalSince(commitSent)))")
            }
            if let completed = t.transcriptCompletedAt {
                parts.append("transcript=\(fmt(completed.timeIntervalSince(commitSent)))")
            }
        }
        if let polishStart = t.polishStartedAt,
            let polishEnd = t.polishFinishedAt
        {
            parts.append(
                "polish=\(t.polishKind.rawValue)(\(fmt(polishEnd.timeIntervalSince(polishStart))))"
            )
        } else if t.polishKind != .pending {
            parts.append("polish=\(t.polishKind.rawValue)")
        }
        if let end = t.endedAt {
            parts.append("total=\(fmt(end.timeIntervalSince(t.startedAt)))")
        }
        if let error = t.error {
            parts.append("error=\"\(error.replacingOccurrences(of: "\"", with: "'"))\"")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Backup connection

    /// Spawn a background task that opens a new connection for the next
    /// session. No-op if one is already in flight or ready.
    private func warmBackup() {
        let bApiKey = apiKeyProvider()
        let bModel = realtimeModel
        let startedAt = Date()

        // Atomically check eligibility and assign backupOpenTask in the
        // same lock scope to prevent duplicate backup spawns.
        var captured: Task<Void, Never>?
        let openTask = Task { [weak self] in
            do {
                let (task, session) = try Self.buildWebSocketTask(
                    apiKey: bApiKey, model: bModel)
                task.resume()
                // Don't send any messages on the backup — it stays idle
                // until adopted by a future startStreaming call.
                guard !Task.isCancelled else {
                    task.cancel(with: .normalClosure, reason: nil)
                    session.invalidateAndCancel()
                    return
                }
                self?.lock.withLock {
                    self?.backupTask = task
                    self?.backupSession = session
                    self?.backupOpenedAt = Date()
                    self?.backupOpenTask = nil
                }
                Log.debug(
                    String(
                        format: "[RealtimeBackup] ready after %.3fs",
                        Date().timeIntervalSince(startedAt)))
                // Schedule a background refresh so the backup is
                // replaced before it goes stale. Sleep until 10s
                // before maxBackupAge, then discard and re-open.
                self?.scheduleBackupRefresh()
            } catch {
                self?.lock.withLock {
                    self?.backupOpenTask = nil
                }
                Log.debug(
                    "[RealtimeBackup] open failed: \(error.localizedDescription)")
            }
        }

        captured = openTask
        lock.withLock {
            if self.backupTask != nil || self.backupOpenTask != nil {
                captured = nil  // another thread won; cancel ours
            } else {
                self.backupOpenTask = openTask
            }
        }
        if captured == nil {
            openTask.cancel()
        }
    }

    /// Schedule a background task that replaces the backup connection
    /// before it goes stale. Sleeps until 10s before `maxBackupAge`,
    /// then discards the old connection and opens a fresh one.
    private func scheduleBackupRefresh() {
        let refreshDelay = max(10, maxBackupAge - 10)
        lock.withLock {
            backupRefreshTask?.cancel()
        }
        let task = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(refreshDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Only refresh if the backup hasn't been adopted or
            // replaced by another session in the meantime.
            let shouldRefresh: Bool = self.lock.withLock {
                self.backupTask != nil
            }
            guard shouldRefresh else { return }
            Log.debug("[RealtimeBackup] refreshing before staleness")
            await self.discardBackup()
            self.warmBackup()
        }
        lock.withLock {
            backupRefreshTask = task
        }
    }

    /// Outcome of an attempt to adopt the warm backup connection as the
    /// active one for a new session.
    private struct BackupAdoption {
        /// The adopted connection, or nil if none was available or if
        /// the backup was too old.
        let adopted: (task: URLSessionWebSocketTask, session: URLSession)?
        /// Whether a stale backup existed and had to be discarded. Used
        /// by diagnostic logging to distinguish "no backup existed" from
        /// "backup existed but was stale".
        let discardedStale: Bool
    }

    /// Attempt to adopt a fresh backup as the active connection.
    ///
    /// A stale backup (older than `maxBackupAge`) is discarded instead
    /// of adopted, and the caller must open a fresh connection.
    private func adoptBackupIfFresh() -> BackupAdoption {
        enum Outcome {
            case adopted(URLSessionWebSocketTask, URLSession, age: TimeInterval)
            case stale
            case none
        }

        let outcome: Outcome = lock.withLock {
            guard let task = self.backupTask,
                let session = self.backupSession,
                let openedAt = self.backupOpenedAt
            else {
                return .none
            }
            let age = Date().timeIntervalSince(openedAt)
            if age > self.maxBackupAge {
                return .stale
            }
            self.backupTask = nil
            self.backupSession = nil
            self.backupOpenedAt = nil
            return .adopted(task, session, age: age)
        }

        switch outcome {
        case .adopted(let task, let session, let age):
            // Cancel the refresh task — the backup is now in use.
            lock.withLock { backupRefreshTask?.cancel(); backupRefreshTask = nil }
            Log.debug(
                String(
                    format: "[RealtimeBackup] adopt age=%.3fs", age))
            return BackupAdoption(adopted: (task, session), discardedStale: false)
        case .stale:
            Log.debug("[RealtimeBackup] stale, discarding")
            Task { await self.discardBackup() }
            return BackupAdoption(adopted: nil, discardedStale: true)
        case .none:
            return BackupAdoption(adopted: nil, discardedStale: false)
        }
    }

    /// Tear down and forget any pre-opened backup connection.
    private func discardBackup() async {
        let (task, session): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let t = self.backupTask
            let s = self.backupSession
            self.backupTask = nil
            self.backupSession = nil
            self.backupOpenedAt = nil
            return (t, s)
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - Audio send helpers

    /// Drain all buffered audio chunks and send each one to the task.
    private func flushPendingAudio(to task: URLSessionWebSocketTask) async throws {
        let buffered: [Data] = lock.withLock {
            let b = self.pendingAudio
            self.pendingAudio.removeAll()
            return b
        }
        for chunk in buffered {
            try await sendChunk(chunk, to: task)
        }
    }

    /// Encode a PCM chunk as an audio-append message, send it on the
    /// WebSocket, and update the timing/byte counters.
    private func sendChunk(_ pcm24k: Data, to task: URLSessionWebSocketTask) async throws {
        let msg = Self.buildAudioAppend(pcm24k: pcm24k)
        try await task.send(.string(msg))
        recordChunkSent(byteCount: pcm24k.count)
    }

    /// Update timing and byte counters after a chunk is sent.
    private func recordChunkSent(byteCount: Int) {
        lock.withLock {
            self.currentTiming?.audioBytesSent += byteCount
            self.currentTiming?.audioChunksSent += 1
            self.audioBytesSinceLastCommit += byteCount
        }
    }

    // MARK: - Connection lifecycle

    /// Compute the hard timeout for waiting on a transcription result
    /// given the number of 24 kHz 16-bit PCM bytes that were sent.
    ///
    /// Short dictations keep a fast-fail floor of 15 s. Long ones get a
    /// proportional budget so the Realtime API has time to finalize the
    /// tail of a long audio buffer (observed up to ~7 s on a 70 s
    /// dictation). The ceiling at 300 s matches the URLSession request
    /// timeout so the WebSocket's own timeout stays one layer higher.
    static func transcriptTimeout(forAudioBytes bytes: Int) -> TimeInterval {
        // 24 kHz 16-bit mono = 48_000 bytes/s.
        let duration = TimeInterval(bytes) / 48_000.0
        let budget = 15.0 + duration * 0.5
        return min(300.0, max(15.0, budget))
    }

    /// Build a fresh URLSessionWebSocketTask for the OpenAI Realtime API.
    ///
    /// The URLSessionConfiguration's `timeoutIntervalForRequest` applies to
    /// the interval between data packets on the WebSocket, not the total
    /// connection lifetime. We set it to 300 s so that a long idle window
    /// during transcription of a long audio buffer does not drop the
    /// connection mid-session. Previously this was the default (60 s),
    /// which caused `NSPOSIXErrorDomain Code=57 "Socket is not connected"`
    /// failures on dictations longer than about a minute.
    static func buildWebSocketTask(
        apiKey: String, model: String
    ) throws -> (URLSessionWebSocketTask, URLSession) {
        let url = buildWebSocketURL(model: model)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        let session = URLSession(configuration: config)
        return (session.webSocketTask(with: request), session)
    }

    /// Tear down the active session's WebSocket and URLSession.
    private func tearDown() async {
        let (task, session): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let t = self.webSocketTask
            let s = self.urlSession
            self.webSocketTask = nil
            self.urlSession = nil
            self.setupTask = nil
            self.pendingAudio.removeAll()
            self.rawChunkBuffer = ""
            self.finalChunkContinuation?.finish()
            self.finalChunkContinuation = nil
            self.finalChunkStream = nil
            return (t, s)
        }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - Message builders (testable pure functions)

    /// Build the Realtime API WebSocket URL for the given model.
    static func buildWebSocketURL(model: String) -> URL {
        var components = URLComponents(
            string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url!
    }

    /// Build the `session.update` message to configure transcription-only
    /// mode with manual commit.
    static func buildSessionUpdate(
        sttModel: String,
        language: String?,
        micProximity: MicProximity
    ) -> String {
        var transcription: [String: Any] = [
            "model": sttModel,
        ]
        if let language {
            transcription["language"] = language
        }

        let session: [String: Any] = [
            "type": "realtime",
            "audio": [
                "input": [
                    "format": [
                        "type": "audio/pcm",
                        "rate": 24000,
                    ],
                    "transcription": transcription,
                    // NSNull serializes as JSON null, which disables
                    // server VAD so the client controls when audio
                    // ends via commit.
                    "turn_detection": NSNull(),
                ],
            ],
        ]

        return jsonString([
            "type": "session.update",
            "session": session,
        ])
    }

    /// Build an `input_audio_buffer.append` message wrapping base64 PCM.
    static func buildAudioAppend(pcm24k: Data) -> String {
        jsonString([
            "type": "input_audio_buffer.append",
            "audio": pcm24k.base64EncodedString(),
        ])
    }

    /// Build the `input_audio_buffer.commit` message.
    static func buildCommit() -> String {
        jsonString(["type": "input_audio_buffer.commit"])
    }

    // MARK: - Event parsing (testable pure function)

    enum ParsedEvent: Equatable {
        case transcriptionDelta(String)
        case transcriptionCompleted(String)
        case error(String)
        case other
    }

    static func parseEvent(_ text: String) -> ParsedEvent {
        guard
            let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else {
            return .other
        }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            let transcript = obj["transcript"] as? String ?? ""
            return .transcriptionCompleted(transcript)
        case "conversation.item.input_audio_transcription.delta":
            let delta = obj["delta"] as? String ?? ""
            return .transcriptionDelta(delta)
        case "error":
            if let error = obj["error"] as? [String: Any],
                let message = error["message"] as? String
            {
                return .error(message)
            }
            return .error("unknown error")
        default:
            return .other
        }
    }

    // MARK: - WebSocket receive

    /// Read events on a task until the first `transcription.completed`
    /// arrives or an error is received. Other event types are discarded.
    ///
    /// - Parameter onFirstDelta: Optional callback invoked the first
    ///   time a `transcription.delta` event arrives on the connection.
    ///   Used by the diagnostic summary to record when the model starts
    ///   returning partial text — the gap between commit and first
    ///   delta is the closest thing to "time-to-first-token" this API
    ///   exposes.
    static func readTranscriptUntilCompleted(
        on task: URLSessionWebSocketTask,
        onFirstDelta: (@Sendable () -> Void)? = nil
    ) async throws -> String {
        var firstDeltaReported = false
        while true {
            try Task.checkCancellation()
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw DictationError.networkError(
                    "WebSocket receive failed: \(error.localizedDescription)")
            }

            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
            @unknown default: continue
            }

            switch parseEvent(text) {
            case .transcriptionCompleted(let transcript):
                return transcript
            case .error(let message):
                throw DictationError.networkError(
                    "Realtime API error: \(message)")
            case .transcriptionDelta:
                if !firstDeltaReported {
                    firstDeltaReported = true
                    onFirstDelta?()
                }
                continue
            case .other:
                continue
            }
        }
    }

    // MARK: - Polishing

    /// Polish an intermediate chunk. Same pipeline as `polish` but does
    /// not update `currentTiming` — intermediate chunks have their own
    /// `[RealtimeChunk]` log lines.
    private func polishChunk(_ raw: String) async -> String {
        await polishText(raw, updateTiming: false)
    }

    private func polish(_ raw: String) async -> String {
        await polishText(raw, updateTiming: true)
    }

    /// Shared polishing implementation. When `updateTiming` is true,
    /// record polish start/end and outcome on `currentTiming`.
    private func polishText(_ raw: String, updateTiming: Bool) async -> String {
        if updateTiming {
            lock.withLock {
                self.currentTiming?.polishStartedAt = Date()
            }
        }

        let (context, language): (AppContext, String?) = lock.withLock {
            (self.currentContext, self.currentLanguage)
        }

        let casual = PolishPipeline.toneLabel(for: context.bundleID) == "casual"
        let substituted = PolishPipeline.substituteDictatedPunctuation(
            raw, casual: casual,
            precedingText: context.focusedFieldContent)
        let stripped = PolishPipeline.stripKeepTags(
            substituted, casual: casual)

        guard let polishChatClient else {
            if updateTiming {
                lock.withLock {
                    self.currentTiming?.polishKind = .noChatClient
                    self.currentTiming?.polishFinishedAt = Date()
                }
            }
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }

        let systemPrompt = PolishPipeline.buildCloudSystemPrompt(
            context: context, language: language)
        let userPrompt = PolishPipeline.buildUserPrompt(
            substituted, context: context, language: language)

        do {
            let polished = try await polishChatClient.complete(
                model: polishModel,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt)
            if polished.isEmpty {
                if updateTiming {
                    lock.withLock {
                        self.currentTiming?.polishKind = .llmEmpty
                        self.currentTiming?.polishFinishedAt = Date()
                    }
                }
                return PolishPipeline.normalizeFormatting(
                    stripped, casual: casual)
            }
            if updateTiming {
                lock.withLock {
                    self.currentTiming?.polishKind = .llmOK
                    self.currentTiming?.polishFinishedAt = Date()
                }
            }
            let cleaned = PolishPipeline.guardAgainstEcho(
                polished: polished,
                precedingText: context.focusedFieldContent)
            let guarded: String
            if let fallback = PolishPipeline.guardAgainstTruncation(
                polished: cleaned, preprocessed: stripped) {
                guarded = fallback
            } else {
                guarded = cleaned
            }
            let untagged = PolishPipeline.stripKeepTags(
                guarded, casual: casual)
            let normalized = PolishPipeline.normalizeFormatting(
                untagged, casual: casual)
            let cased = PolishPipeline.matchInputCasing(
                normalized, preprocessedInput: substituted,
                casual: casual)
            let noPreceding = context.focusedFieldContent == nil
                || context.focusedFieldContent!.isEmpty
            let result = PolishPipeline.adjustFirstCharCasing(
                cased, preprocessed: stripped, casual: casual,
                noPreceding: noPreceding)
            if stripped != result {
                Log.debug("[Polish] CHANGED: \"\(stripped)\" → \"\(result)\"")
            }
            return result
        } catch {
            if updateTiming {
                lock.withLock {
                    self.currentTiming?.polishKind = .llmFailed
                    self.currentTiming?.polishFinishedAt = Date()
                }
            }
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }
    }

    // MARK: - WAV helpers

    /// Extract raw PCM bytes from a WAV file by stripping the 44-byte
    /// RIFF header produced by `WAVEncoder`.
    static func extractPCM(fromWAV wav: Data) -> Data {
        guard wav.count > 44 else { return Data() }
        return wav.subdata(in: 44..<wav.count)
    }

    // MARK: - JSON helper

    private static func jsonString(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
