import CoreFoundation
import Foundation

/// Stream audio to the OpenAI Realtime API and return polished text.
///
/// Opens a WebSocket to `wss://api.openai.com/v1/realtime` per dictation
/// session. To avoid paying the handshake cost on every dictation, a
/// fresh connection is pre-opened in the background immediately after a
/// successful session, and adopted by the next `startStreaming` call.
/// A warm backup typically cuts `startStreaming` from ~300 ms to < 5 ms.
///
/// `startStreaming` is non-blocking: it kicks off the connection and
/// `session.update` in a background task and returns immediately.
/// `sendAudio` and `finishStreaming` await that setup task before using
/// the connection.
///
/// Session protocol:
///
///   1. Open WSS; send `session.update` with polish instructions,
///      transcription, and manual commit configuration.
///   2. Forward audio chunks as `input_audio_buffer.append` with
///      base64-encoded 24 kHz PCM (resampled from the 16 kHz capture).
///   3. Commit bounded source-audio ranges and correlate every transcription
///      terminal by its committed item ID.
///   4. On finish, seal exact source coverage and assemble all item transcripts
///      in commit order.
///   5. Send the complete raw transcript as one text item, request one text
///      response, and read the polished result on the same connection.
///   6. Tear down the connection and pre-open a new backup.
public final class OpenAIStreamingProvider: StreamingDictationProviding, @unchecked Sendable {

    // MARK: - Configuration

    /// Realtime model used by the production composition root.
    public static let defaultRealtimeModel = "gpt-realtime-2.1"

    private let apiKeyProvider: @Sendable () -> String
    private let realtimeModel: String
    private let sttModel: String
    private let commitPolicy: RealtimeCommitPolicy
    private let maxUnresolvedItems: Int
    private let serverEventTimeout: TimeInterval = 60

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
        var polishKind: PolishKind = .pending
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
            case realtimeOK = "realtime-ok"
        }
    }

    // MARK: - Multi-commit session

    /// Serialized source coverage and item-correlation state for the active
    /// connection. The background reader and audio sender share this owner.
    private var commitSession: OpenAIRealtimeCommitSession?

    /// Reader task that receives the transcription and polished response.
    private var chunkReaderTask: Task<Void, Never>?

    // MARK: - Backup connection (warm standby)

    /// Pre-opened connection ready to be adopted by the next session.
    private var backupTask: URLSessionWebSocketTask?
    private var backupSession: URLSession?
    private var backupOpenedAt: Date?
    private var backupOpenTask: Task<Void, Never>?

    /// Background task that refreshes the backup before it goes stale.
    private var backupRefreshTask: Task<Void, Never>?

    /// Maximum age for an idle backup connection. OpenAI closes idle
    /// WebSockets after ~60-90s, so keep this well under that threshold.
    private let maxBackupAge: TimeInterval = 45

    // MARK: - Init

    public init(
        apiKey: @autoclosure @escaping @Sendable () -> String,
        realtimeModel: String = OpenAIStreamingProvider.defaultRealtimeModel,
        sttModel: String = "gpt-4o-mini-transcribe",
        commitPolicy: RealtimeCommitPolicy = RealtimeCommitPolicy(),
        maxUnresolvedItems: Int = 2
    ) {
        precondition(maxUnresolvedItems > 0)
        self.apiKeyProvider = apiKey
        self.realtimeModel = realtimeModel
        self.sttModel = sttModel
        self.commitPolicy = commitPolicy
        self.maxUnresolvedItems = maxUnresolvedItems
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

    public func startStreaming(
        context: AppContext, language: String?, micProximity _: MicProximity
    ) async throws {
        try Task.checkCancellation()

        // Warn if a session is already active — callers should cancel
        // or finish the previous session before starting a new one.
        if lock.withLock({ currentTiming != nil }) {
            Log.debug("[OpenAIRealtime] startStreaming called while a session is active")
            assertionFailure("startStreaming called while a session is active")
        }

        let commitSession = OpenAIRealtimeCommitSession(
            policy: commitPolicy,
            maxUnresolvedItems: maxUnresolvedItems)

        // Install a fresh timing record and source-coverage owner.
        let sessionID: Int = lock.withLock {
            let id = self.nextSessionID
            self.nextSessionID += 1
            self.currentTiming = SessionTiming(id: id, startedAt: Date())
            self.commitSession = commitSession
            return id
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

            let update = Self.buildSessionUpdate(
                sttModel: freshSTTModel,
                language: language,
                context: context)
            try await task.send(.string(update))

            // Record setup completion for the diagnostic summary.
            self.lock.withLock {
                if self.currentTiming?.id == sessionID {
                    self.currentTiming?.setupCompletedAt = Date()
                }
            }
        }
        lock.withLock { self.setupTask = setup }

        // Keep one receive owner for acknowledgement, transcription, and
        // response events throughout the session.
        let reader = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.awaitSetup()
            } catch {
                await commitSession.fail(error)
                return
            }
            let task: URLSessionWebSocketTask? = self.lock.withLock { self.webSocketTask }
            guard let task else {
                await commitSession.fail(
                    DictationError.networkError("No active WebSocket"))
                return
            }

            do {
                try await Self.readRealtimeSessionEvents(
                    session: commitSession,
                    receive: { try await Self.receiveText(on: task) },
                    onTranscriptCompleted: { [weak self] transcript in
                        Log.debug(
                            "[RealtimeResponse] transcript:"
                                + " \"\(transcript.prefix(200))\"")
                        self?.lock.withLock {
                            self?.currentTiming?.transcriptCompletedAt = Date()
                        }
                    },
                    onFirstResponseDelta: { [weak self] in
                        self?.lock.withLock {
                            if self?.currentTiming?.firstDeltaAt == nil {
                                self?.currentTiming?.firstDeltaAt = Date()
                            }
                        }
                    })
            } catch {
                await commitSession.fail(error)
            }
        }
        lock.withLock { self.chunkReaderTask = reader }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        guard !pcmData.isEmpty else { return }
        try await awaitSetup()

        let state = lock.withLock { (self.webSocketTask, self.commitSession) }
        guard let task = state.0, let commitSession = state.1 else {
            throw DictationError.networkError("No active WebSocket")
        }

        do {
            try await Self.withRealtimeSessionTimeout(
                seconds: serverEventTimeout,
                waitingFor: "Realtime commit state",
                session: commitSession,
                onTimeout: {
                    task.cancel(with: .abnormalClosure, reason: nil)
                },
                operation: { [self] in
                    try await Self.sendRealtimeAudio(
                        pcmData,
                        session: commitSession,
                        send: { try await task.send(.string($0)) },
                        onAppendSent: { [self] _, submittedBytes in
                            lock.withLock {
                                currentTiming?.audioBytesSent += submittedBytes
                                currentTiming?.audioChunksSent += 1
                            }
                        },
                        onCommitSent: { [self] in
                            lock.withLock {
                                currentTiming?.commitSentAt = Date()
                            }
                        })
                })
        } catch {
            lock.withLock {
                if self.currentTiming?.error == nil {
                    self.currentTiming?.error = error.localizedDescription
                }
            }
            throw error
        }
    }

    public func finishStreaming() async throws -> String {
        func fail(_ error: Error) async -> Error {
            let commitSession = lock.withLock { self.commitSession }
            await commitSession?.fail(error)
            lock.withLock {
                if self.currentTiming?.error == nil {
                    self.currentTiming?.error = error.localizedDescription
                }
                self.currentTiming?.endedAt = Date()
            }
            emitSessionSummary()
            await tearDown()
            let reader = lock.withLock { () -> Task<Void, Never>? in
                let r = self.chunkReaderTask
                self.chunkReaderTask = nil
                return r
            }
            reader?.cancel()
            return error
        }

        do {
            try await awaitSetup()
        } catch {
            throw await fail(error)
        }

        let state = lock.withLock { (self.webSocketTask, self.commitSession) }
        guard let task = state.0, let commitSession = state.1 else {
            throw await fail(
                DictationError.networkError("No active WebSocket"))
        }

        let bytesSent: Int = lock.withLock {
            self.currentTiming?.audioBytesSent ?? 0
        }
        let transcriptTimeout = Self.transcriptTimeout(forAudioBytes: bytesSent)
        let responseText: String
        do {
            responseText = try await Self.withRealtimeSessionTimeout(
                seconds: transcriptTimeout,
                waitingFor: "complete Realtime transcript and polish",
                session: commitSession,
                onTimeout: {
                    task.cancel(with: .abnormalClosure, reason: nil)
                },
                operation: { [self] in
                    try await Self.finishRealtimeSession(
                        session: commitSession,
                        send: { try await task.send(.string($0)) },
                        onAppendSent: { [self] _, submittedBytes in
                            lock.withLock {
                                currentTiming?.audioBytesSent += submittedBytes
                                currentTiming?.audioChunksSent += 1
                            }
                        },
                        onCommitSent: { [self] in
                            lock.withLock {
                                currentTiming?.commitSentAt = Date()
                            }
                        })
                })
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
        await tearDown()
        doneReader?.cancel()
        warmBackup()

        let polished = responseText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if polished.isEmpty {
            lock.withLock {
                self.currentTiming?.polishKind = .skip
                self.currentTiming?.endedAt = Date()
            }
            emitSessionSummary()
            return ""
        }

        lock.withLock {
            self.currentTiming?.polishKind = .realtimeOK
            self.currentTiming?.endedAt = Date()
        }
        emitSessionSummary()
        Log.debug("[Pipeline] realtime-polished: \"\(polished)\"")
        return polished
    }

    public func cancelStreaming() async {
        let cancellation = CancellationError()
        let state: (Task<Void, Error>?, OpenAIRealtimeCommitSession?) = lock.withLock {
            let s = self.setupTask
            self.setupTask = nil
            return (s, self.commitSession)
        }
        state.0?.cancel()
        await state.1?.fail(cancellation)
        lock.withLock {
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
        let state = lock.withLock { (self.setupTask, self.commitSession) }
        state.0?.cancel()
        await state.1?.fail(CancellationError())
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
    ///     chunks=5 first_delta=0.410 transcript=0.352
    ///     polish=realtime-ok total=0.674
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
        if t.polishKind != .pending {
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
            self.commitSession = nil
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

    /// Configure manual transcription and same-connection response polish.
    static func buildSessionUpdate(
        sttModel: String,
        language: String?,
        context: AppContext
    ) -> String {
        var transcription: [String: Any] = [
            "model": sttModel,
        ]
        if let language {
            transcription["language"] = language
        }

        let session: [String: Any] = [
            "type": "realtime",
            "instructions": PolishPipeline.buildCloudSystemPrompt(
                context: context, language: language),
            "reasoning": ["effort": "minimal"],
            "audio": [
                "input": [
                    "format": [
                        "type": "audio/pcm",
                        "rate": 24000,
                    ],
                    "transcription": transcription,
                    "turn_detection": NSNull(),
                ],
            ],
        ]

        let json = jsonString([
            "type": "session.update",
            "session": session,
        ])
        Log.debug("[RealtimeResponse] session.update JSON: \(json.prefix(500))")
        return json
    }

    /// Build the `response.create` message to trigger a text response.
    static func buildResponseCreate(eventID: String? = nil) -> String {
        var event: [String: Any] = [
            "type": "response.create",
            "response": [
                "output_modalities": ["text"],
            ],
        ]
        if let eventID { event["event_id"] = eventID }
        return jsonString(event)
    }

    /// Build a `conversation.item.create` message to add a user text
    /// message containing the raw transcript for polishing.
    static func buildPolishRequest(
        transcript: String,
        eventID: String? = nil
    ) -> String {
        var event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": transcript,
                    ],
                ],
            ],
        ]
        if let eventID { event["event_id"] = eventID }
        return jsonString(event)
    }

    /// Build an `input_audio_buffer.append` message wrapping base64 PCM.
    static func buildAudioAppend(
        pcm24k: Data,
        eventID: String? = nil
    ) -> String {
        var event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm24k.base64EncodedString(),
        ]
        if let eventID { event["event_id"] = eventID }
        return jsonString(event)
    }

    /// Build the `input_audio_buffer.commit` message.
    static func buildCommit(eventID: String? = nil) -> String {
        var event: [String: Any] = ["type": "input_audio_buffer.commit"]
        if let eventID { event["event_id"] = eventID }
        return jsonString(event)
    }

    // MARK: - Event parsing (testable pure function)

    enum ParsedEvent: Equatable {
        case transcription(OpenAIRealtimeTranscriptionEvent)
        case transcriptionDelta(String)
        case responseTextDelta(String)
        case responseTextDone(String)
        case responseDone
        case error(String)
        case serverError(OpenAIRealtimeServerError)
        case protocolError(String)
        case other
    }

    static func parseEvent(_ text: String) -> ParsedEvent {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let obj = object as? [String: Any]
        else {
            return .protocolError("Realtime event is not a JSON object")
        }
        guard let type = obj["type"] as? String, !type.isEmpty else {
            return .protocolError("Realtime event requires nonempty string type")
        }

        switch type {
        case "input_audio_buffer.committed":
            do {
                let serverEventID = try requiredNonemptyString(
                    in: obj,
                    field: "event_id",
                    eventType: type)
                let itemID = try requiredNonemptyString(
                    in: obj,
                    field: "item_id",
                    eventType: type)
                let predecessor = try itemPredecessor(
                    in: obj,
                    field: "previous_item_id",
                    eventType: type)
                return .transcription(
                    .commitAcknowledged(
                        serverEventID: serverEventID,
                        itemID: itemID,
                        predecessor: predecessor))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "conversation.item.input_audio_transcription.completed":
            do {
                return .transcription(
                    .completed(
                        serverEventID: try requiredNonemptyString(
                            in: obj,
                            field: "event_id",
                            eventType: type),
                        itemID: try requiredNonemptyString(
                            in: obj,
                            field: "item_id",
                            eventType: type),
                        contentIndex: try requiredNonnegativeInteger(
                            in: obj,
                            field: "content_index",
                            eventType: type),
                        transcript: try requiredString(
                            in: obj,
                            field: "transcript",
                            eventType: type)))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "conversation.item.input_audio_transcription.delta":
            let delta = obj["delta"] as? String ?? ""
            return .transcriptionDelta(delta)
        case "conversation.item.input_audio_transcription.failed":
            do {
                let error = try requiredObject(
                    in: obj,
                    field: "error",
                    eventType: type)
                let details = OpenAIRealtimeErrorDetails(
                    type: try optionalString(
                        in: error,
                        field: "type",
                        eventType: type),
                    code: try optionalString(
                        in: error,
                        field: "code",
                        eventType: type),
                    message: try optionalString(
                        in: error,
                        field: "message",
                        eventType: type),
                    parameter: try optionalString(
                        in: error,
                        field: "param",
                        eventType: type))
                return .transcription(
                    .failed(
                        serverEventID: try requiredNonemptyString(
                            in: obj,
                            field: "event_id",
                            eventType: type),
                        itemID: try requiredNonemptyString(
                            in: obj,
                            field: "item_id",
                            eventType: type),
                        contentIndex: try requiredNonnegativeInteger(
                            in: obj,
                            field: "content_index",
                            eventType: type),
                        error: details))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "response.text.delta", "response.output_text.delta":
            do {
                return .responseTextDelta(
                    try requiredString(
                        in: obj,
                        field: "delta",
                        eventType: type))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "response.text.done", "response.output_text.done":
            do {
                return .responseTextDone(
                    try requiredString(
                        in: obj,
                        field: "text",
                        eventType: type))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "response.done":
            Log.debug("[RealtimeResponse] raw response.done: \(text.prefix(1000))")
            guard let response = obj["response"] as? [String: Any] else {
                return .error("response.done missing response")
            }
            guard let status = response["status"] as? String else {
                return .error("response.done missing status")
            }
            if status != "completed" {
                let message = errorMessage(in: response)
                    ?? "response ended with status \(status)"
                return .error(message)
            }
            return .responseDone
        case "error":
            do {
                let error = try requiredObject(
                    in: obj,
                    field: "error",
                    eventType: type)
                return .serverError(
                    OpenAIRealtimeServerError(
                        serverEventID: try requiredNonemptyString(
                            in: obj,
                            field: "event_id",
                            eventType: type),
                        type: try requiredNonemptyString(
                            in: error,
                            field: "type",
                            eventType: type),
                        code: try optionalString(
                            in: error,
                            field: "code",
                            eventType: type),
                        message: try requiredNonemptyString(
                            in: error,
                            field: "message",
                            eventType: type),
                        parameter: try optionalString(
                            in: error,
                            field: "param",
                            eventType: type),
                        clientEventID: try optionalString(
                            in: error,
                            field: "event_id",
                            eventType: type)))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        default:
            Log.debug("[RealtimeResponse] event type=\(type)")
            return .other
        }
    }

    private struct EventFieldFailure: Error {
        let message: String
    }

    private static func requiredNonemptyString(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> String {
        guard let value = object[field] as? String, !value.isEmpty else {
            throw EventFieldFailure(
                message: "\(eventType) requires nonempty string \(field)")
        }
        return value
    }

    private static func requiredString(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> String {
        guard let value = object[field] as? String else {
            throw EventFieldFailure(
                message: "\(eventType) requires string \(field)")
        }
        return value
    }

    private static func optionalString(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> String? {
        guard let raw = object[field] else { return nil }
        if raw is NSNull { return nil }
        guard let value = raw as? String else {
            throw EventFieldFailure(
                message: "\(eventType) requires \(field) to be null or a string")
        }
        return value
    }

    private static func requiredObject(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> [String: Any] {
        guard let value = object[field] as? [String: Any] else {
            throw EventFieldFailure(
                message: "\(eventType) requires object \(field)")
        }
        return value
    }

    private static func requiredNonnegativeInteger(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> Int {
        guard let number = object[field] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            throw EventFieldFailure(
                message: "\(eventType) requires nonnegative integer \(field)")
        }
        let int64Value = number.int64Value
        guard int64Value >= 0,
            number.compare(NSNumber(value: int64Value)) == .orderedSame,
            let value = Int(exactly: int64Value)
        else {
            throw EventFieldFailure(
                message: "\(eventType) requires nonnegative integer \(field)")
        }
        return value
    }

    private static func itemPredecessor(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> RealtimeItemPredecessor {
        guard let raw = object[field] else { return .unspecified }
        if raw is NSNull { return .root }
        guard let value = raw as? String, !value.isEmpty else {
            throw EventFieldFailure(
                message: "\(eventType) requires \(field) to be null or a nonempty string")
        }
        return .item(value)
    }

    private static func errorMessage(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }
        if let details = object["status_details"] as? [String: Any] {
            return errorMessage(in: details)
        }
        return nil
    }

    // MARK: - Multi-commit session orchestration

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
                    buildAudioAppend(
                        pcm24k: pcm24k,
                        eventID: eventID()))
                try Task.checkCancellation()
                onAppendSent?(appendCount, pcm24k.count)
                let containsSpeech = AudioLevelAnalyzer.rmsLevel(pcm16: source)
                    > 0.005
                let shouldCommit = try await session.appendSucceeded(
                    byteCount: appendCount,
                    containsSpeech: containsSpeech)
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
        onCommitSent: (@Sendable () -> Void)? = nil
    ) async throws -> String {
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
            if transcript.isEmpty {
                await session.releaseTransportTurn()
                return ""
            }

            try await session.beginPolish()
            try await send(
                buildPolishRequest(
                    transcript: transcript,
                    eventID: eventID()))
            try await send(buildResponseCreate(eventID: eventID()))
            let response = try await session.waitForPolishedResponse()
            await session.releaseTransportTurn()
            return response
        } catch {
            await session.fail(error)
            if ownsTransportTurn {
                await session.releaseTransportTurn()
            }
            throw error
        }
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
                switch parseEvent(try await receive()) {
                case .transcription(let event):
                    try await session.apply(event)
                    if case .completed(_, _, _, let transcript) = event {
                        onTranscriptCompleted?(transcript)
                    }
                case .responseTextDelta(let delta):
                    if try await session.appendResponseDelta(delta) {
                        onFirstResponseDelta?()
                    }
                case .responseTextDone(let text):
                    try await session.completeResponseText(text)
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
                        buildAudioAppend(
                            pcm24k: tail,
                            eventID: eventID()))
                    onAppendSent?(0, tail.count)
                }
                try await send(buildCommit(eventID: eventID()))
                onCommitSent?()
                try await session.waitForAcknowledgement(
                    sequence: commit.sequence)
                try Task.checkCancellation()
                return
            }
        }
    }

    // MARK: - WebSocket receive

    private static func receiveText(
        on task: URLSessionWebSocketTask
    ) async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw DictationError.networkError(
                "WebSocket receive failed: \(error.localizedDescription)")
        }

        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return ""
        }
    }

    // MARK: - JSON helper

    private static func jsonString(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
