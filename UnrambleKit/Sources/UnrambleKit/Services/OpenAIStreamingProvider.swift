import CoreFoundation
import CryptoKit
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

    /// The app supports 300 seconds of cloud capture. The finish-watchdog bound
    /// budgets another ten accounting seconds for queued forwarding and the
    /// cumulative sample-rounding overhead of independently resampled items.
    /// This cushion is not a longer supported recording or an admission fence.
    static let finishWatchdogBoundSourceSeconds: TimeInterval = 310
    static let finishWatchdogBoundWireAudioBytes =
        Int(finishWatchdogBoundSourceSeconds * 48_000)

    /// Only exact digital silence can authorize a continued Realtime item.
    /// Any positive threshold can misclassify low-amplitude speech after an
    /// earlier loud peak; under-counting pauses only delays finalization.
    static let pauseSilenceThreshold: Float = 0

    private static let multiCommitPolishFidelityInstructions = """
        The polishing input is the complete ordered transcript assembled from one or more \
        committed audio items. Preserve every dictated semantic statement and \
        discourse-framing phrase in its original order. Never delete or summarize a \
        complete sentence or clause merely because it sounds conversational, \
        introductory, or redundant. For example, "Just circling back on this" is \
        dictated content and must be preserved. Cleanup may still remove non-semantic \
        filler sounds, explicit self-corrections or restarts, and accidental repetitions \
        under the rules above.
        """

    private let apiKeyProvider: @Sendable () -> String
    private let realtimeModel: String
    private let sttModel: String
    private let commitPolicy: RealtimeCommitPolicy
    private let maxUnresolvedItems: Int
    typealias EvidenceObserver = @Sendable (
        OpenAIRealtimeCommitSession.EvidenceSnapshot
    ) async -> Void
    struct RealtimeFinishResult: Sendable {
        let response: String
        let evidence: OpenAIRealtimeCommitSession.EvidenceSnapshot?
    }
    private let evidenceObserver: EvidenceObserver?
    typealias TransportFactory = @Sendable (
        _ apiKey: String,
        _ model: String
    ) throws -> any OpenAIRealtimeTransport
    typealias SetupAdmission = @Sendable (DictationSessionID) async -> Void
    typealias BackupReadyObserver = @Sendable () -> Void
    typealias BackupOpenObserver = @Sendable (UUID) async -> Void
    typealias BackupOpenCompletionObserver = @Sendable (UUID) -> Void
    typealias BackupRefreshObserver = @Sendable (UUID) async -> Void
    typealias BackupRefreshCompletionObserver = @Sendable (UUID) -> Void
    private let transportFactory: TransportFactory
    private let setupAdmission: SetupAdmission?
    private let backupReadyObserver: BackupReadyObserver?
    private let backupOpenWillPublish: BackupOpenObserver?
    private let backupOpenDidFinish: BackupOpenCompletionObserver?
    private let backupRefreshDelay: TimeInterval
    private let backupRefreshWillDiscard: BackupRefreshObserver?
    private let backupRefreshDidFinish: BackupRefreshCompletionObserver?
    private let serverEventTimeout: TimeInterval = 60

    // MARK: - State (guarded by lock)

    private let lock = NSLock()

    /// Active session's WebSocket transport, if any.
    private var transport: (any OpenAIRealtimeTransport)?

    /// Background task that opens the connection and sends session.update.
    /// `sendAudio` and `finishStreaming` await this future before using
    /// the active task.
    private var setupTask: Task<Void, Error>?
    private var activeSessionID: DictationSessionID?
    private var currentTimingSessionID: DictationSessionID?
    private var chunkReaderSessionID: DictationSessionID?

    /// Invalidates post-session background work that was admitted before a
    /// disconnect completed.
    private var lifecycleEpoch: UInt64 = 0

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
        var failure: FailureKind?

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

        enum FailureKind: String {
            case cancelled
            case emptyAudio = "empty-audio"
            case audioTooLarge = "audio-too-large"
            case authentication
            case rateLimited = "rate-limited"
            case request
            case invalidResponse = "invalid-response"
            case network
            case unknown
        }
    }

    // MARK: - Multi-commit session

    /// Serialized source coverage and item-correlation state for the active
    /// connection. The background reader and audio sender share this owner.
    private var commitSession: OpenAIRealtimeCommitSession?

    /// Reader task that receives the transcription and polished response.
    private var chunkReaderTask: Task<Void, Never>?

    private struct TeardownOperation {
        let token: UUID
        let sessionID: DictationSessionID
        let task: Task<Void, Never>
    }

    /// A closing session retains provider ownership until all setup and reader
    /// work has drained, preventing the next session from adopting its writes.
    private var teardownOperation: TeardownOperation?

    // MARK: - Backup connection (warm standby)

    private struct BackupConnection {
        let generation: UUID
        let credentialFingerprint: Data
        let transport: any OpenAIRealtimeTransport
        let openedAt: Date
    }

    private struct BackupOpenOperation {
        let token: UUID
        let credentialFingerprint: Data
        var task: Task<Void, Never>?
    }

    private struct BackupRefreshOperation {
        let token: UUID
        let generation: UUID
        var task: Task<Void, Never>?
    }

    private final class AsyncLaunchGate: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if lock.withLock({ released }) { return }
            await withCheckedContinuation { continuation in
                let ready = lock.withLock {
                    if released { return true }
                    waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }

        func release() {
            let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
                guard !released else { return [] }
                released = true
                let ready = waiters
                waiters.removeAll()
                return ready
            }
            for waiter in ready { waiter.resume() }
        }
    }

    /// Each asynchronous backup transition is reserved before its task starts.
    /// A task may publish or discard only while its token still owns the slot.
    private var backupConnection: BackupConnection?
    private var backupOpenOperation: BackupOpenOperation?
    private var backupRefreshOperation: BackupRefreshOperation?

    /// Maximum age for an idle backup connection. OpenAI closes idle
    /// WebSockets after ~60-90s, so keep this well under that threshold.
    private let maxBackupAge: TimeInterval = 45

    // MARK: - Init

    public convenience init(
        apiKey: @autoclosure @escaping @Sendable () -> String,
        realtimeModel: String = OpenAIStreamingProvider.defaultRealtimeModel,
        sttModel: String = "gpt-4o-mini-transcribe",
        commitPolicy: RealtimeCommitPolicy = RealtimeCommitPolicy(),
        maxUnresolvedItems: Int = 2
    ) {
        self.init(
            apiKeyProvider: apiKey,
            realtimeModel: realtimeModel,
            sttModel: sttModel,
            commitPolicy: commitPolicy,
            maxUnresolvedItems: maxUnresolvedItems,
            evidenceObserver: nil)
    }

    init(
        apiKeyProvider: @escaping @Sendable () -> String,
        realtimeModel: String,
        sttModel: String,
        commitPolicy: RealtimeCommitPolicy,
        maxUnresolvedItems: Int,
        evidenceObserver: EvidenceObserver?,
        transportFactory: @escaping TransportFactory = {
            try OpenAIRealtimeTransportFactory.buildTransport(apiKey: $0, model: $1)
        },
        setupAdmission: SetupAdmission? = nil,
        backupReadyObserver: BackupReadyObserver? = nil,
        backupOpenWillPublish: BackupOpenObserver? = nil,
        backupOpenDidFinish: BackupOpenCompletionObserver? = nil,
        backupRefreshDelay: TimeInterval = 35,
        backupRefreshWillDiscard: BackupRefreshObserver? = nil,
        backupRefreshDidFinish: BackupRefreshCompletionObserver? = nil
    ) {
        precondition(maxUnresolvedItems > 0)
        precondition(backupRefreshDelay >= 0 && backupRefreshDelay.isFinite)
        self.apiKeyProvider = apiKeyProvider
        self.realtimeModel = realtimeModel
        self.sttModel = sttModel
        self.commitPolicy = commitPolicy
        self.maxUnresolvedItems = maxUnresolvedItems
        self.evidenceObserver = evidenceObserver
        self.transportFactory = transportFactory
        self.setupAdmission = setupAdmission
        self.backupReadyObserver = backupReadyObserver
        self.backupOpenWillPublish = backupOpenWillPublish
        self.backupOpenDidFinish = backupOpenDidFinish
        self.backupRefreshDelay = backupRefreshDelay
        self.backupRefreshWillDiscard = backupRefreshWillDiscard
        self.backupRefreshDidFinish = backupRefreshDidFinish
    }

    deinit {
        let (reader, active, bOpen, backup, bRefresh) = lock.withLock {
            (chunkReaderTask, transport,
             backupOpenOperation?.task,
             backupConnection?.transport,
             backupRefreshOperation?.task)
        }
        reader?.cancel()
        bOpen?.cancel()
        bRefresh?.cancel()
        backup?.close(.normal)
        active?.close(.normal)
    }

    // MARK: - StreamingDictationProviding

    public func startStreaming(
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity _: MicProximity
    ) async throws {
        try Task.checkCancellation()

        let commitSession = OpenAIRealtimeCommitSession(
            policy: commitPolicy,
            maxUnresolvedItems: maxUnresolvedItems)

        // Checking and reserving ownership are one atomic operation so two
        // concurrent starts cannot both observe an idle provider.
        let claimed = lock.withLock {
            guard activeSessionID == nil else { return false }
            let id = self.nextSessionID
            self.nextSessionID += 1
            self.activeSessionID = sessionID
            self.currentTimingSessionID = sessionID
            self.currentTiming = SessionTiming(id: id, startedAt: Date())
            self.commitSession = commitSession
            return true
        }
        guard claimed else {
            throw DictationError.networkError(
                "A Realtime session is already active")
        }

        // Try to adopt a fresh backup connection. If the backup is missing
        // or stale, open a new one. Either way, store the setup future so
        // sendAudio and finishStreaming can await it.
        let freshAPIKey = apiKeyProvider()
        let credentialFingerprint = Self.credentialFingerprint(freshAPIKey)
        let adoption = adoptBackupIfFresh(
            credentialFingerprint: credentialFingerprint)
        let adopted = adoption.adopted
        let staleBackup = adoption.discardedStale

        lock.withLock {
            guard activeSessionID == sessionID else { return }
            self.currentTiming?.setupKind =
                adopted != nil
                ? .adoptedBackup
                : (staleBackup ? .adoptedStaleBackup : .freshConnection)
        }

        let freshModel = realtimeModel
        let freshSTTModel = sttModel
        let setupAdmission = setupAdmission

        let setup = Task { [weak self] in
            guard let self else {
                adopted?.close(.normal)
                return
            }

            let candidate: any OpenAIRealtimeTransport
            if let adopted {
                candidate = adopted
            } else {
                try Task.checkCancellation()
                let transport = try self.transportFactory(freshAPIKey, freshModel)
                transport.resume()
                candidate = transport
            }

            // Until publication transfers the candidate into provider state,
            // every exit path retains responsibility for closing it.
            var didPublish = false
            defer {
                if !didPublish { candidate.close(.normal) }
            }

            await setupAdmission?(sessionID)
            try Task.checkCancellation()
            guard self.lock.withLock({ self.activeSessionID == sessionID }) else {
                throw CancellationError()
            }

            // If cancelled after building but before publishing, clean
            // up the locally held task/session and bail. Without this,
            // cancelStreaming running between these lines could leave a
            // stale transport in provider state for the next session.
            if Task.isCancelled {
                throw CancellationError()
            }

            // Publish the task immediately so tearDown can reach it even
            // if session.update fails.
            let wasPublished = self.lock.withLock {
                guard self.activeSessionID == sessionID,
                    self.teardownOperation == nil
                else { return false }
                self.transport = candidate
                return true
            }
            guard wasPublished else {
                throw CancellationError()
            }
            didPublish = true

            let update = Self.buildSessionUpdate(
                sttModel: freshSTTModel,
                language: language,
                context: context)
            try await candidate.send(update)
            try Task.checkCancellation()

            // Record setup completion for the diagnostic summary.
            self.lock.withLock {
                if self.activeSessionID == sessionID,
                    self.teardownOperation == nil
                {
                    self.currentTiming?.setupCompletedAt = Date()
                }
            }
        }
        let setupInstalled = lock.withLock {
            guard activeSessionID == sessionID, teardownOperation == nil else {
                return false
            }
            self.setupTask = setup
            return true
        }
        guard setupInstalled else {
            setup.cancel()
            _ = try? await setup.value
            throw CancellationError()
        }

        // Keep one receive owner for acknowledgement, transcription, and
        // response events throughout the session.
        let reader = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.awaitSetup(sessionID: sessionID)
            } catch {
                await commitSession.fail(error)
                return
            }
            let transport: (any OpenAIRealtimeTransport)? = self.lock.withLock {
                guard self.activeSessionID == sessionID,
                    self.teardownOperation == nil
                else { return nil }
                return self.transport
            }
            guard let transport else {
                await commitSession.fail(
                    DictationError.networkError("No active WebSocket"))
                return
            }

            do {
                try await OpenAIRealtimeSessionDriver.readRealtimeSessionEvents(
                    session: commitSession,
                    receive: { try await transport.receiveText() },
                    onTranscriptCompleted: { [weak self] transcript in
                        Log.debug(
                            "[RealtimeResponse] transcript completed"
                                + " (\(transcript.utf8.count) bytes)")
                        self?.lock.withLock {
                            guard self?.currentTimingSessionID == sessionID else { return }
                            self?.currentTiming?.transcriptCompletedAt = Date()
                        }
                    },
                    onFirstResponseDelta: { [weak self] in
                        self?.lock.withLock {
                            guard self?.currentTimingSessionID == sessionID else { return }
                            if self?.currentTiming?.firstDeltaAt == nil {
                                self?.currentTiming?.firstDeltaAt = Date()
                            }
                        }
                    })
            } catch {
                await commitSession.fail(error)
            }
        }
        let readerInstalled = lock.withLock {
            guard activeSessionID == sessionID, teardownOperation == nil else {
                return false
            }
            self.chunkReaderTask = reader
            self.chunkReaderSessionID = sessionID
            return true
        }
        if !readerInstalled { reader.cancel() }
    }

    public func sendAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID
    ) async throws {
        guard !pcmData.isEmpty else { return }
        try await awaitSetup(sessionID: sessionID)

        let state: ((any OpenAIRealtimeTransport)?, OpenAIRealtimeCommitSession?) =
            lock.withLock {
                guard activeSessionID == sessionID, teardownOperation == nil else {
                    return (nil, nil)
                }
                return (self.transport, self.commitSession)
            }
        guard let transport = state.0, let commitSession = state.1 else {
            throw DictationError.networkError("No active WebSocket")
        }

        do {
            try await OpenAIRealtimeSessionDriver.withRealtimeSessionTimeout(
                seconds: serverEventTimeout,
                waitingFor: "Realtime commit state",
                session: commitSession,
                onTimeout: {
                    transport.close(.abnormal)
                },
                operation: { [self] in
                    try await OpenAIRealtimeSessionDriver.sendRealtimeAudio(
                        pcmData,
                        session: commitSession,
                        send: { try await transport.send($0) },
                        onAppendSent: { [self] _, submittedBytes in
                            lock.withLock {
                                guard currentTimingSessionID == sessionID else { return }
                                currentTiming?.audioBytesSent += submittedBytes
                                currentTiming?.audioChunksSent += 1
                            }
                        },
                        onCommitSent: { [self] in
                            lock.withLock {
                                guard currentTimingSessionID == sessionID else { return }
                                currentTiming?.commitSentAt = Date()
                            }
                        })
                })
        } catch {
            lock.withLock {
                guard self.currentTimingSessionID == sessionID else { return }
                if self.currentTiming?.failure == nil {
                    self.currentTiming?.failure = Self.failureKind(for: error)
                }
            }
            throw error
        }
    }

    public func finishStreaming(
        sessionID: DictationSessionID
    ) async throws -> String {
        let finishLifecycleEpoch = lock.withLock { lifecycleEpoch }

        func fail(_ error: Error) async -> Error {
            lock.withLock {
                guard self.currentTimingSessionID == sessionID else { return }
                if self.currentTiming?.failure == nil {
                    self.currentTiming?.failure = Self.failureKind(for: error)
                }
                self.currentTiming?.endedAt = Date()
            }
            await tearDown(
                sessionID: sessionID,
                cancelSetup: true,
                failure: error)
            emitSessionSummary(sessionID: sessionID)
            return error
        }

        do {
            try await awaitSetup(sessionID: sessionID)
        } catch {
            throw await fail(error)
        }

        let state: ((any OpenAIRealtimeTransport)?, OpenAIRealtimeCommitSession?) =
            lock.withLock {
                guard activeSessionID == sessionID, teardownOperation == nil else {
                    return (nil, nil)
                }
                return (self.transport, self.commitSession)
            }
        guard let transport = state.0, let commitSession = state.1 else {
            throw await fail(
                DictationError.networkError("No active WebSocket"))
        }

        let bytesSent: Int = lock.withLock {
            guard currentTimingSessionID == sessionID else { return 0 }
            return self.currentTiming?.audioBytesSent ?? 0
        }
        let transcriptTimeout = Self.transcriptTimeout(forAudioBytes: bytesSent)
        let finishResult: RealtimeFinishResult
        do {
            finishResult = try await OpenAIRealtimeSessionDriver.withRealtimeSessionTimeout(
                seconds: transcriptTimeout,
                waitingFor: "complete Realtime transcript and polish",
                session: commitSession,
                onTimeout: {
                    transport.close(.abnormal)
                },
                operation: { [self] in
                    try await OpenAIRealtimeSessionDriver.finishRealtimeSessionResult(
                        session: commitSession,
                        send: { try await transport.send($0) },
                        includeEvidence: evidenceObserver != nil,
                        onAppendSent: { [self] _, submittedBytes in
                            lock.withLock {
                                guard currentTimingSessionID == sessionID else { return }
                                currentTiming?.audioBytesSent += submittedBytes
                                currentTiming?.audioChunksSent += 1
                            }
                        },
                        onCommitSent: { [self] in
                            lock.withLock {
                                guard currentTimingSessionID == sessionID else { return }
                                currentTiming?.commitSentAt = Date()
                            }
                        })
                })
        } catch {
            throw await fail(error)
        }

        // Tear down the current session's connection and spawn a new
        // backup in the background for the next session.
        await tearDown(
            sessionID: sessionID,
            cancelSetup: false,
            failure: nil)
        warmBackup(expectedLifecycleEpoch: finishLifecycleEpoch)

        do {
            try await OpenAIRealtimeSessionDriver.notifyEvidenceObserver(
                evidenceObserver,
                evidence: finishResult.evidence)
        } catch {
            throw await fail(error)
        }

        let polished = finishResult.response.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if polished.isEmpty {
            lock.withLock {
                guard self.currentTimingSessionID == sessionID else { return }
                self.currentTiming?.polishKind = .skip
                self.currentTiming?.endedAt = Date()
            }
            emitSessionSummary(sessionID: sessionID)
            return ""
        }

        lock.withLock {
            guard self.currentTimingSessionID == sessionID else { return }
            self.currentTiming?.polishKind = .realtimeOK
            self.currentTiming?.endedAt = Date()
        }
        emitSessionSummary(sessionID: sessionID)
        Log.debug("[Pipeline] realtime polish completed (\(polished.utf8.count) bytes)")
        return polished
    }

    public var finishStreamingWatchdog: TimeInterval {
        let bytesSent = lock.withLock {
            self.currentTiming?.audioBytesSent ?? 0
        }
        // Let the provider's semantic timeout win under normal conditions,
        // while preserving time for whole-WAV recovery below the pipeline cap.
        return min(295, Self.transcriptTimeout(forAudioBytes: bytesSent) + 5)
    }

    public var maximumFinishStreamingWatchdog: TimeInterval {
        Self.transcriptTimeout(
            forAudioBytes: Self.finishWatchdogBoundWireAudioBytes) + 5
    }

    var hasStandbyOwnership: Bool {
        lock.withLock {
            backupConnection != nil
                || backupOpenOperation != nil
                || backupRefreshOperation != nil
        }
    }

    public func cancelActiveStreaming() async {
        guard let sessionID = lock.withLock({ activeSessionID }) else { return }
        await cancelStreaming(sessionID: sessionID)
    }

    public func cancelStreaming(sessionID: DictationSessionID) async {
        lock.withLock {
            guard self.currentTimingSessionID == sessionID else { return }
            if self.currentTiming != nil {
                self.currentTiming?.endedAt = Date()
                if self.currentTiming?.failure == nil {
                    self.currentTiming?.failure = .cancelled
                }
            }
        }
        await tearDown(
            sessionID: sessionID,
            cancelSetup: true,
            failure: CancellationError())
        emitSessionSummary(sessionID: sessionID)
    }

    /// Disconnect and release all connections. Call at app shutdown.
    public func disconnect() async {
        let sessionID = lock.withLock {
            lifecycleEpoch &+= 1
            return activeSessionID
        }
        if let sessionID {
            await cancelStreaming(sessionID: sessionID)
        }
        await discardBackup()
    }

    // MARK: - Setup future

    /// Await the setup task, returning when the connection is ready and
    /// session.update has been sent. Throws any setup error.
    private func awaitSetup(sessionID: DictationSessionID) async throws {
        let lookup: (ownsSession: Bool, task: Task<Void, Error>?) = lock.withLock {
            guard activeSessionID == sessionID, teardownOperation == nil else {
                return (false, nil)
            }
            return (true, self.setupTask)
        }
        guard lookup.ownsSession else { throw CancellationError() }
        guard let task = lookup.task else {
            throw DictationError.networkError("No active streaming session")
        }
        try await task.value
        guard lock.withLock({
            activeSessionID == sessionID && teardownOperation == nil
        }) else {
            throw CancellationError()
        }
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
    private func emitSessionSummary(sessionID: DictationSessionID) {
        let timing: SessionTiming? = lock.withLock {
            guard self.currentTimingSessionID == sessionID else { return nil }
            let t = self.currentTiming
            self.currentTiming = nil
            self.currentTimingSessionID = nil
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
        if let failure = t.failure {
            parts.append("failure=\(failure.rawValue)")
        }

        return parts.joined(separator: " ")
    }

    static func failureKind(for error: Error) -> SessionTiming.FailureKind {
        if error is CancellationError {
            return .cancelled
        }
        guard let dictationError = error as? DictationError else {
            return error is URLError ? .network : .unknown
        }
        switch dictationError {
        case .emptyAudio:
            return .emptyAudio
        case .audioTooLarge:
            return .audioTooLarge
        case .authenticationFailed:
            return .authentication
        case .rateLimited:
            return .rateLimited
        case .requestFailed:
            return .request
        case .invalidResponse:
            return .invalidResponse
        case .networkError:
            return .network
        }
    }

    // MARK: - Backup connection

    private static func credentialFingerprint(_ apiKey: String) -> Data {
        Data(SHA256.hash(data: Data(apiKey.utf8)))
    }

    /// Spawn a background task that opens a new connection for the next
    /// session. No-op if one is already in flight or ready.
    private func warmBackup(
        replacingRefresh refreshToken: UUID? = nil,
        expectedLifecycleEpoch: UInt64? = nil
    ) {
        if let expectedLifecycleEpoch,
            lock.withLock({ lifecycleEpoch != expectedLifecycleEpoch })
        {
            return
        }
        let bApiKey = apiKeyProvider()
        let credentialFingerprint = Self.credentialFingerprint(bApiKey)
        let bModel = realtimeModel
        let startedAt = Date()
        let token = UUID()

        let reserved = lock.withLock {
            if let expectedLifecycleEpoch,
                lifecycleEpoch != expectedLifecycleEpoch
            {
                return false
            }
            guard backupConnection == nil, backupOpenOperation == nil else {
                return false
            }
            if let refreshToken {
                guard backupRefreshOperation?.token == refreshToken else {
                    return false
                }
                backupRefreshOperation = nil
            } else {
                guard backupRefreshOperation == nil else { return false }
            }
            backupOpenOperation = BackupOpenOperation(
                token: token,
                credentialFingerprint: credentialFingerprint,
                task: nil)
            return true
        }
        guard reserved else { return }

        let launchGate = AsyncLaunchGate()
        let openTask = Task { [weak self] in
            await launchGate.wait()
            do {
                guard let self else { return }
                defer { self.backupOpenDidFinish?(token) }
                try Task.checkCancellation()
                let transport = try self.transportFactory(bApiKey, bModel)
                transport.resume()
                guard !Task.isCancelled else {
                    transport.close(.normal)
                    return
                }
                await self.backupOpenWillPublish?(token)

                let published = self.lock.withLock {
                    guard self.backupOpenOperation?.token == token,
                        self.backupConnection == nil
                    else { return false }
                    self.backupConnection = BackupConnection(
                        generation: token,
                        credentialFingerprint: credentialFingerprint,
                        transport: transport,
                        openedAt: Date())
                    self.backupOpenOperation = nil
                    return true
                }
                guard published else {
                    transport.close(.normal)
                    return
                }

                self.backupReadyObserver?()
                Log.debug(
                    String(
                        format: "[RealtimeBackup] ready after %.3fs",
                        Date().timeIntervalSince(startedAt)))
                self.scheduleBackupRefresh(generation: token)
            } catch {
                let owned = self?.lock.withLock {
                    guard self?.backupOpenOperation?.token == token else {
                        return false
                    }
                    self?.backupOpenOperation = nil
                    return true
                } ?? false
                if owned, !(error is CancellationError) {
                    Log.debug(
                        "[RealtimeBackup] open failed: \(error.localizedDescription)")
                }
            }
        }

        let shouldCancel = lock.withLock {
            if backupConnection?.generation == token {
                return false
            }
            guard backupOpenOperation?.token == token else { return true }
            backupOpenOperation?.task = openTask
            return false
        }
        if shouldCancel { openTask.cancel() }
        launchGate.release()
    }

    /// Schedule a background task that replaces the backup connection
    /// before it goes stale. Sleeps until 10s before `maxBackupAge`,
    /// then discards the old connection and opens a fresh one.
    private func scheduleBackupRefresh(generation: UUID) {
        let refreshDelay = backupRefreshDelay
        let refreshToken = UUID()
        let reservation: (reserved: Bool, previous: Task<Void, Never>?) =
            lock.withLock {
                guard backupConnection?.generation == generation else {
                    return (false, nil)
                }
                let previous = backupRefreshOperation?.task
                backupRefreshOperation = BackupRefreshOperation(
                    token: refreshToken,
                    generation: generation,
                    task: nil)
                return (true, previous)
            }
        guard reservation.reserved else { return }
        reservation.previous?.cancel()

        let launchGate = AsyncLaunchGate()
        let didFinish = backupRefreshDidFinish
        let task = Task { [weak self] in
            defer { didFinish?(refreshToken) }
            await launchGate.wait()
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(refreshDelay * 1_000_000_000))
                try Task.checkCancellation()
                guard let self else { return }

                let ownsGeneration = self.lock.withLock {
                    self.backupRefreshOperation?.token == refreshToken
                        && self.backupRefreshOperation?.generation == generation
                        && self.backupConnection?.generation == generation
                }
                guard ownsGeneration else { return }
                await self.backupRefreshWillDiscard?(refreshToken)

                let connection: BackupConnection? = self.lock.withLock {
                    guard self.backupRefreshOperation?.token == refreshToken,
                        self.backupRefreshOperation?.generation == generation,
                        self.backupConnection?.generation == generation
                    else { return nil }
                    let connection = self.backupConnection
                    self.backupConnection = nil
                    return connection
                }
                guard let connection else { return }
                connection.transport.close(.normal)
                Log.debug("[RealtimeBackup] refreshing before staleness")
                self.warmBackup(replacingRefresh: refreshToken)
            } catch is CancellationError {
                return
            } catch {
                Log.debug(
                    "[RealtimeBackup] refresh failed: \(error.localizedDescription)")
            }
        }

        let shouldCancel = lock.withLock {
            guard backupRefreshOperation?.token == refreshToken,
                backupRefreshOperation?.generation == generation
            else { return true }
            backupRefreshOperation?.task = task
            return false
        }
        if shouldCancel { task.cancel() }
        launchGate.release()
    }

    /// Outcome of an attempt to adopt the warm backup connection as the
    /// active one for a new session.
    private struct BackupAdoption {
        let adopted: (any OpenAIRealtimeTransport)?
        let discardedStale: Bool
    }

    /// Attempt to adopt a fresh backup created with the current credential.
    private func adoptBackupIfFresh(
        credentialFingerprint: Data
    ) -> BackupAdoption {
        enum Outcome {
            case adopted(
                BackupConnection,
                refreshTask: Task<Void, Never>?)
            case discarded(
                BackupConnection,
                stale: Bool,
                refreshTask: Task<Void, Never>?)
            case none(
                cancelOpenTask: Task<Void, Never>?,
                cancelRefreshTask: Task<Void, Never>?)
        }

        let outcome: Outcome = lock.withLock {
            if let connection = backupConnection {
                let refreshTask = backupRefreshOperation?.task
                backupConnection = nil
                backupRefreshOperation = nil

                let age = Date().timeIntervalSince(connection.openedAt)
                if age > maxBackupAge {
                    return .discarded(
                        connection,
                        stale: true,
                        refreshTask: refreshTask)
                }
                guard connection.credentialFingerprint == credentialFingerprint else {
                    return .discarded(
                        connection,
                        stale: false,
                        refreshTask: refreshTask)
                }
                return .adopted(connection, refreshTask: refreshTask)
            }

            if let operation = backupOpenOperation,
                operation.credentialFingerprint != credentialFingerprint
            {
                backupOpenOperation = nil
                return .none(
                    cancelOpenTask: operation.task,
                    cancelRefreshTask: nil)
            }
            if let operation = backupRefreshOperation {
                backupRefreshOperation = nil
                return .none(
                    cancelOpenTask: nil,
                    cancelRefreshTask: operation.task)
            }
            return .none(
                cancelOpenTask: nil,
                cancelRefreshTask: nil)
        }

        switch outcome {
        case .adopted(let connection, let refreshTask):
            refreshTask?.cancel()
            Log.debug(
                String(
                    format: "[RealtimeBackup] adopt age=%.3fs",
                    Date().timeIntervalSince(connection.openedAt)))
            return BackupAdoption(
                adopted: connection.transport,
                discardedStale: false)
        case .discarded(let connection, let stale, let refreshTask):
            refreshTask?.cancel()
            connection.transport.close(.normal)
            Log.debug(
                stale
                    ? "[RealtimeBackup] stale, discarding"
                    : "[RealtimeBackup] credential changed, discarding")
            return BackupAdoption(adopted: nil, discardedStale: stale)
        case .none(let openTask, let refreshTask):
            openTask?.cancel()
            refreshTask?.cancel()
            return BackupAdoption(adopted: nil, discardedStale: false)
        }
    }

    /// Tear down and forget any pre-opened backup connection.
    private func discardBackup() async {
        let detached: (
            connection: BackupConnection?,
            open: Task<Void, Never>?,
            refresh: Task<Void, Never>?
        ) = lock.withLock {
            let detached = (
                backupConnection,
                backupOpenOperation?.task,
                backupRefreshOperation?.task)
            backupConnection = nil
            backupOpenOperation = nil
            backupRefreshOperation = nil
            return detached
        }
        detached.open?.cancel()
        detached.refresh?.cancel()
        detached.connection?.transport.close(.normal)
        await detached.open?.value
        await detached.refresh?.value
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

    /// Build a fresh WebSocket transport for the OpenAI Realtime API.
    ///
    private struct DetachedSession: @unchecked Sendable {
        let setup: Task<Void, Error>?
        let commit: OpenAIRealtimeCommitSession?
        let transport: (any OpenAIRealtimeTransport)?
        let reader: Task<Void, Never>?
    }

    /// Close and drain only the matching session. Ownership is released after
    /// both setup and receive tasks can no longer publish into provider state.
    private func tearDown(
        sessionID: DictationSessionID,
        cancelSetup: Bool,
        failure: Error?
    ) async {
        let operation: TeardownOperation? = lock.withLock {
            if let existing = teardownOperation {
                return existing.sessionID == sessionID ? existing : nil
            }
            guard activeSessionID == sessionID else { return nil }

            let detached = DetachedSession(
                setup: setupTask,
                commit: commitSession,
                transport: self.transport,
                reader: chunkReaderSessionID == sessionID ? chunkReaderTask : nil)
            self.transport = nil
            setupTask = nil
            commitSession = nil
            if chunkReaderSessionID == sessionID {
                chunkReaderTask = nil
                chunkReaderSessionID = nil
            }

            let token = UUID()
            let task = Task {
                if cancelSetup { detached.setup?.cancel() }
                detached.transport?.close(.goingAway)
                if let failure { await detached.commit?.fail(failure) }
                if cancelSetup { _ = await detached.setup?.result }
                detached.reader?.cancel()
                await detached.reader?.value
            }
            let operation = TeardownOperation(
                token: token,
                sessionID: sessionID,
                task: task)
            teardownOperation = operation
            return operation
        }
        guard let operation else { return }
        await operation.task.value

        lock.withLock {
            guard teardownOperation?.token == operation.token else { return }
            teardownOperation = nil
            guard activeSessionID == sessionID else { return }
            activeSessionID = nil
        }
    }

    // MARK: - Message builders (testable pure functions)

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

        let polishInstructions =
            PolishPipeline.buildCloudSystemPrompt(
                context: context, language: language)
            + "\n\n" + multiCommitPolishFidelityInstructions
        let session: [String: Any] = [
            "type": "realtime",
            "instructions": polishInstructions,
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

        let json = OpenAIRealtimeWireCodec.jsonString([
            "type": "session.update",
            "session": session,
        ])
        Log.debug("[RealtimeResponse] session configuration encoded")
        return json
    }

}
