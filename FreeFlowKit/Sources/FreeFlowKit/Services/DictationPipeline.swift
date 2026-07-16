import Foundation

/// The two supported dictation architectures.
///
/// Both paths stream captured PCM. Cloud additionally owns one exact-WAV
/// fallback for failures that occur before final publication.
public enum DictationBackend: Sendable {
    case local(streaming: any LocalAudioReplayProviding)
    case cloud(
        realtime: any StreamingDictationProviding,
        fallback: any BatchDictationProviding)

    fileprivate var streamingProvider: any StreamingDictationProviding {
        switch self {
        case .local(let streaming):
            streaming
        case .cloud(let realtime, _):
            realtime
        }
    }

    fileprivate var cloudFallback: (any BatchDictationProviding)? {
        guard case .cloud(_, let fallback) = self else { return nil }
        return fallback
    }

    fileprivate var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

public enum DictationPipelineCaptureMaintenanceError: Error, Equatable, Sendable {
    case pipelineUnavailable
}

/// Orchestrate the full dictation flow from hotkey press to text injection.
///
/// `DictationPipeline` implements `PipelineProviding` by coordinating an
/// `AudioProviding`, `AppContextProviding`, one `DictationBackend`, and a
/// `TextInjecting` service. It drives the `RecordingCoordinator` state
/// machine through each phase:
///
///   1. `activate()` — transition to `.recording`, start audio capture,
///      begin reading app context in parallel. If a streaming provider
///      is configured, open the streaming session and start forwarding
///      PCM chunks in the background.
///   2. `complete()` — transition to `.processing`, stop audio capture,
///      await context, and produce a final result. Streaming mode drains all
///      queued PCM before finalization. In cloud mode, any uncertain streaming
///      candidate is discarded and recovered from the exact complete WAV
///      through batch. Only the accepted final candidate is injected.
///   3. `cancel()` — abort any in-progress pipeline run and reset to `.idle`.
///
/// The pipeline holds captured context from the `activate()` call so it is
/// available immediately when `complete()` runs.
///
/// After successful dictation, the final text is stored in a `TranscriptBuffer`
/// before injection. If injection fails (no focused text field), the pipeline
/// transitions to `.injectionFailed` so the HUD can show no-target recovery.
/// The transcript remains in the buffer for re-paste via the special shortcut.
public actor DictationPipeline: PipelineProviding {

    /// Lock-free-from-the-provider release ledger. The audio callback publishes
    /// `.live` at the exact provider boundary; key release atomically closes it.
    private final class CaptureBoundaryLedger: @unchecked Sendable {
        private enum State: Equatable {
            case starting
            case live
            case releasedBeforeLive
            case liveAfterReleasePendingStop
            case releasedAfterLive
            case deadlineBeforeLive
        }

        private let lock = NSLock()
        private var state: State = .starting

        func markCaptureLive() {
            lock.withLock {
                switch state {
                case .starting:
                    state = .live
                case .releasedBeforeLive:
                    state = .liveAfterReleasePendingStop
                case .live, .liveAfterReleasePendingStop,
                    .releasedAfterLive, .deadlineBeforeLive:
                    break
                }
            }
        }

        /// Close capture ownership. True means capture was already live and can
        /// be stopped without contending with an in-progress engine start.
        func release() -> Bool {
            lock.withLock {
                switch state {
                case .starting:
                    state = .releasedBeforeLive
                    return false
                case .live:
                    state = .releasedAfterLive
                    return true
                case .liveAfterReleasePendingStop:
                    state = .releasedAfterLive
                    return true
                case .releasedBeforeLive, .releasedAfterLive,
                    .deadlineBeforeLive:
                    return false
                }
            }
        }

        /// Atomically classify a start-method deadline against capture
        /// readiness. Whichever boundary wins owns the provider: a ready
        /// capture continues, while a deadline that wins first can reset a
        /// start that never published audio.
        func claimDeadlineBeforeCapture() -> Bool {
            lock.withLock {
                guard state == .starting else { return false }
                state = .deadlineBeforeLive
                return true
            }
        }

        var captureWasPublished: Bool {
            lock.withLock {
                switch state {
                case .live, .liveAfterReleasePendingStop, .releasedAfterLive:
                    return true
                case .starting, .releasedBeforeLive, .deadlineBeforeLive:
                    return false
                }
            }
        }
    }

    private let audioProvider: AudioProviding
    private let contextProvider: AppContextProviding
    private let backend: DictationBackend
    private let textInjector: TextInjecting
    private let coordinator: RecordingCoordinator
    private let transcriptBuffer: TranscriptBuffer?
    private let micDiagnosticStore: MicDiagnosticStore?

    /// Called when a dictation request fails with a 401 authentication
    /// error. The app should clear stored credentials and enter the
    /// session recovery flow. The app deduplicates an active recovery flow.
    private let onSessionExpired: (@Sendable () -> Void)?

    /// Fixed RMS silence threshold, used as a fallback when ambient
    /// calibration has not completed (recording shorter than 0.5s).
    /// When ambient RMS is available and the mic is near-field, the
    /// pipeline computes an adaptive threshold instead:
    /// `max(ambientRMS * 1.2, 0.0005)`. For far-field (built-in) mics,
    /// the adaptive threshold is skipped because speech and ambient RMS
    /// are virtually indistinguishable (ratio as low as 1.0–1.2x); the
    /// server's `input_audio_noise_reduction: far_field` handles signal
    /// quality instead.
    private let silenceThreshold: Float

    /// Fixed threshold for far-field (built-in) mics. Much lower than
    /// the default `silenceThreshold` because built-in mic speech peaks
    /// at only 0.002–0.005 RMS. Set just above the absolute noise floor
    /// to reject truly silent presses without blocking quiet speech.
    /// The server's far-field noise reduction handles signal quality.
    private let farFieldSilenceThreshold: Float = 0.001

    /// Multiplier applied to the measured ambient RMS to produce an
    /// adaptive silence threshold. Speech must exceed ambient × this
    /// factor to be considered non-silent. 1.2 is calibrated from
    /// real-world testing: built-in mic speech/ambient ratio can be
    /// as low as 1.2x in quiet rooms (previous multipliers of 2.0
    /// and 1.5 both rejected real speech on the built-in mic). The
    /// silence gate only needs to reject truly silent presses; the
    /// server's far-field noise reduction handles signal quality.
    /// AirPods ambient (~0.002) → threshold 0.0024, still well
    /// below AirPods speech RMS (~0.08).
    private let ambientMultiplier: Float = 1.2

    /// Absolute floor for the adaptive threshold. Even with zero
    /// measured ambient noise, reject audio below this level.
    private let minimumAdaptiveThreshold = AudioLevelAnalyzer.minimumAcceptedSpeechRMS

    /// Ceiling for the adaptive threshold. AirPods noise cancellation
    /// can produce variable ambient RMS (0.002–0.015) depending on
    /// environment. Without a cap, high ambient pushes the threshold
    /// above whisper peak RMS (~0.009) and silently rejects speech.
    /// 0.01 lets whispers through while still rejecting noise-only
    /// presses (which peak well below 0.005 on near-field mics).
    private let maximumAdaptiveThreshold: Float = 0.01

    /// Context is read-only input. Observe its deadline without making a hung
    /// accessibility read part of capture/provider replacement ownership.
    private struct ContextReadOperation: Sendable {
        let id: UUID
        let sessionID: DictationSessionID
        let operation: DetachedOperation<AppContext>
    }

    private var pendingContext: ContextReadOperation?

    /// The in-flight pipeline task, used for cancellation.
    private var pipelineTask: Task<Void, Never>?

    /// An injection that has crossed the final publication boundary. Target
    /// applications cannot roll back arbitrary text edits, so cancellation
    /// drains this operation instead of abandoning it while a replacement
    /// session starts.
    private struct InjectionOperation {
        let id: UUID
        /// General buffered paste has no dictation session but still crosses
        /// the same irreversible target-publication boundary.
        let sessionID: DictationSessionID?
        let task: Task<Void, Error>
    }

    private var injectionOperation: InjectionOperation?

    /// Owns explicit transcription Retry from provider setup through final
    /// publication. Cancellation drains it before replacement admission so an
    /// old local model session or cloud request cannot overlap the next capture.
    private struct RetryOperation {
        let id: UUID
        let sessionID: DictationSessionID
        let task: Task<String, Error>
    }

    private var retryOperation: RetryOperation?

    /// Owns PCM forwarding until natural drain or explicit teardown.
    private var audioForwardingOperation: AudioForwardingOperation?

    /// Task that performs audio setup after activate() returns.
    /// complete() awaits this to ensure audio is ready before stopping.
    private var audioSetupTask: Task<Void, Never>?

    private struct AudioStartOperation {
        let id: UUID
        let sessionID: DictationSessionID
        let captureLedger: CaptureBoundaryLedger
        let task: Task<Result<Void, Error>, Never>
    }

    /// The single owner that closes a live capture and preserves its exact WAV.
    /// Completion, cancellation, and retirement join this task instead of
    /// independently consulting an already-released capture ledger.
    private struct CaptureStopOperation {
        let id: UUID
        let sessionID: DictationSessionID
        let task: Task<Result<AudioBuffer, Error>, Never>
    }

    private struct StreamingSetupOperation {
        let id: UUID
        let sessionID: DictationSessionID
        let task: Task<Bool, Never>
    }

    /// Timeout observation must not discard the cancellation-insensitive owner.
    private var audioStartOperation: AudioStartOperation?
    private var captureStopOperation: CaptureStopOperation?
    private var streamingSetupOperation: StreamingSetupOperation?

    /// Completion can stop capture after the provider has published its PCM
    /// stream but before the detached setup owner resumes to read it. Retain
    /// that exact stream by session so release cannot erase captured speech.
    private var completionRetainedPCMStream:
        (sessionID: DictationSessionID, stream: AsyncStream<Data>)?

    private struct CancellationDrain {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct ActiveSession: Sendable {
        let id: DictationSessionID
        let language: String?
        let startedAt: Date
        let releaseBoundary: AudioCaptureReleaseBoundary?
    }

    private enum DictationSource: String {
        case local
        case realtime
        case httpFallback = "http_fallback"
    }

    private struct ResolvedDictation {
        let text: String
        let source: DictationSource
    }

    /// Shared barrier for overlapping cancel and retirement requests.
    private var cancellationDrain: CancellationDrain?

    /// One identity owns capture, backend work, recovery, and publication.
    private var activeSession: ActiveSession?

    /// Reserves the single activation slot before the first actor suspension.
    /// It becomes `activeSession` only when coordinator admission is claimed.
    private var activationReservation: ActiveSession?

    /// Owns the shared transcript lease and target-publication path. A held
    /// activation may reserve concurrently, but waits for this owner to finish.
    private var bufferedPasteReservationID: UUID?
    private var bufferedPasteWaiters: [CheckedContinuation<Void, Never>] = []

    /// Invalidate completion operations that suspended before cancellation.
    private var cancellationGeneration: UInt64 = 0

    /// Completion owners may still mutate session state after cancellation.
    private var completionOwnerCount = 0
    private var completionOwnerWaiters: [CheckedContinuation<Void, Never>] = []

    /// Bridges the coordinator's claimed terminal state to its visible idle
    /// commit. Replacement activation and manual paste wait here instead of
    /// observing the deliberately frozen pre-idle coordinator state.
    private var terminalIdleTransitionID: UUID?
    private var terminalIdleTransitionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether the current recording session is using streaming mode.
    private var isStreamingSession: Bool = false

    /// Set by performAudioSetup when startRecording fails. Checked by
    /// complete() to skip dictation and reset immediately.
    private var audioSetupFailed: Bool = false

    private var captureBoundary:
        (sessionID: DictationSessionID, ledger: CaptureBoundaryLedger)?

    /// A release that arrived before capture became live owns the hard audio
    /// boundary. A cold late start cannot become a transcript candidate; only
    /// a running preview tap that proves complete pre-release coverage may
    /// recover the session from its retained pre-roll.
    private var captureBoundaryMissedSessionID: DictationSessionID?
    private var previewPreRollRecoverySessionID: DictationSessionID?

    private struct RecoveryRecord: Sendable {
        let sessionID: DictationSessionID
        let audio: Data
        let context: AppContext
        let language: String?
        let micProximity: MicProximity
        let silenceThreshold: Float
    }

    /// Exact capture and activation-time inputs retained for explicit Retry.
    private var recovery: RecoveryRecord?

    /// When the current recording started (set in `activate`, cleared
    /// at the end of `complete`). Used to compute a duration-scaled
    /// hard deadline for the pipeline task so long dictations do not
    /// hit the force-reset ceiling mid-way through transcription.
    private var recordingStartedAt: Date?

    /// ISO-639-1 language hint for transcription (e.g. "en", "fr", "ja").
    /// Set from the menu bar language picker or auto-detected from macOS
    /// locale. When nil, the server defaults to auto-detection.
    private(set) var language: String?

    /// Cloud recordings finalize at this wall-clock limit so the complete WAV
    /// remains inside the supported batch-recovery envelope.
    private let cloudRecordingLimit: Duration
    private let cloudRecordingLimitSleep: @Sendable (Duration) async -> Void
    private let cloudRecordingLimitDidClaim: @Sendable () async -> Void
    private let completionDidEstablishReleaseBoundary: @Sendable () async -> Void
    private let completionWillHandoff: @Sendable () async -> Void
    private let captureStopDidClaim: @Sendable () async -> Void
    private let cancellationDrainDidStart: @Sendable () async -> Void
    private let cancellationDidSelectCaptureStop: @Sendable (Bool) -> Void
    private let terminalIdleDidClaim: @Sendable (DictationSessionID) async -> Void
    private let terminalIdleDidReleaseOwnership: @Sendable (DictationSessionID) async -> Void
    private let terminalIdleDidPublish: @Sendable (DictationSessionID) async -> Void
    private let pipelineDidCaptureRecovery: @Sendable (DictationSessionID) -> Void
    private let activationDidBeginWaitingForCompletion: @Sendable () -> Void
    private let activationDidReserve: @Sendable () async -> Void
    private let activationDidPublishSessionOwner: @Sendable () async -> Void
    private let contextObservationTimeout: TimeInterval
    private let audioStartObservationTimeout: TimeInterval
    private let audioSetupCompletionWatchdog: Duration
    private let audioSetupCompletionSleep: @Sendable (Duration) async -> Void
    private var cloudRecordingLimitID: UUID?
    private var cloudRecordingLimitClaimedID: UUID?
    private var cloudRecordingLimitSessionID: DictationSessionID?
    private var cloudRecordingLimitTask: Task<Void, Never>?

    /// A retired pipeline cannot accept work after composition replacement.
    private var isRetired = false

    /// A replacement seal blocks only new capture and idle-paste admissions.
    /// Work already owned by this generation remains live until it reaches a
    /// user-visible terminal state and releases its session.
    private(set) var isSealedForReplacement = false
    private var replacementSealWaiters: [CheckedContinuation<Void, Never>] = []

    /// A capture-maintenance owner seals new microphone and idle-paste work,
    /// waits for previously admitted work to drain naturally, and retains the
    /// seal until its hardware transaction returns.
    private(set) var isSealedForCaptureMaintenance = false
    private var captureMaintenanceID: UUID?
    private var captureMaintenanceQuiescenceWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    private var captureMaintenanceCompletionWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    private var cancellableCaptureMaintenanceQuiescenceWaiters: [
        UUID: CheckedContinuation<Void, Error>
    ] = [:]
    private var cancellableCaptureMaintenanceCompletionWaiters: [
        UUID: CheckedContinuation<Void, Error>
    ] = [:]

    /// Public operations that entered before retirement. Retirement waits for
    /// them, then performs a final task-slot sweep before model shutdown.
    private var activeOperationCount = 0
    private var activeOperationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Update the language hint from outside the actor.
    public func setLanguage(_ code: String?) {
        language = code
    }

    public init(
        audioProvider: AudioProviding,
        contextProvider: AppContextProviding,
        backend: DictationBackend,
        textInjector: TextInjecting,
        coordinator: RecordingCoordinator,
        transcriptBuffer: TranscriptBuffer? = nil,
        silenceThreshold: Float = 0.005,
        language: String? = nil,
        onSessionExpired: (@Sendable () -> Void)? = nil,
        micDiagnosticStore: MicDiagnosticStore? = nil
    ) {
        self.init(
            audioProvider: audioProvider,
            contextProvider: contextProvider,
            backend: backend,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            silenceThreshold: silenceThreshold,
            language: language,
            onSessionExpired: onSessionExpired,
            micDiagnosticStore: micDiagnosticStore,
            cloudRecordingLimit: .seconds(300),
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            cloudRecordingLimitDidClaim: {})
    }

    init(
        audioProvider: AudioProviding,
        contextProvider: AppContextProviding,
        backend: DictationBackend,
        textInjector: TextInjecting,
        coordinator: RecordingCoordinator,
        transcriptBuffer: TranscriptBuffer? = nil,
        silenceThreshold: Float = 0.005,
        language: String? = nil,
        onSessionExpired: (@Sendable () -> Void)? = nil,
        micDiagnosticStore: MicDiagnosticStore? = nil,
        cloudRecordingLimit: Duration = .seconds(300),
        cloudRecordingLimitSleep: @escaping @Sendable (Duration) async -> Void,
        cloudRecordingLimitDidClaim: @escaping @Sendable () async -> Void = {},
        completionDidEstablishReleaseBoundary: @escaping @Sendable () async -> Void = {},
        completionWillHandoff: @escaping @Sendable () async -> Void = {},
        captureStopDidClaim: @escaping @Sendable () async -> Void = {},
        cancellationDrainDidStart: @escaping @Sendable () async -> Void = {},
        cancellationDidSelectCaptureStop: @escaping @Sendable (Bool) -> Void = { _ in },
        terminalIdleDidClaim: @escaping @Sendable (DictationSessionID) async -> Void = { _ in },
        terminalIdleDidReleaseOwnership: @escaping @Sendable (DictationSessionID) async -> Void = { _ in },
        terminalIdleDidPublish: @escaping @Sendable (DictationSessionID) async -> Void = { _ in },
        pipelineDidCaptureRecovery: @escaping @Sendable (DictationSessionID) -> Void = { _ in },
        activationDidBeginWaitingForCompletion: @escaping @Sendable () -> Void = {},
        activationDidReserve: @escaping @Sendable () async -> Void = {},
        activationDidPublishSessionOwner: @escaping @Sendable () async -> Void = {},
        contextObservationTimeout: TimeInterval = 0.5,
        audioStartObservationTimeout: TimeInterval = 3,
        audioSetupCompletionWatchdog: Duration = .seconds(6),
        audioSetupCompletionSleep: @escaping @Sendable (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        }
    ) {
        self.audioProvider = audioProvider
        self.contextProvider = contextProvider
        self.backend = backend
        self.textInjector = textInjector
        self.coordinator = coordinator
        self.transcriptBuffer = transcriptBuffer
        self.silenceThreshold = silenceThreshold
        self.language = language
        self.onSessionExpired = onSessionExpired
        self.micDiagnosticStore = micDiagnosticStore
        self.cloudRecordingLimit = cloudRecordingLimit
        self.cloudRecordingLimitSleep = cloudRecordingLimitSleep
        self.cloudRecordingLimitDidClaim = cloudRecordingLimitDidClaim
        self.completionDidEstablishReleaseBoundary =
            completionDidEstablishReleaseBoundary
        self.completionWillHandoff = completionWillHandoff
        self.captureStopDidClaim = captureStopDidClaim
        self.cancellationDrainDidStart = cancellationDrainDidStart
        self.cancellationDidSelectCaptureStop = cancellationDidSelectCaptureStop
        self.terminalIdleDidClaim = terminalIdleDidClaim
        self.terminalIdleDidReleaseOwnership = terminalIdleDidReleaseOwnership
        self.terminalIdleDidPublish = terminalIdleDidPublish
        self.pipelineDidCaptureRecovery = pipelineDidCaptureRecovery
        self.activationDidBeginWaitingForCompletion =
            activationDidBeginWaitingForCompletion
        self.activationDidReserve = activationDidReserve
        self.activationDidPublishSessionOwner = activationDidPublishSessionOwner
        self.contextObservationTimeout = contextObservationTimeout
        self.audioStartObservationTimeout = audioStartObservationTimeout
        self.audioSetupCompletionWatchdog = audioSetupCompletionWatchdog
        self.audioSetupCompletionSleep = audioSetupCompletionSleep
    }

    /// Compute the effective silence threshold for the current session.
    ///
    /// For far-field (built-in) mics, returns a low fixed threshold
    /// because speech and ambient RMS are virtually indistinguishable
    /// (ratio 1.0–1.2x). The server's far-field noise reduction handles
    /// signal quality, so the silence gate only needs to reject truly
    /// silent presses.
    ///
    /// For near-field mics (AirPods, USB, etc.), uses an adaptive
    /// threshold based on ambient noise when calibration has completed.
    /// Otherwise falls back to the fixed `silenceThreshold`.
    private func audioOwner(_ sessionID: DictationSessionID) -> AudioCaptureOwner {
        .dictation(sessionID)
    }

    private func effectiveSilenceThreshold(
        sessionID: DictationSessionID
    ) -> Float {
        guard let metrics = audioProvider.metrics(owner: audioOwner(sessionID)) else {
            return max(silenceThreshold, minimumAdaptiveThreshold)
        }
        // Built-in mic: skip adaptive threshold entirely.
        if metrics.micProximity == .farField {
            return farFieldSilenceThreshold
        }
        // Near-field mic: use adaptive threshold when ambient is known.
        // Clamp between floor and ceiling so variable ambient (e.g.
        // AirPods noise cancellation adjusting) cannot push the
        // threshold above whisper-range speech.
        let ambient = metrics.ambientRMS
        if ambient > 0 {
            let raw = ambient * ambientMultiplier
            return min(max(raw, minimumAdaptiveThreshold), maximumAdaptiveThreshold)
        }
        return max(silenceThreshold, minimumAdaptiveThreshold)
    }

    private func beginOperation() -> Bool {
        guard !isRetired else { return false }
        activeOperationCount += 1
        return true
    }

    private func endOperation() {
        activeOperationCount -= 1
        if activeOperationCount == 0 {
            let waiters = activeOperationWaiters
            activeOperationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        resumeLifecycleWaitersIfQuiescent()
    }

    private func waitForActiveOperations() async {
        guard activeOperationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            activeOperationWaiters.append(continuation)
        }
    }

    private func beginCompletionOwnership() {
        completionOwnerCount += 1
    }

    private func endCompletionOwnership() {
        completionOwnerCount -= 1
        guard completionOwnerCount == 0 else { return }
        let waiters = completionOwnerWaiters
        completionOwnerWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForCompletionOwners() async {
        guard completionOwnerCount > 0 else { return }
        await withCheckedContinuation { continuation in
            completionOwnerWaiters.append(continuation)
            activationDidBeginWaitingForCompletion()
        }
    }

    private func waitForTerminalIdleTransition() async {
        guard terminalIdleTransitionID != nil else { return }
        await withCheckedContinuation { continuation in
            terminalIdleTransitionWaiters.append(continuation)
        }
    }

    private func finishTerminalIdleTransition(id: UUID) {
        guard terminalIdleTransitionID == id else { return }
        terminalIdleTransitionID = nil
        let waiters = terminalIdleTransitionWaiters
        terminalIdleTransitionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForBufferedPaste() async {
        guard bufferedPasteReservationID != nil else { return }
        await withCheckedContinuation { continuation in
            bufferedPasteWaiters.append(continuation)
        }
    }

    private func finishBufferedPaste(id: UUID) {
        guard bufferedPasteReservationID == id else { return }
        bufferedPasteReservationID = nil
        let waiters = bufferedPasteWaiters
        bufferedPasteWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func ownsSession(_ id: DictationSessionID) -> Bool {
        activeSession?.id == id
    }

    private func ownsActivationReservation(_ id: DictationSessionID) -> Bool {
        activationReservation?.id == id
    }

    private func canContinueActivation(_ id: DictationSessionID) -> Bool {
        !Task.isCancelled && !isRetired && ownsActivationReservation(id)
    }

    private var hasActivationAdmissionBarrier: Bool {
        cancellationDrain != nil
            || terminalIdleTransitionID != nil
            || bufferedPasteReservationID != nil
            || cloudRecordingLimitClaimedID != nil
            || completionOwnerCount > 0
            || audioStartOperation != nil
    }

    private var isCaptureAdmissionSealed: Bool {
        isSealedForReplacement || isSealedForCaptureMaintenance
    }

    private func canContinueBufferedPaste(_ id: UUID) -> Bool {
        canRetainBufferedPasteReservation(id)
            && activeSession == nil
    }

    private func canRetainBufferedPasteReservation(_ id: UUID) -> Bool {
        !Task.isCancelled && !isRetired
            && bufferedPasteReservationID == id
    }

    private enum TerminalIdleTransition {
        case finishInjecting
        case reset
        case resetIf(RecordingState)
    }

    /// Freeze the coordinator's terminal state, release all matching pipeline
    /// ownership, and only then publish `.idle`. A failed claim leaves the
    /// current session untouched, so an accepted Retry cannot be revoked by a
    /// stale Dismiss or authentication-recovery callback.
    @discardableResult
    private func releaseOwnedSessionToIdle(
        _ sessionID: DictationSessionID,
        transition: TerminalIdleTransition,
        releaseState: () -> Void = {}
    ) async -> Bool {
        guard ownsSession(sessionID), terminalIdleTransitionID == nil else {
            return false
        }

        let transitionID = UUID()
        terminalIdleTransitionID = transitionID
        defer { finishTerminalIdleTransition(id: transitionID) }

        let claim: RecordingIdleTransitionClaim?
        switch transition {
        case .finishInjecting:
            claim = await coordinator.claimFinishInjecting(sessionID: sessionID)
        case .reset:
            claim = await coordinator.claimReset(sessionID: sessionID)
        case .resetIf(let expectedState):
            claim = await coordinator.claimReset(
                sessionID: sessionID,
                ifState: expectedState)
        }

        guard let claim else { return false }
        await terminalIdleDidClaim(sessionID)
        guard ownsSession(sessionID) else {
            await coordinator.cancelIdleTransition(claim)
            return false
        }

        releaseState()
        activeSession = nil
        await terminalIdleDidReleaseOwnership(sessionID)
        let committed = await coordinator.commitIdleTransition(claim)
        if committed {
            await terminalIdleDidPublish(sessionID)
        }
        return committed
    }

    private func resetOwnedSession(_ sessionID: DictationSessionID) async {
        _ = await releaseOwnedSessionToIdle(
            sessionID,
            transition: .reset
        ) {
            if pendingContext?.sessionID == sessionID {
                pendingContext?.operation.task.cancel()
                pendingContext = nil
            }
            if completionRetainedPCMStream?.sessionID == sessionID {
                completionRetainedPCMStream = nil
            }
            if captureBoundaryMissedSessionID == sessionID {
                captureBoundaryMissedSessionID = nil
                previewPreRollRecoverySessionID = nil
            }
            if captureBoundary?.sessionID == sessionID {
                _ = captureBoundary?.ledger.release()
                captureBoundary = nil
            }
            if captureStopOperation?.sessionID == sessionID {
                captureStopOperation = nil
            }
        }
    }

    /// Release capture-only state after the last completion owner exits. The
    /// stop task can otherwise retain an entire WAV through the next session.
    private func releaseCaptureResources(sessionID: DictationSessionID) {
        if completionRetainedPCMStream?.sessionID == sessionID {
            completionRetainedPCMStream = nil
        }
        if captureBoundary?.sessionID == sessionID {
            captureBoundary = nil
        }
        if captureStopOperation?.sessionID == sessionID {
            captureStopOperation = nil
        }
    }

    /// Atomically close the capture boundary and publish the stop owner before
    /// this actor can suspend. Once published, every teardown path joins the
    /// same result so none can return while the microphone remains live.
    private func claimCaptureStop(
        sessionID: DictationSessionID,
        releaseHostTime: UInt64? = nil
    ) -> CaptureStopOperation? {
        if let operation = captureStopOperation,
            operation.sessionID == sessionID
        {
            return operation
        }
        guard let boundary = captureBoundary,
            boundary.sessionID == sessionID,
            boundary.ledger.release()
        else { return nil }

        let owner = audioOwner(sessionID)

        // Publish the sample-time boundary before spawning the asynchronous
        // drain. The provider keeps queued callbacks and its PCM stream alive
        // until stopRecording() has retained every pre-release sample prefix.
        if let releaseHostTime {
            audioProvider.closeRecordingBoundary(
                owner: owner,
                atHostTime: releaseHostTime)
        } else {
            audioProvider.closeRecordingBoundary(owner: owner)
        }
        if let pcmStream = audioProvider.pcmAudioStream(owner: owner) {
            completionRetainedPCMStream = (
                sessionID: sessionID,
                stream: pcmStream)
        }
        let id = UUID()
        let task: Task<Result<AudioBuffer, Error>, Never> = Task.detached {
            [audioProvider, owner] in
            do {
                return .success(try await audioProvider.stopRecording(owner: owner))
            } catch {
                // A failed stop is not a terminal hardware state. Force-reset
                // before publishing failure so every joining teardown owner can
                // return knowing the microphone has been closed.
                audioProvider.forceReset(owner: owner)
                return .failure(error)
            }
        }
        let operation = CaptureStopOperation(
            id: id,
            sessionID: sessionID,
            task: task)
        captureStopOperation = operation
        return operation
    }

    private func waitForCancellationDrain() async {
        guard let drain = cancellationDrain else { return }
        await drain.task.value
        finishCancellationDrain(id: drain.id)
    }

    private func reapAudioStartOperation(
        id: UUID,
        task: Task<Result<Void, Error>, Never>
    ) {
        Task.detached { [weak self] in
            _ = await task.result
            await self?.clearAudioStartOperation(id: id)
        }
    }

    private func clearAudioStartOperation(id: UUID) {
        guard audioStartOperation?.id == id else { return }
        audioStartOperation = nil
    }

    @discardableResult
    private func drainRetainedAudioStartOperation() async -> Bool {
        guard let operation = audioStartOperation else { return false }
        let matchingCaptureStop = captureStopOperation.flatMap { stop in
            stop.sessionID == operation.sessionID ? stop : nil
        }
        operation.task.cancel()
        if let matchingCaptureStop {
            _ = await matchingCaptureStop.task.value
            _ = await operation.task.result
        } else if operation.captureLedger.captureWasPublished {
            // Capture already crossed readiness. Its stop owner completed
            // before the retained result was released; only the unrelated
            // post-start work remains to drain.
            _ = await operation.task.result
        } else {
            let owner = audioOwner(operation.sessionID)
            audioProvider.forceReset(owner: owner)
            _ = await operation.task.result
            // A cancellation-insensitive pre-ready start can publish hardware
            // after the first reset. Clean it again after the owner returns.
            audioProvider.forceReset(owner: owner)
            _ = try? await audioProvider.stopRecording(owner: owner)
        }
        if audioStartOperation?.id == operation.id {
            audioStartOperation = nil
        }
        return true
    }

    private func armCloudRecordingLimit(sessionID: DictationSessionID) {
        guard !backend.isLocal else { return }

        cancelPendingCloudRecordingLimit()
        guard cloudRecordingLimitClaimedID == nil else { return }
        let id = UUID()
        let limit = cloudRecordingLimit
        let sleep = cloudRecordingLimitSleep
        cloudRecordingLimitID = id
        cloudRecordingLimitSessionID = sessionID
        cloudRecordingLimitTask = Task { [weak self] in
            await sleep(limit)
            guard !Task.isCancelled else { return }
            await self?.completeCloudRecordingAtLimit(
                id: id,
                sessionID: sessionID)
        }
    }

    /// Cancel a timer that has not started automatic completion. A physical key
    /// release can race the limit callback after it has claimed the recording;
    /// in that case the claimed task must remain alive to publish the result.
    private func cancelPendingCloudRecordingLimit() {
        guard cloudRecordingLimitID != nil else { return }
        cloudRecordingLimitID = nil
        cloudRecordingLimitSessionID = nil
        cloudRecordingLimitTask?.cancel()
        cloudRecordingLimitTask = nil
    }

    /// Cancel every recording-limit phase for explicit cancellation or
    /// retirement. Return a claimed completion so teardown can drain it before a
    /// replacement recording is allowed to start.
    private func takeClaimedCloudRecordingLimitForCancellation()
        -> Task<Void, Never>?
    {
        let claimedTask = cloudRecordingLimitClaimedID == nil
            ? nil
            : cloudRecordingLimitTask
        cloudRecordingLimitID = nil
        cloudRecordingLimitClaimedID = nil
        cloudRecordingLimitSessionID = nil
        cloudRecordingLimitTask?.cancel()
        cloudRecordingLimitTask = nil
        return claimedTask
    }

    private func completeCloudRecordingAtLimit(
        id: UUID,
        sessionID: DictationSessionID
    ) async {
        guard cloudRecordingLimitID == id,
            cloudRecordingLimitSessionID == sessionID,
            ownsSession(sessionID)
        else { return }
        cloudRecordingLimitID = nil
        cloudRecordingLimitClaimedID = id
        defer {
            if cloudRecordingLimitClaimedID == id {
                cloudRecordingLimitClaimedID = nil
                cloudRecordingLimitSessionID = nil
                cloudRecordingLimitTask = nil
            }
        }
        await cloudRecordingLimitDidClaim()
        guard !Task.isCancelled else { return }
        Log.debug("[Pipeline] Cloud recording limit reached; completing full capture")
        await complete(sessionID: sessionID)
    }

    private func waitForClaimedCloudRecordingLimit() async {
        guard cloudRecordingLimitClaimedID != nil,
            let claimedTask = cloudRecordingLimitTask
        else { return }
        await claimedTask.value
    }

    // MARK: - PipelineProviding

    public var state: RecordingState {
        get async {
            await coordinator.state
        }
    }

    public var currentSessionID: DictationSessionID? {
        activeSession?.id
    }

    @discardableResult
    public func activate() async -> DictationSessionID? {
        await activateOwned(releaseBoundary: nil)
    }

    @discardableResult
    public func activate(
        releaseBoundary: AudioCaptureReleaseBoundary
    ) async -> DictationSessionID? {
        await activateOwned(releaseBoundary: releaseBoundary)
    }

    private func activateOwned(
        releaseBoundary: AudioCaptureReleaseBoundary?
    ) async -> DictationSessionID? {
        guard beginOperation() else {
            Log.debug("[Pipeline] activate() ignored - pipeline is retired")
            return nil
        }
        defer { endOperation() }
        guard !Task.isCancelled, !isCaptureAdmissionSealed else {
            Log.debug("[Pipeline] activate() ignored - pipeline is sealed")
            return nil
        }

        guard activationReservation == nil,
            activeSession == nil
                || terminalIdleTransitionID != nil
                || completionOwnerCount > 0
        else {
            Log.debug("[Pipeline] activate() ignored - another session owns admission")
            return nil
        }
        let session = ActiveSession(
            id: DictationSessionID(),
            language: language,
            startedAt: Date(),
            releaseBoundary: releaseBoundary)
        activationReservation = session
        defer {
            if ownsActivationReservation(session.id) {
                activationReservation = nil
            }
        }
        await activationDidReserve()
        guard canContinueActivation(session.id) else { return nil }

        // An owner can be installed while this activation is suspended behind
        // a different owner. Stabilize the complete barrier set, then recheck
        // it after the coordinator read before allocating replacement state.
        var stateReadStartedAt = CFAbsoluteTimeGetCurrent()
        var currentState = RecordingState.idle
        while true {
            await waitForCancellationDrain()
            guard canContinueActivation(session.id) else { return nil }
            await waitForTerminalIdleTransition()
            guard canContinueActivation(session.id) else { return nil }
            await waitForBufferedPaste()
            guard canContinueActivation(session.id) else { return nil }
            await waitForClaimedCloudRecordingLimit()
            guard canContinueActivation(session.id) else { return nil }
            await waitForCompletionOwners()
            guard canContinueActivation(session.id) else { return nil }
            await drainRetainedAudioStartOperation()
            guard canContinueActivation(session.id) else { return nil }

            stateReadStartedAt = CFAbsoluteTimeGetCurrent()
            currentState = await coordinator.state
            guard canContinueActivation(session.id) else { return nil }
            if hasActivationAdmissionBarrier {
                continue
            }
            guard currentState == .idle else {
                Log.debug("[Pipeline] activate() ignored — state is \(currentState)")
                return nil
            }
            break
        }
        let t0 = stateReadStartedAt

        guard canContinueActivation(session.id) else { return nil }
        activationReservation = nil
        activeSession = session
        await activationDidPublishSessionOwner()
        guard !isRetired, ownsSession(session.id) else {
            if ownsSession(session.id) {
                activeSession = nil
            }
            return nil
        }

        let t1 = CFAbsoluteTimeGetCurrent()
        let started = await coordinator.startRecording(sessionID: session.id)
        guard ownsSession(session.id) else {
            if started {
                let reset = await coordinator.reset(sessionID: session.id)
                if reset {
                    await terminalIdleDidPublish(session.id)
                }
            }
            return nil
        }
        guard started else {
            activeSession = nil
            return nil
        }
        guard !isRetired else {
            await resetOwnedSession(session.id)
            return nil
        }
        let t2 = CFAbsoluteTimeGetCurrent()
        Log.debug(
            "[Pipeline] activate() state check: \(String(format: "%.3f", t1 - t0))s, startRecording: \(String(format: "%.3f", t2 - t1))s"
        )

        recordingStartedAt = session.startedAt
        audioSetupFailed = false
        captureBoundary = (
            sessionID: session.id,
            ledger: CaptureBoundaryLedger())
        captureBoundaryMissedSessionID = nil
        previewPreRollRecoverySessionID = nil
        guard !isRetired else {
            await resetOwnedSession(session.id)
            return nil
        }
        armCloudRecordingLimit(sessionID: session.id)
        guard !isRetired else {
            cancelPendingCloudRecordingLimit()
            await resetOwnedSession(session.id)
            return nil
        }

        // State is now .recording — return immediately so the HUD can animate.
        // Audio setup runs in a detached task so it does not execute on the
        // pipeline actor's executor. A plain Task inherits the actor context
        // and can block the actor until the first suspension point, which
        // delays the return from activate() by the full AVAudioEngine start
        // time (0.5-0.9s). Detached tasks run independently, letting
        // activate() return instantly and the HUD expand without delay.
        let pipeline = self
        audioSetupTask = Task.detached {
            await pipeline.performAudioSetup(
                activationTime: t0,
                session: session)
        }
        return session.id
    }

    /// Perform audio capture setup and streaming initialization.
    /// This runs after `activate()` returns, so the HUD can animate immediately.
    private func performAudioSetup(
        activationTime t0: CFAbsoluteTime,
        session: ActiveSession
    ) async {
        // Bail early if cancelled before we even begin (e.g. rapid cancel
        // after activate). Without this check the detached task can start
        // recording after cancel() has already finished its cleanup.
        guard !Task.isCancelled, ownsSession(session.id) else {
            Log.debug("[Pipeline] performAudioSetup() cancelled before start")
            return
        }
        guard let captureLedger = captureBoundary.flatMap({ boundary in
            boundary.sessionID == session.id ? boundary.ledger : nil
        }) else {
            return
        }

        // Start reading context concurrently. The result is awaited in complete().
        let ctxProvider = contextProvider
        let contextOperation = DetachedOperation {
            await ctxProvider.readContext()
        }
        let contextRead = ContextReadOperation(
            id: UUID(),
            sessionID: session.id,
            operation: contextOperation)
        pendingContext = contextRead

        // Start audio capture. This can take 500-900ms due to AVAudioEngine
        // setup. The UI is already showing "listening" state since
        // activate() returned.
        //
        // IMPORTANT: audioProvider.startRecording() runs engine.start()
        // inside a synchronous lock. When the default input device is a
        // Bluetooth device (AirPods), engine.start() can block for
        // seconds while macOS negotiates the SCO audio channel. Because
        // performAudioSetup() is an actor-isolated method, a blocking
        // call here monopolises the pipeline actor's executor — no other
        // actor method (complete(), cancel()) can run until it returns,
        // which freezes the hotkey entirely.
        //
        // Fix: run startRecording() in a detached task so it blocks a
        // cooperative-pool thread instead of the actor. The actor awaits
        // the result via withCheckedContinuation, which suspends (not
        // blocks) the actor. A 3s timeout catches hangs during BT
        // negotiation and lets the pipeline fall back to batch mode.
        let t3 = CFAbsoluteTimeGetCurrent()
        let audioProviderRef = audioProvider
        let captureOwner = audioOwner(session.id)
        enum StartRecordingFailure: Error {
            case timedOutBeforeCapture
            case returnedWithoutReadiness
        }
        let detachedStart = DetachedOperation<Result<Void, Error>> {
            do {
                let onCaptureReady: @Sendable () -> Void = {
                    captureLedger.markCaptureLive()
                }
                try await audioProviderRef.startRecording(
                    owner: captureOwner,
                    configuration: .dictation,
                    releaseBoundary: session.releaseBoundary,
                    onCaptureReady: onCaptureReady)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let audioStartID = UUID()
        audioStartOperation = AudioStartOperation(
            id: audioStartID,
            sessionID: session.id,
            captureLedger: captureLedger,
            task: detachedStart.task)

        // Capture readiness, not unrelated post-start work, is the successful
        // ownership boundary. A deadline can reset only if it atomically wins
        // before readiness; caller cancellation leaves teardown to the shared
        // capture-stop owner.
        let startResult: Result<Void, Error>
        let startDeadlineBeforeCapture: Bool
        let observation = await detachedStart.outcome(
            timeout: audioStartObservationTimeout)
        switch observation {
        case .completed(let completed):
            if audioStartOperation?.id == audioStartID {
                audioStartOperation = nil
            }
            startDeadlineBeforeCapture = false
            if captureLedger.captureWasPublished {
                if case .failure(let error) = completed {
                    Log.debug(
                        "[Pipeline] startRecording() returned an error after capture readiness: \(error)"
                    )
                }
                startResult = .success(())
            } else if case .success = completed {
                startResult = .failure(
                    StartRecordingFailure.returnedWithoutReadiness)
            } else {
                startResult = completed
            }

        case .deadline:
            if captureLedger.claimDeadlineBeforeCapture() {
                Log.debug(
                    "[Pipeline] startRecording() did not publish capture within \(audioStartObservationTimeout)s"
                )
                startDeadlineBeforeCapture = true
                detachedStart.task.cancel()
                audioProvider.forceReset(owner: captureOwner)
                startResult = .failure(
                    StartRecordingFailure.timedOutBeforeCapture)
            } else if captureLedger.captureWasPublished {
                Log.debug(
                    "[Pipeline] Capture is ready; draining delayed startRecording() return independently"
                )
                startDeadlineBeforeCapture = false
                startResult = .success(())
                reapAudioStartOperation(
                    id: audioStartID,
                    task: detachedStart.task)
            } else {
                // Key release or cancellation won before readiness. Its
                // teardown path owns reset/drain and must not be raced here.
                detachedStart.task.cancel()
                return
            }

        case .cancelled:
            detachedStart.task.cancel()
            return
        }

        guard ownsSession(session.id) else {
            if !startDeadlineBeforeCapture,
                captureStopOperation?.sessionID != session.id
            {
                _ = try? await audioProvider.stopRecording(owner: captureOwner)
            }
            return
        }

        switch startResult {
        case .success:
            break
        case .failure(let error):
            Log.debug("[Pipeline] Failed to start recording: \(error)")
            if !startDeadlineBeforeCapture {
                audioProvider.forceReset(owner: captureOwner)
            }
            if !startDeadlineBeforeCapture,
                captureStopOperation?.sessionID != session.id
            {
                _ = try? await audioProvider.stopRecording(owner: captureOwner)
            }
            if pendingContext?.sessionID == session.id {
                pendingContext?.operation.task.cancel()
                pendingContext = nil
            }
            audioSetupFailed = true
            return
        }

        // Check cancellation after starting audio. cancel() may have fired
        // while startRecording() was in progress. Without this, the audio
        // provider stays in the recording state with no one to stop it,
        // causing testCancelFromRecordingResetsToIdle to flake.
        if Task.isCancelled || !ownsSession(session.id) {
            Log.debug("[Pipeline] performAudioSetup() cancelled after startRecording")
            if captureStopOperation?.sessionID != session.id {
                _ = try? await audioProvider.stopRecording(owner: captureOwner)
            }
            if pendingContext?.sessionID == session.id {
                pendingContext?.operation.task.cancel()
                pendingContext = nil
            }
            return
        }

        if captureBoundaryMissedSessionID == session.id,
            previewPreRollRecoverySessionID == session.id
        {
            Log.debug(
                "[Pipeline] Audio capture became live after key release; draining exact pre-roll"
            )
            if let lateStop = claimCaptureStop(
                sessionID: session.id,
                releaseHostTime: session.releaseBoundary?.releaseHostTime)
            {
                captureBoundaryMissedSessionID = nil
                previewPreRollRecoverySessionID = nil
                await captureStopDidClaim()
                _ = lateStop
            }
        }
        let t4 = CFAbsoluteTimeGetCurrent()
        Log.debug(
            "[Pipeline] performAudioSetup() audioProvider.startRecording: \(String(format: "%.3f", t4 - t3))s"
        )

        // Both supported backends stream when PCM capture is available. A
        // local release may already have stopped the provider, so claim the
        // stream retained by complete() before stopRecording cleared it.
        let pcmStream = audioProvider.pcmAudioStream(owner: captureOwner)
            ?? completionRetainedPCMStream.flatMap { retained in
                retained.sessionID == session.id ? retained.stream : nil
            }
        if completionRetainedPCMStream?.sessionID == session.id {
            completionRetainedPCMStream = nil
        }
        if let pcmStream {
            let streaming = backend.streamingProvider
            isStreamingSession = true

            // Await context early for the streaming start message. Use
            // a short timeout so we do not delay the session opening.
            let context: AppContext
            if let pending = pendingContext,
                pending.sessionID == session.id
            {
                let result = await pending.operation.value(
                    timeout: contextObservationTimeout)
                context = result ?? .empty
            } else {
                context = .empty
            }

            guard !Task.isCancelled, ownsSession(session.id) else {
                isStreamingSession = false
                if captureStopOperation?.sessionID != session.id {
                    _ = try? await audioProvider.stopRecording(owner: captureOwner)
                }
                return
            }

            let t5 = CFAbsoluteTimeGetCurrent()
            let micProximity = audioProvider.metrics(owner: captureOwner)?
                .micProximity ?? .nearField
            let language = session.language

            // Neither mode injects mid-stream. Local assembles one final
            // transcript from bounded units; cloud stays atomic because
            // arbitrary target applications cannot safely revise text after
            // injection. The pipeline injects each provider's result once.
            streaming.setChunkHandler(nil)

            // Local pause detection uses the same ambient-adaptive threshold as
            // the silent-press gate, so real acoustic pauses close units rather
            // than only the size cap.
            if backend.isLocal {
                (streaming as? LocalStreamingProvider)?
                    .setSilenceThreshold(
                        effectiveSilenceThreshold(sessionID: session.id))
            }

            // Cloud setup has a bounded fallback path. Local setup has no
            // alternate recognizer, so completion must retain and drain it
            // rather than discarding the exact capture at an arbitrary timer.
            Log.debug(
                "[Pipeline] Starting streaming setup (language=\(language ?? "nil"))"
            )
            let detachedSetup = DetachedOperation<Bool> {
                do {
                    Log.debug("[Pipeline] streaming.startStreaming() entering")
                    try await streaming.startStreaming(
                        sessionID: session.id,
                        context: context,
                        language: language,
                        micProximity: micProximity)
                    Log.debug("[Pipeline] streaming.startStreaming() returned OK")
                    return true
                } catch {
                    Log.debug("[Pipeline] streaming.startStreaming() failed: \(error)")
                    return false
                }
            }
            let streamingSetupID = UUID()
            streamingSetupOperation = StreamingSetupOperation(
                id: streamingSetupID,
                sessionID: session.id,
                task: detachedSetup.task)

            let streamingStarted: Bool
            if backend.isLocal {
                streamingStarted = await detachedSetup.task.value
            } else if let result = await detachedSetup.value(timeout: 5.0) {
                streamingStarted = result
            } else {
                Log.debug("[Pipeline] Streaming setup timeout fired after 5s")
                detachedSetup.task.cancel()
                await streaming.cancelStreaming(sessionID: session.id)
                _ = await detachedSetup.task.value
                streamingStarted = false
            }
            if streamingSetupOperation?.id == streamingSetupID {
                streamingSetupOperation = nil
            }

            guard !Task.isCancelled, ownsSession(session.id) else {
                streaming.setChunkHandler(nil)
                await streaming.cancelStreaming(sessionID: session.id)
                isStreamingSession = false
                if captureStopOperation?.sessionID != session.id,
                    audioProvider.isRecording(owner: captureOwner)
                {
                    _ = try? await audioProvider.stopRecording(owner: captureOwner)
                }
                return
            }

            // If streaming timed out, also cancel the session on the
            // provider so it tears down the broken connection cleanly
            // rather than leaving stale state for the next session.
            if !streamingStarted {
                await streaming.cancelStreaming(sessionID: session.id)
            }

            guard streamingStarted else {
                Log.debug("[Pipeline] Streaming setup timed out or failed, falling back to batch")
                streaming.setChunkHandler(nil)
                isStreamingSession = false
                return
            }
            guard ownsSession(session.id) else {
                await streaming.cancelStreaming(sessionID: session.id)
                return
            }
            let t6 = CFAbsoluteTimeGetCurrent()
            Log.debug(
                "[Pipeline] performAudioSetup() streaming.startStreaming: \(String(format: "%.3f", t6 - t5))s, total: \(String(format: "%.3f", t6 - t0))s"
            )

            audioForwardingOperation = AudioForwardingOperation(
                stream: pcmStream,
                send: { chunk in
                    try await streaming.sendAudio(
                        chunk,
                        sessionID: session.id)
                })
        } else {
            isStreamingSession = false
        }
    }

    private func handleCaptureStopFailure(
        sessionID: DictationSessionID,
        streamingProvider: any StreamingDictationProviding
    ) async {
        Log.debug(
            "[Pipeline] Capture stop failed after terminal reset; refusing transcription"
        )
        let setupTask = audioSetupTask
        audioSetupTask = nil
        setupTask?.cancel()
        await setupTask?.value

        let forwardingOperation = audioForwardingOperation
        audioForwardingOperation = nil
        streamingProvider.setChunkHandler(nil)
        if let forwardingOperation {
            await forwardingOperation.cancel {
                await streamingProvider.cancelStreaming(sessionID: sessionID)
            }
        } else {
            await streamingProvider.cancelStreaming(sessionID: sessionID)
        }
        isStreamingSession = false
        audioSetupFailed = false
        recordingStartedAt = nil
        _ = await coordinator.failDictation(sessionID: sessionID)
    }

    public func complete() async {
        await complete(expectedSessionID: nil, releaseHostTime: nil)
    }

    public func complete(sessionID: DictationSessionID) async {
        await complete(expectedSessionID: sessionID, releaseHostTime: nil)
    }

    public func complete(
        sessionID: DictationSessionID,
        releaseHostTime: UInt64
    ) async {
        await complete(
            expectedSessionID: sessionID,
            releaseHostTime: releaseHostTime)
    }

    private func complete(
        expectedSessionID: DictationSessionID?,
        releaseHostTime: UInt64?
    ) async {
        guard beginOperation() else {
            Log.debug("[Pipeline] complete() ignored - pipeline is retired")
            return
        }
        defer { endOperation() }
        if let expectedSessionID, activeSession?.id != expectedSessionID {
            Log.debug("[Pipeline] complete() ignored - stale session")
            return
        }
        let establishesReleaseBoundary = completionOwnerCount == 0
        beginCompletionOwnership()
        var ownedCompletionSessionID: DictationSessionID?
        defer {
            endCompletionOwnership()
            if completionOwnerCount == 0, let ownedCompletionSessionID {
                releaseCaptureResources(sessionID: ownedCompletionSessionID)
            }
        }
        guard let session = activeSession else {
            Log.debug("[Pipeline] complete() ignored - no active session")
            return
        }
        let captureOwner = audioOwner(session.id)
        ownedCompletionSessionID = session.id
        if let releaseHostTime {
            _ = session.releaseBoundary?.publish(
                releaseHostTime: releaseHostTime)
        }
        let canRecoverPreviewPreRoll: Bool
        if establishesReleaseBoundary, let boundary = session.releaseBoundary {
            // Snapshot preview proof before releasing the readiness ledger. A
            // concurrent promotion publishes readiness and then clears its
            // one-shot proof; readiness before this snapshot wins through the
            // stop claim below, while readiness after it cannot erase proof.
            canRecoverPreviewPreRoll =
                audioProvider.canRecoverCaptureReleasedBeforeReadiness(
                    owner: captureOwner,
                    pressHostTime: boundary.pressHostTime)
        } else {
            canRecoverPreviewPreRoll = false
        }
        let releaseCaptureStopOperation: CaptureStopOperation?
        if establishesReleaseBoundary {
            releaseCaptureStopOperation = claimCaptureStop(
                sessionID: session.id,
                releaseHostTime: releaseHostTime)
        } else if let operation = captureStopOperation,
            operation.sessionID == session.id
        {
            releaseCaptureStopOperation = operation
        } else {
            releaseCaptureStopOperation = nil
        }
        let missedCaptureBoundary =
            establishesReleaseBoundary && releaseCaptureStopOperation == nil
        if missedCaptureBoundary {
            captureBoundaryMissedSessionID = session.id
            if canRecoverPreviewPreRoll {
                previewPreRollRecoverySessionID = session.id
            } else {
                previewPreRollRecoverySessionID = nil
                Log.debug(
                    "[Pipeline] Capture was not live at key release and has no retained preview coverage; resetting"
                )
                audioProvider.forceReset(owner: captureOwner)
            }
        }
        if establishesReleaseBoundary {
            await completionDidEstablishReleaseBoundary()
        }
        if establishesReleaseBoundary, releaseCaptureStopOperation != nil {
            await captureStopDidClaim()
        }
        let streamingProvider = backend.streamingProvider
        let cloudFallback = backend.cloudFallback
        let completionGeneration = cancellationGeneration
        cancelPendingCloudRecordingLimit()
        if await abortCompletionIfCancelledOrRetired(
            completionGeneration: completionGeneration,
            sessionID: session.id
        ) {
            return
        }
        let completeEnteredAt = CFAbsoluteTimeGetCurrent()
        Log.debug("[Pipeline] complete() entering")
        let currentState = await coordinator.state
        if await abortCompletionIfCancelledOrRetired(
            completionGeneration: completionGeneration,
            sessionID: session.id
        ) {
            return
        }
        guard currentState == .recording else {
            if missedCaptureBoundary,
                completionOwnerCount == 1,
                captureBoundaryMissedSessionID == session.id
            {
                captureBoundaryMissedSessionID = nil
                previewPreRollRecoverySessionID = nil
            }
            Log.debug("[Pipeline] complete() ignored — state is \(currentState)")
            return
        }

        Log.debug("[Pipeline] complete() transitioning to processing")
        let stopped = await coordinator.stopRecording(sessionID: session.id)
        if await abortCompletionIfCancelledOrRetired(
            completionGeneration: completionGeneration,
            sessionID: session.id
        ) {
            return
        }
        guard stopped else { return }

        // End capture at key release even when provider setup is still loading.
        // The already-created AsyncStream keeps buffered PCM available for the
        // forwarding owner after setup drains. No backend may observe PCM that
        // arrived after the user released the dictation key.
        var releasedAudioBuffer: AudioBuffer?
        var captureStopFailed: Bool
        if let releaseCaptureStopOperation {
            switch await releaseCaptureStopOperation.task.value {
            case .success(let audioBuffer):
                releasedAudioBuffer = audioBuffer
                captureStopFailed = false
            case .failure(let error):
                Log.debug("[Pipeline] Failed to stop audio at release: \(error)")
                releasedAudioBuffer = nil
                captureStopFailed = true
            }
        } else {
            releasedAudioBuffer = nil
            captureStopFailed = false
        }
        if await abortCompletionIfCancelledOrRetired(
            completionGeneration: completionGeneration,
            sessionID: session.id
        ) {
            return
        }

        if captureStopFailed {
            await handleCaptureStopFailure(
                sessionID: session.id,
                streamingProvider: streamingProvider)
            return
        }

        // Cloud setup gets a short window before falling back to the complete
        // audio buffer. Local setup is retained because there is no alternate
        // recognizer for that capture.
        //
        // IMPORTANT: We cannot use `await setupTask.value` directly or
        // inside a TaskGroup, because the setup task runs on this actor
        // and may be blocked on a non-cancellable operation (e.g.
        // URLSession sendPing). TaskGroup.cancelAll() doesn't unblock
        // children that are stuck in non-cancellable awaits, and the
        // group won't return until all children exit. Instead we use a
        // detached polling loop that checks whether the task has set
        // `isStreamingSession` or completed, with a hard 6s deadline.
        // If the audio is clearly silent, skip the streaming setup wait
        // entirely. peakRMS is updated by the tap callback during
        // recording, so it reflects the loudest moment. When it is below
        // the silence threshold, there is nothing to transcribe and
        // waiting 5-6s for a stale WebSocket ping to time out is waste.
        let earlyThreshold = effectiveSilenceThreshold(sessionID: session.id)
        // A peakRMS of exactly 0 means no audio was captured yet (the
        // tap hasn't fired). Skip the early silence gate in this case
        // so rapid hotkey taps don't silently discard speech.
        if let earlyMetrics = audioProvider.metrics(owner: captureOwner),
            earlyMetrics.peakRMS > 0,
            earlyMetrics.peakRMS <= earlyThreshold
        {
            let setupTask = audioSetupTask
            setupTask?.cancel()
            audioSetupTask = nil
            isStreamingSession = false
            let forwardingOperation = audioForwardingOperation
            audioForwardingOperation = nil
            if let forwardingOperation {
                await forwardingOperation.cancel { [streamingProvider] in
                    await streamingProvider.cancelStreaming(sessionID: session.id)
                }
            } else {
                await streamingProvider.cancelStreaming(sessionID: session.id)
            }
            await setupTask?.value

            Log.debug(
                "[Pipeline] Early silence short-circuit: peak RMS \(earlyMetrics.peakRMS) <= \(earlyThreshold) (ambient: \(earlyMetrics.ambientRMS)), skipping setup wait"
            )

            if let store = micDiagnosticStore {
                await store.record(
                    MicDiagnosticEntry(
                        deviceName: earlyMetrics.deviceName,
                        proximity: earlyMetrics.micProximity.rawValue,
                        ambientRMS: earlyMetrics.ambientRMS,
                        peakRMS: earlyMetrics.peakRMS,
                        gain: earlyMetrics.gainFactor,
                        threshold: earlyThreshold,
                        duration: 0,
                        latency: 0,
                        result: "silent"
                    ))
            }

            // Stop audio and reset immediately if release did not already do so.
            if releasedAudioBuffer == nil {
                _ = try? await audioProvider.stopRecording(owner: captureOwner)
            }
            await resetOwnedSession(session.id)
            return
        }

        if let setupTask = audioSetupTask {
            if backend.isLocal {
                // Local has no alternate recognizer. Retain model setup and
                // the buffered PCM stream until it can produce the one final
                // candidate instead of dropping the capture at six seconds.
                await setupTask.value
                Log.debug("[Pipeline] complete() local audio setup finished")
            } else {
                let watchdog = audioSetupCompletionWatchdog
                let watchdogSleep = audioSetupCompletionSleep
                let setupDone: Bool = await withCheckedContinuation { continuation in
                    let lock = NSLock()
                    var resumed = false

                    // Monitor task observes the retained setup owner without
                    // making it a structured child of the deadline race.
                    Task.detached {
                        await setupTask.value
                        let alreadyResumed = lock.withLock {
                            let was = resumed
                            resumed = true
                            return was
                        }
                        if !alreadyResumed {
                            continuation.resume(returning: true)
                        }
                    }

                    Task.detached {
                        await watchdogSleep(watchdog)
                        let alreadyResumed = lock.withLock {
                            let was = resumed
                            resumed = true
                            return was
                        }
                        if !alreadyResumed {
                            setupTask.cancel()
                            continuation.resume(returning: false)
                        }
                    }

                    // Silence observer: bail after 200ms of confirmed silence
                    // without coupling the hard watchdog to wall-clock polling.
                    Task.detached { [audioProvider, captureOwner, earlyThreshold] in
                        var silentTicks = 0
                        while true {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            let alreadyDone = lock.withLock { resumed }
                            if alreadyDone { return }

                            if let metrics = audioProvider.metrics(owner: captureOwner),
                                metrics.peakRMS > 0,
                                metrics.peakRMS <= earlyThreshold
                            {
                                silentTicks += 1
                                // 4 ticks × 50ms = 200ms of confirmed silence
                                if silentTicks >= 4 {
                                    Log.debug(
                                        "[Pipeline] Setup wait bailing early: silent audio (peak RMS \(metrics.peakRMS), threshold \(earlyThreshold))"
                                    )
                                    let alreadyResumed = lock.withLock {
                                        let was = resumed
                                        resumed = true
                                        return was
                                    }
                                    if !alreadyResumed {
                                        setupTask.cancel()
                                        continuation.resume(returning: false)
                                    }
                                    return
                                }
                            } else {
                                silentTicks = 0
                            }
                        }
                    }
                }

                if setupDone {
                    Log.debug("[Pipeline] complete() audio setup finished normally")
                } else {
                    Log.debug("[Pipeline] complete() audio setup timed out, cancelling")
                    // Give the streaming provider a clean teardown so it
                    // doesn't leave broken connection state.
                    await streamingProvider.cancelStreaming(sessionID: session.id)
                    await setupTask.value
                    isStreamingSession = false
                }
            }
            audioSetupTask = nil
        }

        if releasedAudioBuffer == nil,
            !captureStopFailed,
            let lateStop = captureStopOperation,
            lateStop.sessionID == session.id
        {
            switch await lateStop.task.value {
            case .success(let audioBuffer):
                releasedAudioBuffer = audioBuffer
            case .failure(let error):
                Log.debug("[Pipeline] Failed to drain late capture: \(error)")
                captureStopFailed = true
            }
        }
        if captureStopFailed {
            await handleCaptureStopFailure(
                sessionID: session.id,
                streamingProvider: streamingProvider)
            return
        }

        await completionWillHandoff()
        if await abortCompletionIfCancelledOrRetired(
            completionGeneration: completionGeneration,
            sessionID: session.id
        ) {
            return
        }

        if captureBoundaryMissedSessionID == session.id {
            Log.debug(
                "[Pipeline] Capture was not live at key release; retaining explicit failure"
            )
            captureBoundaryMissedSessionID = nil
            previewPreRollRecoverySessionID = nil
            audioSetupFailed = false
            isStreamingSession = false
            recordingStartedAt = nil
            let drainedLateStart = await drainRetainedAudioStartOperation()
            if !drainedLateStart {
                _ = try? await audioProvider.stopRecording(owner: captureOwner)
            }
            _ = await coordinator.failDictation(sessionID: session.id)
            return
        }

        // If audio setup failed (e.g. BT negotiation timeout), there
        // is no audio to transcribe. Reset and return immediately.
        if audioSetupFailed {
            Log.debug("[Pipeline] Audio setup failed, skipping dictation")
            audioSetupFailed = false
            isStreamingSession = false
            let drainedLateStart = await drainRetainedAudioStartOperation()
            if releasedAudioBuffer == nil, !drainedLateStart {
                _ = try? await audioProvider.stopRecording(owner: captureOwner)
            }
            await resetOwnedSession(session.id)
            return
        }

        let useStreaming = isStreamingSession
        let forwardingOperation = audioForwardingOperation
        audioForwardingOperation = nil
        isStreamingSession = false

        // Clear the chunk handler before entering the pipeline task so
        // late-arriving chunks cannot inject text during finishStreaming.
        if useStreaming {
            streamingProvider.setChunkHandler(nil)
        }

        let (pipelineCompletion, pipelineCompletionContinuation) =
            AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let sessionContext = pendingContext.flatMap { pending in
            pending.sessionID == session.id ? pending : nil
        }
        let task = Task {
            [
                sessionContext, audioProvider, streamingProvider,
                textInjector, coordinator, transcriptBuffer,
                micDiagnosticStore,
                completeEnteredAt, releasedAudioBuffer
            ] in
            var cancellationRecovery: (audio: Data, context: AppContext)?
            defer {
                sessionContext?.operation.task.cancel()
                if Task.isCancelled, let cancellationRecovery {
                    retainRecovery(
                        sessionID: session.id,
                        audio: cancellationRecovery.audio,
                        context: cancellationRecovery.context,
                        language: session.language)
                }
                pipelineCompletionContinuation.yield(())
                pipelineCompletionContinuation.finish()
            }
            let t0 = CFAbsoluteTimeGetCurrent()

            // Stop audio capture and retrieve the buffer.
            Log.debug("[Pipeline] stopping audio capture")
            let audioBuffer: AudioBuffer
            if let releasedAudioBuffer {
                audioBuffer = releasedAudioBuffer
            } else {
                do {
                    audioBuffer = try await audioProvider.stopRecording(
                        owner: captureOwner)
                } catch {
                    guard ownsSession(session.id) else { return }
                    Log.debug("[Pipeline] Failed to stop recording: \(error)")
                    if let forwardingOperation {
                        await forwardingOperation.cancel {
                            await streamingProvider.cancelStreaming(sessionID: session.id)
                        }
                    } else if useStreaming {
                        await streamingProvider.cancelStreaming(sessionID: session.id)
                    }
                    await resetOwnedSession(session.id)
                    return
                }
            }

            let t1 = CFAbsoluteTimeGetCurrent()
            Log.debug(
                "[Pipeline] audio stopped (\(String(format: "%.2f", audioBuffer.duration))s, \(audioBuffer.data.count)B)"
            )

            guard !audioBuffer.data.isEmpty else {
                Log.debug("[Pipeline] Capture produced no accepted audio")
                if let forwardingOperation {
                    await forwardingOperation.cancel {
                        await streamingProvider.cancelStreaming(
                            sessionID: session.id)
                    }
                } else if useStreaming {
                    await streamingProvider.cancelStreaming(sessionID: session.id)
                }
                guard ownsSession(session.id) else { return }
                if missedCaptureBoundary {
                    _ = await coordinator.failDictation(sessionID: session.id)
                } else {
                    await resetOwnedSession(session.id)
                }
                return
            }

            // Early silence check: use the peak RMS tracked during
            // recording to reject silent presses immediately, before
            // waiting on the streaming forwarding operation or any network
            // calls. This avoids the 5-7s delay users see when they
            // tap the hotkey without speaking.
            // Recompute the threshold now that ambient calibration may
            // have finished during recording. Use effectiveSilenceThreshold()
            // which respects far-field mic proximity (built-in mics use
            // a low fixed threshold instead of the adaptive calculation).
            let postRecordThreshold = effectiveSilenceThreshold(
                sessionID: session.id)

            if let postRecordMetrics = audioProvider.metrics(owner: captureOwner),
                postRecordMetrics.peakRMS <= postRecordThreshold
            {
                Log.debug(
                    "[Pipeline] Early silence gate: peak RMS \(postRecordMetrics.peakRMS) <= \(postRecordThreshold) (ambient: \(postRecordMetrics.ambientRMS)), skipping"
                )
                if let store = micDiagnosticStore {
                    await store.record(
                        MicDiagnosticEntry(
                            deviceName: postRecordMetrics.deviceName,
                            proximity: postRecordMetrics.micProximity.rawValue,
                            ambientRMS: postRecordMetrics.ambientRMS,
                            peakRMS: postRecordMetrics.peakRMS,
                            gain: postRecordMetrics.gainFactor,
                            threshold: postRecordThreshold,
                            duration: audioBuffer.duration,
                            latency: 0,
                            result: "silent"
                        ))
                }
                if let forwardingOperation {
                    await forwardingOperation.cancel {
                        await streamingProvider.cancelStreaming(sessionID: session.id)
                    }
                } else if useStreaming {
                    await streamingProvider.cancelStreaming(sessionID: session.id)
                }
                guard ownsSession(session.id) else { return }
                await resetOwnedSession(session.id)
                return
            }

            if !audioBuffer.data.isEmpty {
                cancellationRecovery = (audioBuffer.data, .empty)
                pipelineDidCaptureRecovery(session.id)
            }

            var streamingCandidateIsValid = false
            if useStreaming {
                if let forwardingOperation {
                    let forwardingOutcome = await forwardingOperation.drain(
                        timeout: .seconds(2),
                        cancelStreaming: {
                            await streamingProvider.cancelStreaming(sessionID: session.id)
                        })
                    streamingCandidateIsValid = forwardingOutcome == .drained
                    if !streamingCandidateIsValid {
                        Log.debug(
                            "[Pipeline] audio forwarding invalidated streaming: "
                                + "\(forwardingOutcome)")
                    }
                } else {
                    if let forwardingOperation {
                        await forwardingOperation.cancel {
                            await streamingProvider.cancelStreaming(
                                sessionID: session.id)
                        }
                    } else {
                        await streamingProvider.cancelStreaming(sessionID: session.id)
                    }
                    Log.debug("[Pipeline] streaming session has no forwarding owner")
                }
            } else if let forwardingOperation {
                await forwardingOperation.cancel {
                    await streamingProvider.cancelStreaming(sessionID: session.id)
                }
            }

            guard !Task.isCancelled else { return }

            // Resolve context once. The retained operation caches its
            // result, so awaiting it again (streaming already awaited it
            // in activate) returns the same value instantly.
            let context: AppContext
            if let sessionContext {
                let result = await sessionContext.operation.value(
                    timeout: contextObservationTimeout)
                context = result ?? .empty
                sessionContext.operation.task.cancel()
            } else {
                context = .empty
            }
            if cancellationRecovery != nil {
                cancellationRecovery = (audioBuffer.data, context)
            }

            // Resolve the transcript from the appropriate provider.
            let resolvedDictation: ResolvedDictation?
            switch backend {
            case .local(let streaming):
                if useStreaming {
                    let text = await finishLocalDictation(
                        sessionID: session.id,
                        language: session.language,
                        streaming: streaming,
                        streamingCandidateIsValid: streamingCandidateIsValid,
                        audioBuffer: audioBuffer,
                        context: context,
                        coordinator: coordinator)
                    resolvedDictation = text.map {
                        ResolvedDictation(text: $0, source: .local)
                    }
                } else {
                    Log.debug("[Pipeline] Local streaming setup unavailable")
                    retainRecovery(
                        sessionID: session.id,
                        audio: audioBuffer.data,
                        context: context,
                        language: session.language)
                    _ = await coordinator.failDictation(sessionID: session.id)
                    resolvedDictation = nil
                }

            case .cloud(let realtime, let fallback):
                if useStreaming {
                    resolvedDictation = await finishCloudDictation(
                        sessionID: session.id,
                        language: session.language,
                        streaming: realtime,
                        streamingCandidateIsValid: streamingCandidateIsValid,
                        audioBuffer: audioBuffer,
                        context: context,
                        batchProvider: fallback,
                        coordinator: coordinator,
                        diagnosticStartedAt: t0,
                        silenceThreshold: postRecordThreshold)
                } else {
                    Log.debug("[Pipeline] Realtime unavailable, using HTTP fallback")
                    let text = await batchDictate(
                        sessionID: session.id,
                        language: session.language,
                        audioBuffer: audioBuffer,
                        context: context,
                        batchProvider: fallback,
                        coordinator: coordinator,
                        diagnosticStartedAt: t0,
                        silenceThreshold: postRecordThreshold)
                    resolvedDictation = text.map {
                        ResolvedDictation(text: $0, source: .httpFallback)
                    }
                }
            }

            guard let resolvedDictation else { return }

            let t4 = CFAbsoluteTimeGetCurrent()

            // Inject the result.
            await injectResult(
                resolvedDictation.text,
                sessionID: session.id,
                context: context,
                audioBuffer: audioBuffer,
                coordinator: coordinator,
                textInjector: textInjector,
                transcriptBuffer: transcriptBuffer,
                micDiagnosticStore: micDiagnosticStore,
                audioProvider: audioProvider,
                silenceThreshold: postRecordThreshold,
                t0: t0, t1: t1, t4: t4,
                completeEnteredAt: completeEnteredAt,
                mode: resolvedDictation.source.rawValue)
        }

        self.pipelineTask = task
        if self.pendingContext?.id == sessionContext?.id {
            self.pendingContext = nil
        }

        // Bound the entire pipeline task so a hang (stuck WebSocket
        // send, server not responding, etc.) cannot permanently leave
        // the pipeline in `.processing` and swallow all subsequent
        // activate()/complete() calls.
        //
        // The budget scales with the recording duration: short
        // dictations get the 45 s baseline; long dictations get enough
        // time for transcription tail + polish + injection. Without
        // scaling, a 130 s monologue blows past a fixed 15 s deadline
        // and the force-reset races the batch HTTP fallback, dropping
        // a valid transcript instead of injecting it.
        let recordingDuration =
            recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let requiresCloudBatchWindow = cloudFallback != nil
        let cloudStreamingProvider =
            requiresCloudBatchWindow && useStreaming
            ? streamingProvider
            : nil
        let deadline = Self.pipelineDeadline(
            forRecordingDuration: recordingDuration,
            cloudStreamingProvider: cloudStreamingProvider,
            requiresCloudBatchWindow: requiresCloudBatchWindow)
        let pipelineDone = await Self.waitForCompletion(
            pipelineCompletion,
            timeout: .seconds(deadline))
        if !pipelineDone {
            Log.debug(
                "[Pipeline] complete() ending before pipeline task (\(Int(deadline))s deadline), cancelling"
            )
            task.cancel()
            await streamingProvider.cancelStreaming(sessionID: session.id)
            await task.value
            guard ownsSession(session.id) else { return }
            let stateAfterCancellation = await coordinator.state
            switch stateAfterCancellation {
            case .processing:
                if recovery?.sessionID == session.id {
                    _ = await coordinator.failDictation(sessionID: session.id)
                } else {
                    await resetOwnedSession(session.id)
                }
            case .injecting:
                recovery = nil
                _ = await coordinator.failInjection(sessionID: session.id)
            case .idle, .injectionFailed:
                // Injection either completed or the final transcript is already
                // buffered for manual paste. A second WAV recovery could duplicate it.
                recovery = nil
            case .dictationFailed, .sessionExpired:
                break
            case .recording:
                recovery = nil
                await resetOwnedSession(session.id)
            }
        }
        self.pipelineTask = nil
        self.recordingStartedAt = nil
    }

    private func abortCompletionIfCancelledOrRetired(
        completionGeneration: UInt64,
        sessionID: DictationSessionID
    ) async -> Bool {
        guard cancellationGeneration == completionGeneration,
            cancellationDrain == nil,
            ownsSession(sessionID)
        else { return true }
        guard Task.isCancelled || isRetired else { return false }
        activeSession = nil
        cancellationGeneration &+= 1
        await cancelAndDrain(sessionID: sessionID)
        return true
    }

    /// Time reserved after Realtime finalization for full-file transcription,
    /// deterministic cleanup, injection, and teardown. The HTTP request is
    /// bounded at 60 seconds; the remaining budget covers pipeline handoff and
    /// downstream delivery without clipping the recovery path.
    static let cloudBatchRecoveryReserve: TimeInterval = 100

    /// Compute the hard deadline for a pipeline task given how long the user
    /// held the hotkey. The base budget is `recordingDuration + 45`, capped at
    /// 300 seconds. A cloud path with batch recovery also reserves the complete
    /// fallback window after the streaming provider's stable maximum finish
    /// watchdog. The five-minute product limit keeps that composed budget below
    /// the 300-second ceiling.
    static func pipelineDeadline(
        forRecordingDuration duration: TimeInterval,
        cloudStreamingProvider: StreamingDictationProviding?,
        requiresCloudBatchWindow: Bool
    ) -> TimeInterval {
        pipelineDeadline(
            forRecordingDuration: duration,
            cloudStreamingMaximumFinishWatchdog:
                cloudStreamingProvider?.maximumFinishStreamingWatchdog,
            requiresCloudBatchWindow: requiresCloudBatchWindow)
    }

    static func pipelineDeadline(
        forRecordingDuration duration: TimeInterval,
        cloudStreamingMaximumFinishWatchdog: TimeInterval? = nil,
        requiresCloudBatchWindow: Bool = false
    ) -> TimeInterval {
        var budget = max(30.0, duration + 45.0)
        if requiresCloudBatchWindow {
            budget = max(
                budget,
                max(0, cloudStreamingMaximumFinishWatchdog ?? 0)
                    + cloudBatchRecoveryReserve)
        }
        return min(300.0, max(30.0, budget))
    }

    private static func waitForCompletion(
        _ completion: AsyncStream<Void>,
        timeout: Duration
    ) async -> Bool {
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in completion {
                    guard !Task.isCancelled else { return false }
                    return true
                }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    try Task.checkCancellation()
                    return false
                } catch {
                    return false
                }
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return !Task.isCancelled && completed
    }

    public func cancel() async {
        if let sessionID = activeSession?.id {
            await cancel(sessionID: sessionID)
            return
        }
        if activationReservation != nil {
            activationReservation = nil
            cancellationGeneration &+= 1
        }
        await waitForCancellationDrain()
    }

    public func cancel(sessionID: DictationSessionID) async {
        guard ownsSession(sessionID) else { return }
        // Publish capture teardown before clearing session ownership. Otherwise
        // audio setup can resume in the scheduling gap, observe the cleared
        // session, and independently stop the provider before the cancellation
        // drain claims its shared owner.
        _ = claimCaptureStop(sessionID: sessionID)
        activeSession = nil
        cancellationGeneration &+= 1
        await cancelAndDrain(sessionID: sessionID)
    }

    private func cancelAndDrain(sessionID: DictationSessionID? = nil) async {
        let cancellationDrain = startCancellationDrain(sessionID: sessionID)
        await cancellationDrain.task.value
        finishCancellationDrain(id: cancellationDrain.id)
    }

    private func startCancellationDrain(
        sessionID: DictationSessionID? = nil
    ) -> CancellationDrain {
        if let cancellationDrain { return cancellationDrain }
        let runningCaptureStopOperation: CaptureStopOperation?
        if let operation = captureStopOperation,
            sessionID == nil || operation.sessionID == sessionID
        {
            runningCaptureStopOperation = operation
        } else if let boundary = captureBoundary,
            sessionID == nil || boundary.sessionID == sessionID
        {
            runningCaptureStopOperation = claimCaptureStop(
                sessionID: boundary.sessionID)
        } else {
            runningCaptureStopOperation = nil
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCancellationDrain(
                sessionID: sessionID,
                captureStopOperation: runningCaptureStopOperation)
        }
        let drain = CancellationDrain(id: id, task: task)
        cancellationDrain = drain
        return drain
    }

    private func finishCancellationDrain(id: UUID) {
        guard cancellationDrain?.id == id else { return }
        cancellationDrain = nil
        resumeLifecycleWaitersIfQuiescent()
    }

    private func performCancellationDrain(
        sessionID: DictationSessionID?,
        captureStopOperation runningCaptureStopOperation: CaptureStopOperation?
    ) async {
        await cancellationDrainDidStart()
        cancellationDidSelectCaptureStop(runningCaptureStopOperation != nil)
        let runningCloudRecordingLimitTask =
            takeClaimedCloudRecordingLimitForCancellation()
        let runningPipelineTask = pipelineTask
        pipelineTask = nil
        let runningContextTask = pendingContext
        pendingContext = nil
        let runningSetupTask = audioSetupTask
        audioSetupTask = nil
        let runningAudioStartOperation = audioStartOperation
        audioStartOperation = nil
        let runningStreamingSetupOperation = streamingSetupOperation
        streamingSetupOperation = nil
        let runningForwardingOperation = audioForwardingOperation
        audioForwardingOperation = nil
        let runningRetryOperation: RetryOperation?
        if let operation = retryOperation,
            sessionID == nil || operation.sessionID == sessionID
        {
            runningRetryOperation = operation
            retryOperation = nil
        } else {
            runningRetryOperation = nil
        }
        let runningInjectionOperation: InjectionOperation?
        if let operation = injectionOperation,
            sessionID == nil || operation.sessionID == sessionID
        {
            runningInjectionOperation = operation
        } else {
            runningInjectionOperation = nil
        }

        runningPipelineTask?.cancel()
        runningContextTask?.operation.task.cancel()
        runningSetupTask?.cancel()
        runningAudioStartOperation?.task.cancel()
        runningStreamingSetupOperation?.task.cancel()
        runningRetryOperation?.task.cancel()
        runningInjectionOperation?.task.cancel()
        if let runningAudioStartOperation,
            runningCaptureStopOperation == nil
        {
            audioProvider.forceReset(
                owner: audioOwner(runningAudioStartOperation.sessionID))
        }
        _ = await runningCaptureStopOperation?.task.value

        recordingStartedAt = nil
        recovery = nil

        // Cancel the streaming session. Always attempt cancellation even
        // if complete() already cleared isStreamingSession — the pipeline
        // task may still be inside finishStreaming(). cancelStreaming() is
        // a no-op when no session is active.
        isStreamingSession = false
        let streaming = backend.streamingProvider
        streaming.setChunkHandler(nil)
        if let sessionID {
            await streaming.cancelStreaming(sessionID: sessionID)
        } else {
            await streaming.cancelStreaming()
        }

        if let runningForwardingOperation {
            await runningForwardingOperation.cancel(cancelStreaming: {})
        }

        // Drain every task that can still use the provider or local models.
        // Core ML loading does not stop cooperatively, so dropping these task
        // handles would allow a retired generation to publish model state
        // after its replacement starts.
        if let runningAudioStartOperation {
            _ = await runningAudioStartOperation.task.result
            if runningCaptureStopOperation == nil {
                // The retained start may have ignored cancellation and published
                // a live engine after the pre-drain reset.
                let owner = audioOwner(runningAudioStartOperation.sessionID)
                audioProvider.forceReset(owner: owner)
                _ = try? await audioProvider.stopRecording(owner: owner)
            }
        }
        _ = await runningStreamingSetupOperation?.task.result
        await runningSetupTask?.value

        if let runningInjectionOperation {
            _ = await runningInjectionOperation.task.result
            if injectionOperation?.id == runningInjectionOperation.id {
                injectionOperation = nil
            }
        }
        await runningPipelineTask?.value
        if let runningRetryOperation {
            _ = await runningRetryOperation.task.result
            if let sessionID {
                await streaming.cancelStreaming(sessionID: sessionID)
            } else {
                await streaming.cancelStreaming()
            }
        }
        // Context reads are read-only and session-fenced. Joining a hung AX
        // call here would prevent replacement admission forever; its retained
        // handle is reaped asynchronously if it eventually returns.
        await runningCloudRecordingLimitTask?.value

        // Setup can publish a forwarding operation after cancellation if it was
        // inside a non-cancellable engine load. Capture and drain that operation,
        // then cancel the provider once more to remove any late session state.
        let lateForwardingOperation = audioForwardingOperation
        audioForwardingOperation = nil
        if let lateForwardingOperation {
            await lateForwardingOperation.cancel { [streaming] in
                streaming.setChunkHandler(nil)
                if let sessionID {
                    await streaming.cancelStreaming(sessionID: sessionID)
                } else {
                    await streaming.cancelStreaming()
                }
            }
        }

        let lateAudioStartOperation = audioStartOperation
        audioStartOperation = nil
        if let lateAudioStartOperation {
            lateAudioStartOperation.task.cancel()
            let owner = audioOwner(lateAudioStartOperation.sessionID)
            if runningCaptureStopOperation == nil {
                audioProvider.forceReset(owner: owner)
            }
            _ = await lateAudioStartOperation.task.result
            if runningCaptureStopOperation == nil {
                audioProvider.forceReset(owner: owner)
                _ = try? await audioProvider.stopRecording(owner: owner)
            }
        }
        let lateStreamingSetupOperation = streamingSetupOperation
        streamingSetupOperation = nil
        if let lateStreamingSetupOperation {
            lateStreamingSetupOperation.task.cancel()
            if let sessionID {
                await streaming.cancelStreaming(sessionID: sessionID)
            } else {
                await streaming.cancelStreaming()
            }
            _ = await lateStreamingSetupOperation.task.result
        }

        // Setup may have resumed after the first sweep. Clear every session
        // field it can publish before allowing a subsequent activation.
        isStreamingSession = false
        audioSetupFailed = false
        captureBoundaryMissedSessionID = nil
        previewPreRollRecoverySessionID = nil
        recovery = nil
        if sessionID == nil || captureBoundary?.sessionID == sessionID {
            captureBoundary = nil
        }
        if sessionID == nil
            || completionRetainedPCMStream?.sessionID == sessionID
        {
            completionRetainedPCMStream = nil
        }
        if sessionID == nil || captureStopOperation?.sessionID == sessionID {
            captureStopOperation = nil
        }

        if let sessionID {
            let reset = await coordinator.reset(sessionID: sessionID)
            if reset {
                await terminalIdleDidPublish(sessionID)
            }
        }
    }

    /// Seal this pipeline immediately, then mark it terminal and start
    /// cancellation after any capture-maintenance owner has returned.
    ///
    /// Composition uses this fence before beginning model shutdown so an
    /// invisible old recording cannot continue while Qwen cancellation drains.
    public func beginRetirement() async {
        isSealedForReplacement = true
        while captureMaintenanceID != nil {
            await waitForCaptureMaintenanceCompletion()
        }
        guard !isRetired else { return }
        isRetired = true
        let sessionID = activeSession?.id
        if let sessionID {
            _ = claimCaptureStop(sessionID: sessionID)
        }
        activeSession = nil
        activationReservation = nil
        cancellationGeneration &+= 1
        _ = startCancellationDrain(sessionID: sessionID)
    }

    /// Atomically stop new admissions and wait for work already owned by this
    /// generation to finish. Unlike retirement, sealing never cancels capture,
    /// transcription, recovery, or publication.
    public func sealForReplacement() async {
        guard !isRetired else { return }
        isSealedForReplacement = true
        while !isQuiescentForReplacement {
            await withCheckedContinuation { continuation in
                replacementSealWaiters.append(continuation)
            }
        }
    }

    /// Reopen a generation when its replacement cannot be built after the
    /// quiescence fence. This is legal only before retirement and while no
    /// admitted work remains, so callers cannot reopen beneath an old owner.
    @discardableResult
    public func reopenAfterFailedReplacement() -> Bool {
        guard isSealedForReplacement, !isRetired,
            isQuiescentForReplacement
        else { return false }
        isSealedForReplacement = false
        return true
    }

    /// Run a microphone/device transaction only after previously admitted
    /// capture and publication work reaches quiescence. The temporary seal is
    /// visible before waiting, remains held across the operation, and is always
    /// released when the operation returns or throws.
    public func withQuiescentCaptureMaintenance<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        while captureMaintenanceID != nil {
            try await waitForCaptureMaintenanceCompletionUnlessCancelled()
        }
        try Task.checkCancellation()
        guard !isRetired, !isSealedForReplacement else {
            throw DictationPipelineCaptureMaintenanceError.pipelineUnavailable
        }

        let maintenanceID = UUID()
        captureMaintenanceID = maintenanceID
        isSealedForCaptureMaintenance = true

        do {
            while !isQuiescentPipelineWork {
                try await waitForCaptureMaintenanceQuiescence(
                    id: maintenanceID)
            }
            try Task.checkCancellation()
            let result = try await operation()
            finishCaptureMaintenance(id: maintenanceID)
            return result
        } catch {
            finishCaptureMaintenance(id: maintenanceID)
            throw error
        }
    }

    private func waitForCaptureMaintenanceCompletion() async {
        guard captureMaintenanceID != nil else { return }
        await withCheckedContinuation { continuation in
            captureMaintenanceCompletionWaiters.append(continuation)
        }
    }

    private func waitForCaptureMaintenanceCompletionUnlessCancelled()
        async throws
    {
        guard captureMaintenanceID != nil else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                guard captureMaintenanceID != nil else {
                    continuation.resume()
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                cancellableCaptureMaintenanceCompletionWaiters[waiterID] =
                    continuation
            }
        } onCancel: {
            Task {
                await self.cancelCaptureMaintenanceCompletionWaiter(waiterID)
            }
        }
    }

    private func waitForCaptureMaintenanceQuiescence(id: UUID) async throws {
        guard captureMaintenanceID == id, !isQuiescentPipelineWork else {
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                guard captureMaintenanceID == id,
                    !isQuiescentPipelineWork
                else {
                    continuation.resume()
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                cancellableCaptureMaintenanceQuiescenceWaiters[waiterID] =
                    continuation
            }
        } onCancel: {
            Task {
                await self.cancelCaptureMaintenanceQuiescenceWaiter(waiterID)
            }
        }
    }

    private func cancelCaptureMaintenanceCompletionWaiter(_ id: UUID) {
        cancellableCaptureMaintenanceCompletionWaiters.removeValue(forKey: id)?
            .resume(throwing: CancellationError())
    }

    private func cancelCaptureMaintenanceQuiescenceWaiter(_ id: UUID) {
        cancellableCaptureMaintenanceQuiescenceWaiters.removeValue(forKey: id)?
            .resume(throwing: CancellationError())
    }

    private func finishCaptureMaintenance(id: UUID) {
        guard captureMaintenanceID == id else { return }
        captureMaintenanceID = nil
        isSealedForCaptureMaintenance = false

        let waiters = captureMaintenanceCompletionWaiters
        captureMaintenanceCompletionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let cancellableWaiters = Array(
            cancellableCaptureMaintenanceCompletionWaiters.values)
        cancellableCaptureMaintenanceCompletionWaiters.removeAll()
        for waiter in cancellableWaiters { waiter.resume() }
        resumeLifecycleWaitersIfQuiescent()
    }

    private var isQuiescentPipelineWork: Bool {
        activeSession == nil
            && activationReservation == nil
            && activeOperationCount == 0
            && cancellationDrain == nil
            && bufferedPasteReservationID == nil
            && terminalIdleTransitionID == nil
            && completionOwnerCount == 0
    }

    private var isQuiescentForReplacement: Bool {
        isQuiescentPipelineWork && captureMaintenanceID == nil
    }

    private func resumeLifecycleWaitersIfQuiescent() {
        if captureMaintenanceID != nil, isQuiescentPipelineWork {
            let waiters = captureMaintenanceQuiescenceWaiters
            captureMaintenanceQuiescenceWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            let cancellableWaiters = Array(
                cancellableCaptureMaintenanceQuiescenceWaiters.values)
            cancellableCaptureMaintenanceQuiescenceWaiters.removeAll()
            for waiter in cancellableWaiters { waiter.resume() }
        }
        if isSealedForReplacement, isQuiescentForReplacement {
            let waiters = replacementSealWaiters
            replacementSealWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Permanently stop this pipeline before its providers are released.
    public func retire() async {
        await beginRetirement()
        await cancelAndDrain()
        await waitForActiveOperations()
        await cancelAndDrain()
    }

    // MARK: - Local Dictation

    /// Finish a local streaming session.
    ///
    /// Transcribe and polish on-device. No batch fallback — local
    /// providers cannot run concurrent sessions. Return the polished
    /// text, or nil on failure (coordinator already updated).
    private func finishLocalDictation(
        sessionID: DictationSessionID,
        language: String?,
        streaming: StreamingDictationProviding,
        streamingCandidateIsValid: Bool,
        audioBuffer: AudioBuffer,
        context: AppContext,
        coordinator: RecordingCoordinator
    ) async -> String? {
        guard ownsSession(sessionID) else { return nil }
        guard streamingCandidateIsValid else {
            Log.debug("[Pipeline] Local streaming candidate is incomplete")
            retainRecovery(
                sessionID: sessionID,
                audio: audioBuffer.data,
                context: context,
                language: language)
            _ = await coordinator.failDictation(sessionID: sessionID)
            return nil
        }

        Log.debug("[Pipeline] finishing streaming session (local)")
        do {
            let text = try await streaming.finishStreaming(sessionID: sessionID)
            guard ownsSession(sessionID) else { return nil }
            let result = PolishPipeline.stripTrailingFiller(text)
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                Log.debug("[Pipeline] Local returned no text; retaining complete WAV")
                retainRecovery(
                    sessionID: sessionID,
                    audio: audioBuffer.data,
                    context: context,
                    language: language)
                _ = await coordinator.failDictation(sessionID: sessionID)
                return nil
            }
            Log.debug("[Pipeline] local polished: \"\(result)\"")
            saveSampleIfCollecting(
                streaming: streaming, audio: audioBuffer.data,
                polished: result)
            return result
        } catch {
            Log.debug("[Pipeline] Local finishStreaming failed: \(error)")
            await streaming.cancelStreaming(sessionID: sessionID)
            retainRecovery(
                sessionID: sessionID,
                audio: audioBuffer.data,
                context: context,
                language: language)
            guard ownsSession(sessionID) else { return nil }
            _ = await coordinator.failDictation(sessionID: sessionID)
            return nil
        }
    }

    /// Save audio + structured log when `/tmp/freeflow-collect` exists.
    private func saveSampleIfCollecting(
        streaming: StreamingDictationProviding,
        audio: Data, polished: String
    ) {
        let flag = "/tmp/freeflow-collect"
        guard FileManager.default.fileExists(atPath: flag) else { return }

        let dir = "/tmp/freeflow-samples"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        // The returned text is already the full polished transcript; the
        // local provider also exposes it as lastPolishedTranscript next to
        // the raw STT for the collected sample.
        let rawSTT: String
        var polishedFull = polished
        if let local = streaming as? LocalStreamingProvider {
            rawSTT = local.lastRawTranscript
            if !local.lastPolishedTranscript.isEmpty {
                polishedFull = local.lastPolishedTranscript
            }
        } else {
            rawSTT = ""
        }

        // Atomic counter via file count
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".wav") }) ?? []
        let n = files.count + 1
        let tag = String(format: "%03d", n)

        // Save WAV
        let wav = WAVEncoder.encode(
            pcmData: audio, sampleRate: 16000, channels: 1,
            bitsPerSample: 16)
        let wavPath = "\(dir)/sample-\(tag).wav"
        try? wav.write(to: URL(fileURLWithPath: wavPath))

        // Structured log line
        let escaped = { (s: String) -> String in
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
        }
        let json = "{\"n\":\(n)"
            + ",\"stt\":\"\(escaped(rawSTT))\""
            + ",\"polished\":\"\(escaped(polishedFull))\"}"
        Log.debug("[SAMPLE] \(json)")
    }

    // MARK: - Cloud Dictation

    /// Finish a cloud streaming session.
    ///
    /// Finalize one complete streaming candidate, or recover the exact captured
    /// WAV through the batch provider. Return the final text, or nil on failure.
    private func finishCloudDictation(
        sessionID: DictationSessionID,
        language: String?,
        streaming: StreamingDictationProviding,
        streamingCandidateIsValid: Bool,
        audioBuffer: AudioBuffer,
        context: AppContext,
        batchProvider: BatchDictationProviding,
        coordinator: RecordingCoordinator,
        diagnosticStartedAt: CFAbsoluteTime,
        silenceThreshold: Float
    ) async -> ResolvedDictation? {
        guard ownsSession(sessionID) else { return nil }
        var text: String?
        var source = DictationSource.realtime
        if streamingCandidateIsValid {
            Log.debug("[Pipeline] finishing streaming session (cloud)")
            let finishOperation = StreamingFinishOperation {
                try await streaming.finishStreaming(sessionID: sessionID)
            }
            let watchdogSeconds = streaming.finishStreamingWatchdog
            let timeout = watchdogSeconds.isFinite && watchdogSeconds >= 0
                ? watchdogSeconds : 30
            let outcome = await finishOperation.resolve(
                timeout: .seconds(timeout),
                cancelStreaming: {
                    await streaming.cancelStreaming(sessionID: sessionID)
                })
            switch outcome {
            case .completed(let result):
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    text = result
                    Log.debug("[Pipeline] Streaming completed")
                }
            case .failed(let error):
                Log.debug("[Pipeline] Streaming failed: \(error)")
            case .timedOut:
                Log.debug("[Pipeline] Streaming finalization timed out")
            case .cancelled:
                guard !Task.isCancelled else { return nil }
                Log.debug("[Pipeline] Streaming finalization was cancelled")
            }
        } else {
            Log.debug("[Pipeline] Skipping incomplete streaming candidate")
        }

        if text == nil {
            guard !Task.isCancelled, ownsSession(sessionID) else { return nil }
            source = .httpFallback
            Log.debug("[Pipeline] Falling back to batch HTTP")
            text = await batchDictate(
                sessionID: sessionID,
                language: language,
                audioBuffer: audioBuffer,
                context: context,
                batchProvider: batchProvider,
                coordinator: coordinator,
                diagnosticStartedAt: diagnosticStartedAt,
                silenceThreshold: silenceThreshold)
        }

        if text == nil {
            Log.debug("[Pipeline] Both streaming and batch failed")
        }
        guard let text else { return nil }
        return ResolvedDictation(text: text, source: source)
    }

    // MARK: - Result Injection

    private func performInjection(
        text: String,
        context: AppContext,
        sessionID: DictationSessionID,
        textInjector: TextInjecting
    ) async throws {
        guard ownsSession(sessionID) else { throw CancellationError() }

        let id = UUID()
        let task = Task {
            try await textInjector.inject(text: text, into: context)
        }
        injectionOperation = InjectionOperation(
            id: id,
            sessionID: sessionID,
            task: task)
        defer {
            if injectionOperation?.id == id {
                injectionOperation = nil
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performBufferedPasteInjection(
        text: String,
        context: AppContext,
        reservationID: UUID
    ) async throws {
        guard canContinueBufferedPaste(reservationID) else {
            throw CancellationError()
        }

        let id = UUID()
        let injector = textInjector
        let task = Task {
            try await injector.inject(text: text, into: context)
        }
        injectionOperation = InjectionOperation(
            id: id,
            sessionID: nil,
            task: task)
        defer {
            if injectionOperation?.id == id {
                injectionOperation = nil
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Inject polished text at the cursor.
    ///
    /// Handle empty results, store transcript, transition state,
    /// inject via accessibility API, and log timing.
    private func injectResult(
        _ text: String,
        sessionID: DictationSessionID,
        context: AppContext,
        audioBuffer: AudioBuffer,
        coordinator: RecordingCoordinator,
        textInjector: TextInjecting,
        transcriptBuffer: TranscriptBuffer?,
        micDiagnosticStore: MicDiagnosticStore?,
        audioProvider: AudioProviding,
        silenceThreshold: Float,
        t0: CFAbsoluteTime, t1: CFAbsoluteTime, t4: CFAbsoluteTime,
        completeEnteredAt: CFAbsoluteTime,
        mode: String
    ) async {
        guard ownsSession(sessionID) else { return }
        let captureMetrics = audioProvider.metrics(
            owner: audioOwner(sessionID))
        Log.debug("[Pipeline] dictation returned, injecting text: \"\(text)\"")

        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else {
            Log.debug("[Pipeline] Empty dictation result, skipping injection")
            if let store = micDiagnosticStore, let captureMetrics {
                await store.record(
                    MicDiagnosticEntry(
                        deviceName: captureMetrics.deviceName,
                        proximity: captureMetrics.micProximity.rawValue,
                        ambientRMS: captureMetrics.ambientRMS,
                        peakRMS: captureMetrics.peakRMS,
                        gain: captureMetrics.gainFactor,
                        threshold: silenceThreshold,
                        duration: audioBuffer.duration,
                        latency: CFAbsoluteTimeGetCurrent() - t0,
                        result: "empty"
                    ))
            }
            await resetOwnedSession(sessionID)
            return
        }

        guard !Task.isCancelled, ownsSession(sessionID) else { return }

        await transcriptBuffer?.store(finalText, sessionID: sessionID)
        guard ownsSession(sessionID) else { return }

        let injecting = await coordinator.startInjecting(sessionID: sessionID)
        guard injecting else {
            return
        }

        // Yield once after publishing `.injecting` so cancellation observers can
        // run, then fence the last point before irreversible target publication.
        await Task.yield()
        guard !Task.isCancelled, ownsSession(sessionID) else {
            _ = await coordinator.failInjection(sessionID: sessionID)
            return
        }

        do {
            try await performInjection(
                text: finalText,
                context: context,
                sessionID: sessionID,
                textInjector: textInjector)
        } catch {
            guard ownsSession(sessionID) else { return }
            Log.debug("[Pipeline] Text injection failed: \(error)")
            _ = await coordinator.failInjection(sessionID: sessionID)
            return
        }

        guard ownsSession(sessionID) else { return }

        let t5 = CFAbsoluteTimeGetCurrent()
        let fmt = { (dt: Double) -> String in String(format: "%.2fs", dt) }
        let audioKB = String(format: "%.0f", Double(audioBuffer.data.count) / 1024.0)
        Log.debug(
            "[Pipeline] Timing:"
                + " stop=\(fmt(t1 - t0))"
                + " dictate=\(fmt(t4 - t1))"
                + " inject=\(fmt(t5 - t4))"
                + " total=\(fmt(t5 - t0))"
                + " e2e=\(fmt(t5 - completeEnteredAt))"
                + " audio=\(audioKB)KB/\(fmt(audioBuffer.duration))"
                + " mode=\(mode)"
        )

        if let store = micDiagnosticStore, let captureMetrics {
            await store.record(
                MicDiagnosticEntry(
                    deviceName: captureMetrics.deviceName,
                    proximity: captureMetrics.micProximity.rawValue,
                    ambientRMS: captureMetrics.ambientRMS,
                    peakRMS: captureMetrics.peakRMS,
                    gain: captureMetrics.gainFactor,
                    threshold: silenceThreshold,
                    duration: audioBuffer.duration,
                    latency: t5 - t0,
                    result: "ok_\(mode)"
                ))
        }

        let finished = await releaseOwnedSessionToIdle(
            sessionID,
            transition: .finishInjecting)
        guard finished else {
            Log.debug("[Pipeline] Could not publish idle for completed session \(sessionID)")
            return
        }
    }

    // MARK: - Batch Dictation

    /// Send a complete WAV through the batch provider.
    ///
    /// Capture has already passed the session peak gate. Do not classify the
    /// complete WAV again by average RMS: brief speech followed by silence is
    /// still a valid dictation and must reach recovery unchanged.
    private func batchDictate(
        sessionID: DictationSessionID,
        language: String?,
        audioBuffer: AudioBuffer,
        context: AppContext,
        batchProvider: BatchDictationProviding,
        coordinator: RecordingCoordinator,
        diagnosticStartedAt: CFAbsoluteTime,
        silenceThreshold: Float
    ) async -> String? {
        guard !audioBuffer.data.isEmpty else {
            Log.debug("[Pipeline] Empty audio buffer, skipping dictation")
            await resetOwnedSession(sessionID)
            return nil
        }

        guard !Task.isCancelled, ownsSession(sessionID) else { return nil }

        // Send audio + context to the dictation service.
        do {
            let text = try await batchProvider.dictate(
                audio: audioBuffer.data,
                context: context,
                language: language)
            guard ownsSession(sessionID) else { return nil }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Log.debug("[Pipeline] Batch returned no text; retaining complete WAV")
                if let store = micDiagnosticStore,
                    let captureMetrics = audioProvider.metrics(
                        owner: audioOwner(sessionID))
                {
                    await store.record(
                        MicDiagnosticEntry(
                            deviceName: captureMetrics.deviceName,
                            proximity: captureMetrics.micProximity.rawValue,
                            ambientRMS: captureMetrics.ambientRMS,
                            peakRMS: captureMetrics.peakRMS,
                            gain: captureMetrics.gainFactor,
                            threshold: silenceThreshold,
                            duration: audioBuffer.duration,
                            latency: CFAbsoluteTimeGetCurrent() - diagnosticStartedAt,
                            result: "empty"
                        ))
                }
                retainRecovery(
                    sessionID: sessionID,
                    audio: audioBuffer.data,
                    context: context,
                    language: language)
                _ = await coordinator.failDictation(sessionID: sessionID)
                return nil
            }
            return text
        } catch let error as DictationError where error == .authenticationFailed {
            Log.debug("[Pipeline] Dictation returned 401, session expired")
            retainRecovery(
                sessionID: sessionID,
                audio: audioBuffer.data,
                context: context,
                language: language)
            guard ownsSession(sessionID) else { return nil }
            await notifySessionExpired(sessionID: sessionID)
            return nil
        } catch {
            Log.debug("[Pipeline] Dictation failed: \(error)")
            retainRecovery(
                sessionID: sessionID,
                audio: audioBuffer.data,
                context: context,
                language: language)
            guard ownsSession(sessionID) else { return nil }
            _ = await coordinator.failDictation(sessionID: sessionID)
            return nil
        }
    }

    private func retainRecovery(
        sessionID: DictationSessionID,
        audio: Data,
        context: AppContext,
        language: String?
    ) {
        guard ownsSession(sessionID) else { return }
        let owner = audioOwner(sessionID)
        recovery = RecoveryRecord(
            sessionID: sessionID,
            audio: audio,
            context: context,
            language: language,
            micProximity: audioProvider.metrics(owner: owner)?.micProximity
                ?? .nearField,
            silenceThreshold: effectiveSilenceThreshold(
                sessionID: sessionID))
    }

    // MARK: - Session expiry

    /// Transition the coordinator to `.sessionExpired` and invoke the
    /// callback so the app can clear credentials and start recovery.
    private func notifySessionExpired(sessionID: DictationSessionID) async {
        guard !Task.isCancelled, ownsSession(sessionID) else { return }
        let expired = await coordinator.expireSession(sessionID: sessionID)
        guard expired, !Task.isCancelled, ownsSession(sessionID) else { return }
        onSessionExpired?()
    }

    // MARK: - Dictation recovery

    /// Expose retained audio for an explicit Retry after authentication.
    ///
    /// Replacing a key can activate FreeFlow's onboarding window, so automatic
    /// injection would use an untrusted accessibility target. Keep the exact WAV
    /// and wait for the user to restore focus before retrying.
    public func presentRecoveryAfterAuthentication() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard let session = activeSession else { return }
        guard recovery?.sessionID == session.id,
            case .cloud = backend
        else {
            _ = await releaseOwnedSessionToIdle(
                session.id,
                transition: .resetIf(.sessionExpired)
            ) {
                recovery = nil
            }
            return
        }

        _ = await coordinator.prepareDictationRecovery(sessionID: session.id)
    }

    /// Re-attempt transcription of the saved recovery audio.
    ///
    /// Called from the HUD "Retry" button. On success, inject the text
    /// and return to idle. On failure, stay in `.dictationFailed` so
    /// the user can try again or dismiss.
    public func retryDictation() async {
        guard let sessionID = activeSession?.id else { return }
        await retryDictation(sessionID: sessionID)
    }

    /// Whether this failed session retains the exact WAV required for a
    /// truthful retranscription attempt.
    public func canRetryDictation(sessionID: DictationSessionID) -> Bool {
        recovery?.sessionID == sessionID
    }

    /// Observe current accessibility context without making a hung AX read part
    /// of provider/model replacement ownership.
    private func observeFreshContext() async -> AppContext {
        let provider = contextProvider
        let operation = DetachedOperation {
            await provider.readContext()
        }
        let context = await operation.value(timeout: contextObservationTimeout)
        operation.task.cancel()
        return context ?? .empty
    }

    public func retryDictation(sessionID: DictationSessionID) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard let session = activeSession, session.id == sessionID else {
            return
        }
        guard let recovery, recovery.sessionID == session.id else {
            return
        }

        let started = await coordinator.retryDictation(sessionID: session.id)
        guard started else { return }
        guard !isRetired, ownsSession(session.id) else { return }

        let operationID = UUID()
        let retryTask = Task { [self, backend] in
            try Task.checkCancellation()
            switch backend {
            case .local(let streaming):
                return try await retryLocalDictation(
                    recovery,
                    sessionID: session.id,
                    streaming: streaming)
            case .cloud(_, let fallback):
                return try await fallback.dictate(
                    audio: recovery.audio,
                    context: recovery.context,
                    language: recovery.language)
            }
        }
        retryOperation = RetryOperation(
            id: operationID,
            sessionID: session.id,
            task: retryTask)

        do {
            let retryResult = await withTaskCancellationHandler {
                await retryTask.result
            } onCancel: {
                retryTask.cancel()
            }
            if retryOperation?.id == operationID {
                retryOperation = nil
            }
            let text = try retryResult.get()
            try Task.checkCancellation()
            guard !isRetired, ownsSession(session.id) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.debug("[Pipeline] Retry returned no text; keeping recovery audio")
                _ = await coordinator.failDictation(sessionID: session.id)
                return
            }

            await transcriptBuffer?.store(trimmed, sessionID: session.id)
            guard ownsSession(session.id) else { return }
            self.recovery = nil
            guard !isRetired, ownsSession(session.id) else { return }
            let injecting = await coordinator.startInjecting(sessionID: session.id)
            guard injecting else {
                return
            }

            let freshContext = await observeFreshContext()
            guard !isRetired, ownsSession(session.id) else { return }
            do {
                try await performInjection(
                    text: trimmed,
                    context: freshContext,
                    sessionID: session.id,
                    textInjector: textInjector)
                guard ownsSession(session.id) else { return }
                _ = await releaseOwnedSessionToIdle(
                    session.id,
                    transition: .finishInjecting)
            } catch {
                guard ownsSession(session.id) else { return }
                Log.debug("[Pipeline] Recovery injection failed: \(error)")
                _ = await coordinator.failInjection(sessionID: session.id)
            }
        } catch let error as DictationError where error == .authenticationFailed {
            if retryOperation?.id == operationID {
                retryOperation = nil
            }
            guard ownsSession(session.id) else { return }
            Log.debug("[Pipeline] Retry returned 401, session expired")
            await notifySessionExpired(sessionID: session.id)
        } catch {
            if retryOperation?.id == operationID {
                retryOperation = nil
            }
            guard ownsSession(session.id) else { return }
            Log.debug("[Pipeline] Retry dictation failed: \(error)")
            _ = await coordinator.failDictation(sessionID: session.id)
        }
    }

    private func retryLocalDictation(
        _ recovery: RecoveryRecord,
        sessionID: DictationSessionID,
        streaming: any LocalAudioReplayProviding
    ) async throws -> String {
        guard let pcm = Self.standardWAVPayload(recovery.audio) else {
            throw DictationError.emptyAudio
        }

        streaming.setChunkHandler(nil)

        do {
            try Task.checkCancellation()
            let text = try await streaming.replayCapturedAudio(
                pcm,
                sessionID: sessionID,
                context: recovery.context,
                language: recovery.language,
                micProximity: recovery.micProximity,
                silenceThreshold: recovery.silenceThreshold)
            guard !Task.isCancelled, !isRetired, ownsSession(sessionID) else {
                throw CancellationError()
            }
            return PolishPipeline.stripTrailingFiller(text)
        } catch {
            await streaming.cancelStreaming(sessionID: sessionID)
            throw error
        }
    }

    /// Captured recovery audio is produced by `WAVEncoder`, whose PCM payload
    /// starts after one standard 44-byte header.
    private static func standardWAVPayload(_ wav: Data) -> Data? {
        guard wav.count > WAVEncoder.headerSize,
            wav.prefix(4) == Data("RIFF".utf8),
            wav.dropFirst(8).prefix(4) == Data("WAVE".utf8)
        else { return nil }
        return Data(wav.dropFirst(WAVEncoder.headerSize))
    }

    /// Publish the currently buffered transcript through pipeline ownership.
    ///
    /// A failed dictation publication retains its session identity and uses the
    /// coordinator's atomic retry transition. An ordinary idle paste reserves
    /// admission before its first suspension so capture cannot start across the
    /// shared transcript lease or target mutation.
    public func pasteBufferedTranscript() async {
        guard beginOperation() else { return }
        defer { endOperation() }

        if terminalIdleTransitionID == nil,
            let sessionID = activeSession?.id
        {
            await retryBufferedInjection(sessionID: sessionID)
            return
        }

        guard !isCaptureAdmissionSealed else { return }

        guard activationReservation == nil,
            bufferedPasteReservationID == nil,
            let transcriptBuffer
        else { return }

        let reservationID = UUID()
        bufferedPasteReservationID = reservationID
        defer { finishBufferedPaste(id: reservationID) }

        await waitForCancellationDrain()
        guard canRetainBufferedPasteReservation(reservationID) else { return }
        await waitForTerminalIdleTransition()
        guard canRetainBufferedPasteReservation(reservationID) else { return }
        if let sessionID = activeSession?.id {
            await retryBufferedInjection(sessionID: sessionID)
            return
        }
        guard canContinueBufferedPaste(reservationID) else { return }
        await waitForCompletionOwners()
        guard canContinueBufferedPaste(reservationID) else { return }

        let currentState = await coordinator.state
        guard currentState == .idle,
            canContinueBufferedPaste(reservationID)
        else { return }

        guard let consumption = await transcriptBuffer.consumeForInjection()
        else { return }

        let context = await observeFreshContext()
        guard canContinueBufferedPaste(reservationID) else {
            await transcriptBuffer.restoreAfterFailedInjection(consumption)
            return
        }

        do {
            try await performBufferedPasteInjection(
                text: consumption.transcript,
                context: context,
                reservationID: reservationID)
        } catch {
            await transcriptBuffer.restoreAfterFailedInjection(consumption)
            Log.debug("[Pipeline] Buffered paste failed: \(error)")
        }
    }

    /// Retry a failed target publication through the session-owned injection
    /// boundary. This atomically excludes dictation Retry and preserves the
    /// transcript when a newer buffer value has already replaced it.
    public func retryBufferedInjection(
        sessionID: DictationSessionID
    ) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard ownsSession(sessionID), let transcriptBuffer else { return }
        let claimed = await coordinator.retryInjection(sessionID: sessionID)
        guard claimed, ownsSession(sessionID) else { return }

        guard
            let consumption = await transcriptBuffer.consumeForInjection(
                sessionID: sessionID)
        else {
            _ = await coordinator.failInjection(sessionID: sessionID)
            return
        }

        let context = await observeFreshContext()
        guard !isRetired, ownsSession(sessionID) else {
            await transcriptBuffer.restoreAfterFailedInjection(consumption)
            return
        }

        do {
            try await performInjection(
                text: consumption.transcript,
                context: context,
                sessionID: sessionID,
                textInjector: textInjector)
            guard ownsSession(sessionID) else { return }
            _ = await releaseOwnedSessionToIdle(
                sessionID,
                transition: .finishInjecting)
        } catch {
            await transcriptBuffer.restoreAfterFailedInjection(consumption)
            guard ownsSession(sessionID) else { return }
            Log.debug("[Pipeline] Buffered injection retry failed: \(error)")
            _ = await coordinator.failInjection(sessionID: sessionID)
        }
    }

    /// Dismiss a failed target publication only if it still belongs to the UI
    /// action's captured session.
    public func dismissInjectionFailure(sessionID: DictationSessionID) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        _ = await releaseOwnedSessionToIdle(
            sessionID,
            transition: .resetIf(.injectionFailed))
    }

    /// Discard the saved recovery audio and return to idle.
    ///
    /// Called from the HUD "Dismiss" button or Escape key.
    public func dismissDictationFailure() async {
        guard let sessionID = activeSession?.id else { return }
        await dismissDictationFailure(sessionID: sessionID)
    }

    public func dismissDictationFailure(
        sessionID: DictationSessionID
    ) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        _ = await releaseOwnedSessionToIdle(
            sessionID,
            transition: .resetIf(.dictationFailed)
        ) {
            recovery = nil
        }
    }
}
