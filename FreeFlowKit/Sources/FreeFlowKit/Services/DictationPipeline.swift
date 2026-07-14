import Foundation

/// Orchestrate the full dictation flow from hotkey press to text injection.
///
/// `DictationPipeline` implements `PipelineProviding` by coordinating an
/// `AudioProviding`, `AppContextProviding`, `BatchDictationProviding`, and
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

    private let audioProvider: AudioProviding
    private let contextProvider: AppContextProviding
    private let batchProvider: BatchDictationProviding?
    private let streamingProvider: StreamingDictationProviding?
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

    /// Context captured concurrently during the recording phase.
    private var pendingContext: Task<AppContext, Never>?

    /// The in-flight pipeline task, used for cancellation.
    private var pipelineTask: Task<Void, Never>?

    /// Owns PCM forwarding until natural drain or explicit teardown.
    private var audioForwardingOperation: AudioForwardingOperation?

    /// Task that performs audio setup after activate() returns.
    /// complete() awaits this to ensure audio is ready before stopping.
    private var audioSetupTask: Task<Void, Never>?

    private struct CancellationDrain {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Shared barrier for overlapping cancel and retirement requests.
    private var cancellationDrain: CancellationDrain?

    /// Invalidate completion operations that suspended before cancellation.
    private var cancellationGeneration: UInt64 = 0

    /// Completion owners may still mutate session state after cancellation.
    private var completionOwnerCount = 0
    private var completionOwnerWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether the current recording session is using streaming mode.
    private var isStreamingSession: Bool = false

    /// Set by performAudioSetup when startRecording fails. Checked by
    /// complete() to skip dictation and reset immediately.
    private var audioSetupFailed: Bool = false

    /// Audio saved for recovery when dictation fails. Held until the
    /// user retries or dismisses via the HUD.
    private var recoveryAudio: Data?
    private var recoveryContext: AppContext?

    /// When the current recording started (set in `activate`, cleared
    /// at the end of `complete`). Used to compute a duration-scaled
    /// hard deadline for the pipeline task so long dictations do not
    /// hit the force-reset ceiling mid-way through transcription.
    private var recordingStartedAt: Date?

    /// ISO-639-1 language hint for transcription (e.g. "en", "fr", "ja").
    /// Set from the menu bar language picker or auto-detected from macOS
    /// locale. When nil, the server defaults to auto-detection.
    private(set) var language: String?

    /// When true, finish the on-device streaming provider directly
    /// instead of attempting the cloud batch fallback.
    private let localMode: Bool

    /// Cloud recordings finalize at this wall-clock limit so the complete WAV
    /// remains inside the supported batch-recovery envelope.
    private let cloudRecordingLimit: Duration
    private let cloudRecordingLimitSleep: @Sendable (Duration) async -> Void
    private let cloudRecordingLimitDidClaim: @Sendable () async -> Void
    private let completionWillHandoff: @Sendable () async -> Void
    private let activationDidBeginWaitingForCompletion: @Sendable () -> Void
    private var cloudRecordingLimitID: UUID?
    private var cloudRecordingLimitClaimedID: UUID?
    private var cloudRecordingLimitTask: Task<Void, Never>?

    /// A retired pipeline cannot accept work after composition replacement.
    private var isRetired = false

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
        batchProvider: BatchDictationProviding? = nil,
        textInjector: TextInjecting,
        coordinator: RecordingCoordinator,
        transcriptBuffer: TranscriptBuffer? = nil,
        silenceThreshold: Float = 0.005,
        streamingProvider: StreamingDictationProviding? = nil,
        onSessionExpired: (@Sendable () -> Void)? = nil,
        micDiagnosticStore: MicDiagnosticStore? = nil,
        localMode: Bool = false
    ) {
        self.init(
            audioProvider: audioProvider,
            contextProvider: contextProvider,
            batchProvider: batchProvider,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            silenceThreshold: silenceThreshold,
            streamingProvider: streamingProvider,
            onSessionExpired: onSessionExpired,
            micDiagnosticStore: micDiagnosticStore,
            localMode: localMode,
            cloudRecordingLimit: .seconds(300),
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            cloudRecordingLimitDidClaim: {})
    }

    init(
        audioProvider: AudioProviding,
        contextProvider: AppContextProviding,
        batchProvider: BatchDictationProviding? = nil,
        textInjector: TextInjecting,
        coordinator: RecordingCoordinator,
        transcriptBuffer: TranscriptBuffer? = nil,
        silenceThreshold: Float = 0.005,
        streamingProvider: StreamingDictationProviding? = nil,
        onSessionExpired: (@Sendable () -> Void)? = nil,
        micDiagnosticStore: MicDiagnosticStore? = nil,
        localMode: Bool = false,
        cloudRecordingLimit: Duration = .seconds(300),
        cloudRecordingLimitSleep: @escaping @Sendable (Duration) async -> Void,
        cloudRecordingLimitDidClaim: @escaping @Sendable () async -> Void = {},
        completionWillHandoff: @escaping @Sendable () async -> Void = {},
        activationDidBeginWaitingForCompletion: @escaping @Sendable () -> Void = {}
    ) {
        self.audioProvider = audioProvider
        self.contextProvider = contextProvider
        self.batchProvider = batchProvider
        self.textInjector = textInjector
        self.coordinator = coordinator
        self.transcriptBuffer = transcriptBuffer
        self.silenceThreshold = silenceThreshold
        self.streamingProvider = streamingProvider
        self.onSessionExpired = onSessionExpired
        self.localMode = localMode
        self.micDiagnosticStore = micDiagnosticStore
        self.cloudRecordingLimit = cloudRecordingLimit
        self.cloudRecordingLimitSleep = cloudRecordingLimitSleep
        self.cloudRecordingLimitDidClaim = cloudRecordingLimitDidClaim
        self.completionWillHandoff = completionWillHandoff
        self.activationDidBeginWaitingForCompletion =
            activationDidBeginWaitingForCompletion
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
    private func effectiveSilenceThreshold() -> Float {
        // Built-in mic: skip adaptive threshold entirely.
        if audioProvider.micProximity == .farField {
            return farFieldSilenceThreshold
        }
        // Near-field mic: use adaptive threshold when ambient is known.
        // Clamp between floor and ceiling so variable ambient (e.g.
        // AirPods noise cancellation adjusting) cannot push the
        // threshold above whisper-range speech.
        let ambient = audioProvider.ambientRMS
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
        guard activeOperationCount == 0 else { return }
        let waiters = activeOperationWaiters
        activeOperationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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

    private func armCloudRecordingLimit() {
        guard !localMode else { return }

        cancelPendingCloudRecordingLimit()
        guard cloudRecordingLimitClaimedID == nil else { return }
        let id = UUID()
        let limit = cloudRecordingLimit
        let sleep = cloudRecordingLimitSleep
        cloudRecordingLimitID = id
        cloudRecordingLimitTask = Task { [weak self] in
            await sleep(limit)
            guard !Task.isCancelled else { return }
            await self?.completeCloudRecordingAtLimit(id: id)
        }
    }

    /// Cancel a timer that has not started automatic completion. A physical key
    /// release can race the limit callback after it has claimed the recording;
    /// in that case the claimed task must remain alive to publish the result.
    private func cancelPendingCloudRecordingLimit() {
        guard cloudRecordingLimitID != nil else { return }
        cloudRecordingLimitID = nil
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
        cloudRecordingLimitTask?.cancel()
        cloudRecordingLimitTask = nil
        return claimedTask
    }

    private func completeCloudRecordingAtLimit(id: UUID) async {
        guard cloudRecordingLimitID == id else { return }
        cloudRecordingLimitID = nil
        cloudRecordingLimitClaimedID = id
        defer {
            if cloudRecordingLimitClaimedID == id {
                cloudRecordingLimitClaimedID = nil
                cloudRecordingLimitTask = nil
            }
        }
        await cloudRecordingLimitDidClaim()
        guard !Task.isCancelled else { return }
        Log.debug("[Pipeline] Cloud recording limit reached; completing full capture")
        await complete()
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

    public func activate() async {
        guard beginOperation() else {
            Log.debug("[Pipeline] activate() ignored - pipeline is retired")
            return
        }
        defer { endOperation() }
        // A completion owner can keep mutating session state after cancellation
        // resets the coordinator. Do not let a replacement recording overlap it.
        await waitForClaimedCloudRecordingLimit()
        await waitForCompletionOwners()
        let t0 = CFAbsoluteTimeGetCurrent()
        let currentState = await coordinator.state
        guard !isRetired, currentState == .idle else {
            Log.debug("[Pipeline] activate() ignored — state is \(currentState)")
            return
        }

        let t1 = CFAbsoluteTimeGetCurrent()
        let started = await coordinator.startRecording()
        guard started else { return }
        guard !isRetired else {
            await coordinator.reset()
            return
        }
        let t2 = CFAbsoluteTimeGetCurrent()
        Log.debug(
            "[Pipeline] activate() state check: \(String(format: "%.3f", t1 - t0))s, startRecording: \(String(format: "%.3f", t2 - t1))s"
        )

        recordingStartedAt = Date()
        audioSetupFailed = false
        armCloudRecordingLimit()

        // State is now .recording — return immediately so the HUD can animate.
        // Audio setup runs in a detached task so it does not execute on the
        // pipeline actor's executor. A plain Task inherits the actor context
        // and can block the actor until the first suspension point, which
        // delays the return from activate() by the full AVAudioEngine start
        // time (0.5-0.9s). Detached tasks run independently, letting
        // activate() return instantly and the HUD expand without delay.
        let pipeline = self
        audioSetupTask = Task.detached {
            await pipeline.performAudioSetup(activationTime: t0)
        }
    }

    /// Perform audio capture setup and streaming initialization.
    /// This runs after `activate()` returns, so the HUD can animate immediately.
    private func performAudioSetup(activationTime t0: CFAbsoluteTime) async {
        // Bail early if cancelled before we even begin (e.g. rapid cancel
        // after activate). Without this check the detached task can start
        // recording after cancel() has already finished its cleanup.
        guard !Task.isCancelled else {
            Log.debug("[Pipeline] performAudioSetup() cancelled before start")
            return
        }

        // Start reading context concurrently. The result is awaited in complete().
        let ctxProvider = contextProvider
        pendingContext = Task {
            await ctxProvider.readContext()
        }

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
        enum StartRecordingTimeout: Error { case timedOut }
        // Race startRecording() against a 3s timeout for BT SCO negotiation.
        let startResult: Result<Void, Error>
        let completed: Result<Void, Error>? = await detachedWithTimeout(seconds: 3.0) {
            do {
                try await audioProviderRef.startRecording()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        if let completed {
            startResult = completed
        } else {
            Log.debug(
                "[Pipeline] startRecording() timed out (3s), likely BT negotiation hang"
            )
            startResult = .failure(StartRecordingTimeout.timedOut)
        }

        switch startResult {
        case .success:
            break
        case .failure(let error):
            Log.debug("[Pipeline] Failed to start recording: \(error)")
            // If startRecording() timed out, engine.start() may be
            // blocking inside the lock. Force-reset stops the engine
            // without the lock to unblock the hung call, then marks
            // for rebuild so the next session gets a fresh engine.
            audioProvider.forceReset()
            _ = try? await audioProvider.stopRecording()
            pendingContext?.cancel()
            pendingContext = nil
            audioSetupFailed = true
            return
        }

        // Check cancellation after starting audio. cancel() may have fired
        // while startRecording() was in progress. Without this, the audio
        // provider stays in the recording state with no one to stop it,
        // causing testCancelFromRecordingResetsToIdle to flake.
        if Task.isCancelled {
            Log.debug("[Pipeline] performAudioSetup() cancelled after startRecording")
            _ = try? await audioProvider.stopRecording()
            pendingContext?.cancel()
            pendingContext = nil
            return
        }
        let t4 = CFAbsoluteTimeGetCurrent()
        Log.debug(
            "[Pipeline] performAudioSetup() audioProvider.startRecording: \(String(format: "%.3f", t4 - t3))s"
        )

        // If a streaming provider is available and the audio provider
        // supports PCM streaming, open the streaming session and start
        // forwarding audio chunks in the background.
        if let streaming = streamingProvider, let pcmStream = audioProvider.pcmAudioStream {
            isStreamingSession = true

            // Await context early for the streaming start message. Use
            // a short timeout so we do not delay the session opening.
            let context: AppContext
            if let pending = pendingContext {
                let result = await withTimeout(seconds: 0.5) {
                    await pending.value
                }
                context = result ?? .empty
            } else {
                context = .empty
            }

            guard !Task.isCancelled else {
                isStreamingSession = false
                _ = try? await audioProvider.stopRecording()
                return
            }

            let t5 = CFAbsoluteTimeGetCurrent()
            let micProximity = audioProvider.micProximity
            let language = self.language

            // Neither mode injects mid-stream. Local assembles one final
            // transcript from bounded units; cloud stays atomic because
            // arbitrary target applications cannot safely revise text after
            // injection. The pipeline injects each provider's result once.
            streaming.setChunkHandler(nil)

            // Local pause detection uses the same ambient-adaptive threshold as
            // the silent-press gate, so real acoustic pauses close units rather
            // than only the size cap.
            if localMode {
                (streaming as? LocalStreamingProvider)?
                    .setSilenceThreshold(effectiveSilenceThreshold())
            }

            // Timeout the streaming setup to avoid blocking complete()
            // indefinitely. ensureConnected()/sendPing can hang when the
            // WebSocket is in a broken state. On timeout we cancel the
            // streaming session and fall back to batch mode.
            //
            // Uses a single detached task with an internal task-group
            // timeout. This avoids zombie detached tasks that pile up
            // when the timeout fires but startStreaming() keeps retrying
            // ensureConnected() in the background.
            Log.debug(
                "[Pipeline] Starting streaming setup with 5s timeout (language=\(language ?? "nil"))"
            )
            let streamingStarted: Bool = await Task.detached {
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        do {
                            Log.debug("[Pipeline] streaming.startStreaming() entering")
                            try await streaming.startStreaming(
                                context: context, language: language,
                                micProximity: micProximity)
                            Log.debug("[Pipeline] streaming.startStreaming() returned OK")
                            return true
                        } catch {
                            Log.debug("[Pipeline] streaming.startStreaming() failed: \(error)")
                            return false
                        }
                    }
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: 5_000_000_000)  // 5s
                        } catch {
                            // Cancelled because startStreaming already
                            // resolved. The cancelAll() below will make
                            // this branch lose the race anyway; return
                            // false so the group.next() contract holds.
                            return false
                        }
                        Log.debug("[Pipeline] Streaming setup timeout fired after 5s")
                        return false
                    }
                    let first = await group.next() ?? false
                    // Cancel the losing task. If the timeout won, this
                    // cancels startStreaming() so it won't keep retrying
                    // ensureConnected() as a zombie. If startStreaming()
                    // won, this just cancels the sleeping timeout task.
                    group.cancelAll()
                    return first
                }
            }.value

            guard !Task.isCancelled else {
                streaming.setChunkHandler(nil)
                await streaming.cancelStreaming()
                isStreamingSession = false
                if audioProvider.isRecording {
                    _ = try? await audioProvider.stopRecording()
                }
                return
            }

            // If streaming timed out, also cancel the session on the
            // provider so it tears down the broken connection cleanly
            // rather than leaving stale state for the next session.
            if !streamingStarted {
                await streaming.cancelStreaming()
            }

            guard streamingStarted else {
                Log.debug("[Pipeline] Streaming setup timed out or failed, falling back to batch")
                streaming.setChunkHandler(nil)
                isStreamingSession = false
                return
            }
            let t6 = CFAbsoluteTimeGetCurrent()
            Log.debug(
                "[Pipeline] performAudioSetup() streaming.startStreaming: \(String(format: "%.3f", t6 - t5))s, total: \(String(format: "%.3f", t6 - t0))s"
            )

            audioForwardingOperation = AudioForwardingOperation(
                stream: pcmStream,
                send: { chunk in try await streaming.sendAudio(chunk) })
        } else {
            isStreamingSession = false
        }
    }

    public func complete() async {
        guard beginOperation() else {
            Log.debug("[Pipeline] complete() ignored - pipeline is retired")
            return
        }
        beginCompletionOwnership()
        defer {
            endCompletionOwnership()
            endOperation()
        }
        let completionGeneration = cancellationGeneration
        cancelPendingCloudRecordingLimit()
        if await abortCompletionIfCancelledOrRetired(
            completionGeneration: completionGeneration
        ) {
            return
        }
        let completeEnteredAt = CFAbsoluteTimeGetCurrent()
        Log.debug("[Pipeline] complete() entering")
        let currentState = await coordinator.state
        if await abortCompletionIfCancelledOrRetired(
            completionGeneration: completionGeneration
        ) {
            return
        }
        guard currentState == .recording else {
            Log.debug("[Pipeline] complete() ignored — state is \(currentState)")
            return
        }

        Log.debug("[Pipeline] complete() transitioning to processing")
        let stopped = await coordinator.stopRecording()
        if await abortCompletionIfCancelledOrRetired(
            completionGeneration: completionGeneration
        ) {
            return
        }
        guard stopped else { return }

        // If audio setup is still in progress, give it a short window
        // to finish (covers the normal 500-900ms AVAudioEngine start).
        // If it doesn't complete in time, cancel it and fall back to
        // batch mode — we already have the audio buffer from the
        // capture that did start.
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
        let earlyThreshold = effectiveSilenceThreshold()
        // A peakRMS of exactly 0 means no audio was captured yet (the
        // tap hasn't fired). Skip the early silence gate in this case
        // so rapid hotkey taps don't silently discard speech.
        if audioProvider.peakRMS > 0, audioProvider.peakRMS <= earlyThreshold {
            if let setupTask = audioSetupTask {
                setupTask.cancel()
                audioSetupTask = nil
            }
            isStreamingSession = false
            let forwardingOperation = audioForwardingOperation
            audioForwardingOperation = nil
            if let forwardingOperation {
                await forwardingOperation.cancel { [streamingProvider] in
                    await streamingProvider?.cancelStreaming()
                }
            } else if let streaming = streamingProvider {
                await streaming.cancelStreaming()
            }

            Log.debug(
                "[Pipeline] Early silence short-circuit: peak RMS \(audioProvider.peakRMS) <= \(earlyThreshold) (ambient: \(audioProvider.ambientRMS)), skipping setup wait"
            )

            if let store = micDiagnosticStore {
                await store.record(
                    MicDiagnosticEntry(
                        deviceName: audioProvider.deviceName,
                        proximity: audioProvider.micProximity.rawValue,
                        ambientRMS: audioProvider.ambientRMS,
                        peakRMS: audioProvider.peakRMS,
                        gain: audioProvider.gainFactor,
                        threshold: earlyThreshold,
                        duration: 0,
                        latency: 0,
                        result: "silent"
                    ))
            }

            // Stop audio and reset immediately.
            _ = try? await audioProvider.stopRecording()
            await coordinator.reset()
            return
        }

        if let setupTask = audioSetupTask {
            let setupDone: Bool = await withCheckedContinuation { continuation in
                let lock = NSLock()
                var resumed = false

                // Monitor task: polls for completion by trying to get
                // the value from a detached context (no actor dependency).
                Task.detached { [weak self] in
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

                // Timeout task: poll for silence or hard 6s ceiling.
                // When the audio is clearly silent, bail after a short
                // window (200ms) instead of waiting the full 6s for a
                // stale WebSocket ping to time out. peakRMS is updated
                // by the tap callback on the audio render thread so it
                // is safe to read from a detached task via the lock in
                // AudioCaptureProvider.
                Task.detached { [audioProvider, earlyThreshold] in
                    let deadline = Date().addingTimeInterval(6.0)
                    var silentTicks = 0
                    while Date() < deadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        let alreadyDone = lock.withLock { resumed }
                        if alreadyDone { return }

                        if audioProvider.peakRMS > 0,
                            audioProvider.peakRMS <= earlyThreshold
                        {
                            silentTicks += 1
                            // 4 ticks × 50ms = 200ms of confirmed silence
                            if silentTicks >= 4 {
                                Log.debug(
                                    "[Pipeline] Setup wait bailing early: silent audio (peak RMS \(audioProvider.peakRMS), threshold \(earlyThreshold))"
                                )
                                break
                            }
                        } else {
                            silentTicks = 0
                        }
                    }
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
            }

            if setupDone {
                Log.debug("[Pipeline] complete() audio setup finished normally")
            } else {
                Log.debug("[Pipeline] complete() audio setup timed out, cancelling")
                // Give the streaming provider a clean teardown so it
                // doesn't leave broken connection state.
                if let streaming = streamingProvider {
                    await streaming.cancelStreaming()
                }
                isStreamingSession = false
            }
            audioSetupTask = nil
        }

        await completionWillHandoff()
        if await abortCompletionIfCancelledOrRetired(
            completionGeneration: completionGeneration
        ) {
            return
        }

        // If audio setup failed (e.g. BT negotiation timeout), there
        // is no audio to transcribe. Reset and return immediately.
        if audioSetupFailed {
            Log.debug("[Pipeline] Audio setup failed, skipping dictation")
            audioSetupFailed = false
            isStreamingSession = false
            _ = try? await audioProvider.stopRecording()
            await coordinator.reset()
            return
        }

        let useStreaming = isStreamingSession
        let forwardingOperation = audioForwardingOperation
        audioForwardingOperation = nil
        isStreamingSession = false

        // Clear the chunk handler before entering the pipeline task so
        // late-arriving chunks cannot inject text during finishStreaming.
        if useStreaming {
            streamingProvider?.setChunkHandler(nil)
        }

        let (pipelineCompletion, pipelineCompletionContinuation) =
            AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            [
                pendingContext, audioProvider, batchProvider, streamingProvider,
                textInjector, coordinator, transcriptBuffer,
                micDiagnosticStore,
                completeEnteredAt
            ] in
            var cancellationRecovery: (audio: Data, context: AppContext)?
            defer {
                if Task.isCancelled, !localMode, let cancellationRecovery {
                    retainRecovery(
                        audio: cancellationRecovery.audio,
                        context: cancellationRecovery.context)
                }
                pipelineCompletionContinuation.yield(())
                pipelineCompletionContinuation.finish()
            }
            let t0 = CFAbsoluteTimeGetCurrent()

            // Stop audio capture and retrieve the buffer.
            Log.debug("[Pipeline] stopping audio capture")
            let audioBuffer: AudioBuffer
            do {
                audioBuffer = try await audioProvider.stopRecording()
            } catch {
                Log.debug("[Pipeline] Failed to stop recording: \(error)")
                if let forwardingOperation {
                    await forwardingOperation.cancel {
                        await streamingProvider?.cancelStreaming()
                    }
                } else if useStreaming {
                    await streamingProvider?.cancelStreaming()
                }
                await coordinator.reset()
                return
            }

            let t1 = CFAbsoluteTimeGetCurrent()
            Log.debug(
                "[Pipeline] audio stopped (\(String(format: "%.2f", audioBuffer.duration))s, \(audioBuffer.data.count)B)"
            )

            // Early silence check: use the peak RMS tracked during
            // recording to reject silent presses immediately, before
            // waiting on the streaming forwarding operation or any network
            // calls. This avoids the 5-7s delay users see when they
            // tap the hotkey without speaking.
            // Recompute the threshold now that ambient calibration may
            // have finished during recording. Use effectiveSilenceThreshold()
            // which respects far-field mic proximity (built-in mics use
            // a low fixed threshold instead of the adaptive calculation).
            let postRecordThreshold = effectiveSilenceThreshold()

            let peakLevel = audioProvider.peakRMS
            if peakLevel <= postRecordThreshold {
                Log.debug(
                    "[Pipeline] Early silence gate: peak RMS \(peakLevel) <= \(postRecordThreshold) (ambient: \(audioProvider.ambientRMS)), skipping"
                )
                if let store = micDiagnosticStore {
                    await store.record(
                        MicDiagnosticEntry(
                            deviceName: audioProvider.deviceName,
                            proximity: audioProvider.micProximity.rawValue,
                            ambientRMS: audioProvider.ambientRMS,
                            peakRMS: audioProvider.peakRMS,
                            gain: audioProvider.gainFactor,
                            threshold: postRecordThreshold,
                            duration: audioBuffer.duration,
                            latency: 0,
                            result: "silent"
                        ))
                }
                if let forwardingOperation {
                    await forwardingOperation.cancel {
                        await streamingProvider?.cancelStreaming()
                    }
                } else if useStreaming {
                    await streamingProvider?.cancelStreaming()
                }
                await coordinator.reset()
                return
            }

            if !localMode, !audioBuffer.data.isEmpty {
                cancellationRecovery = (audioBuffer.data, .empty)
            }

            var streamingCandidateIsValid = false
            if useStreaming {
                if let streaming = streamingProvider, let forwardingOperation {
                    let forwardingOutcome = await forwardingOperation.drain(
                        timeout: .seconds(2),
                        cancelStreaming: { await streaming.cancelStreaming() })
                    streamingCandidateIsValid = forwardingOutcome == .drained
                    if !streamingCandidateIsValid {
                        Log.debug(
                            "[Pipeline] audio forwarding invalidated streaming: "
                                + "\(forwardingOutcome)")
                    }
                } else {
                    if let forwardingOperation {
                        await forwardingOperation.cancel {
                            await streamingProvider?.cancelStreaming()
                        }
                    } else {
                        await streamingProvider?.cancelStreaming()
                    }
                    Log.debug("[Pipeline] streaming session has no forwarding owner")
                }
            } else if let forwardingOperation {
                await forwardingOperation.cancel {
                    await streamingProvider?.cancelStreaming()
                }
            }

            guard !Task.isCancelled else { return }

            // Resolve context once. The pendingContext task caches its
            // result, so awaiting it again (streaming already awaited it
            // in activate) returns the same value instantly.
            let context: AppContext
            if let pendingContext {
                let result = await withTimeout(seconds: 0.5) {
                    await pendingContext.value
                }
                context = result ?? .empty
            } else {
                context = .empty
            }
            if cancellationRecovery != nil {
                cancellationRecovery = (audioBuffer.data, context)
            }

            // Resolve the transcript from the appropriate provider.
            let dictatedText: String?
            if useStreaming, let streaming = streamingProvider {
                if localMode {
                    dictatedText = await finishLocalDictation(
                        streaming: streaming,
                        streamingCandidateIsValid: streamingCandidateIsValid,
                        audioBuffer: audioBuffer,
                        context: context,
                        coordinator: coordinator)
                } else if let batchProvider {
                    dictatedText = await finishCloudDictation(
                        streaming: streaming,
                        streamingCandidateIsValid: streamingCandidateIsValid,
                        audioBuffer: audioBuffer,
                        context: context,
                        batchProvider: batchProvider,
                        coordinator: coordinator,
                        diagnosticStartedAt: t0,
                        silenceThreshold: postRecordThreshold)
                } else {
                    Log.debug("[Pipeline] No batch provider, cannot finish cloud dictation")
                    await coordinator.reset()
                    dictatedText = nil
                }
            } else if let batchProvider {
                Log.debug("[Pipeline] batch mode, sending to dictation service")
                dictatedText = await batchDictate(
                    audioBuffer: audioBuffer,
                    context: context,
                    batchProvider: batchProvider,
                    coordinator: coordinator,
                    diagnosticStartedAt: t0,
                    silenceThreshold: postRecordThreshold)
            } else {
                Log.debug("[Pipeline] No dictation provider available")
                await coordinator.reset()
                dictatedText = nil
            }

            guard let dictatedText else { return }

            let t4 = CFAbsoluteTimeGetCurrent()

            // Inject the result.
            await injectResult(
                dictatedText,
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
                mode: useStreaming ? "streaming" : "batch")
        }

        self.pipelineTask = task
        self.pendingContext = nil

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
        let requiresCloudBatchWindow = !localMode && batchProvider != nil
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
            if let streaming = streamingProvider {
                await streaming.cancelStreaming()
            }
            await task.value
            let stateAfterCancellation = await coordinator.state
            switch stateAfterCancellation {
            case .processing:
                if recoveryAudio != nil {
                    _ = await coordinator.failDictation()
                } else {
                    await coordinator.reset()
                }
            case .injecting:
                recoveryAudio = nil
                recoveryContext = nil
                _ = await coordinator.failInjection()
            case .idle, .injectionFailed:
                // Injection either completed or the final transcript is already
                // buffered for manual paste. A second WAV recovery could duplicate it.
                recoveryAudio = nil
                recoveryContext = nil
            case .dictationFailed, .sessionExpired:
                break
            case .recording:
                recoveryAudio = nil
                recoveryContext = nil
                await coordinator.reset()
            }
        }
        self.pipelineTask = nil
        self.recordingStartedAt = nil
    }

    private func abortCompletionIfCancelledOrRetired(
        completionGeneration: UInt64
    ) async -> Bool {
        guard cancellationGeneration == completionGeneration,
            cancellationDrain == nil
        else { return true }
        guard Task.isCancelled || isRetired else { return false }
        cancellationGeneration &+= 1
        await cancelAndDrain()
        return true
    }

    /// Time reserved after Realtime finalization for full-file transcription,
    /// optional batch polish, injection, and teardown. The underlying network
    /// clients use 60- and 30-second request timeouts; ten seconds covers the
    /// surrounding pipeline work.
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
        cancellationGeneration &+= 1
        await cancelAndDrain()
    }

    private func cancelAndDrain() async {
        let cancellationDrain = startCancellationDrain()
        await cancellationDrain.task.value
        finishCancellationDrain(id: cancellationDrain.id)
    }

    private func startCancellationDrain() -> CancellationDrain {
        if let cancellationDrain { return cancellationDrain }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCancellationDrain()
        }
        let drain = CancellationDrain(id: id, task: task)
        cancellationDrain = drain
        return drain
    }

    private func finishCancellationDrain(id: UUID) {
        guard cancellationDrain?.id == id else { return }
        cancellationDrain = nil
    }

    private func performCancellationDrain() async {
        let runningCloudRecordingLimitTask =
            takeClaimedCloudRecordingLimitForCancellation()
        let runningPipelineTask = pipelineTask
        pipelineTask = nil
        let runningContextTask = pendingContext
        pendingContext = nil
        let runningSetupTask = audioSetupTask
        audioSetupTask = nil
        let runningForwardingOperation = audioForwardingOperation
        audioForwardingOperation = nil

        runningPipelineTask?.cancel()
        runningContextTask?.cancel()
        runningSetupTask?.cancel()

        recordingStartedAt = nil
        recoveryAudio = nil
        recoveryContext = nil

        // Cancel the streaming session. Always attempt cancellation even
        // if complete() already cleared isStreamingSession — the pipeline
        // task may still be inside finishStreaming(). cancelStreaming() is
        // a no-op when no session is active.
        isStreamingSession = false
        if let streaming = streamingProvider {
            streaming.setChunkHandler(nil)
            await streaming.cancelStreaming()
        }

        // Stop audio if currently recording.
        if audioProvider.isRecording {
            _ = try? await audioProvider.stopRecording()
        }

        if let runningForwardingOperation {
            await runningForwardingOperation.cancel(cancelStreaming: {})
        }

        // Drain every task that can still use the provider or local models.
        // Core ML loading does not stop cooperatively, so dropping these task
        // handles would allow a retired generation to publish model state
        // after its replacement starts.
        await runningSetupTask?.value
        await runningPipelineTask?.value
        _ = await runningContextTask?.value
        await runningCloudRecordingLimitTask?.value

        // Setup can publish a forwarding operation after cancellation if it was
        // inside a non-cancellable engine load. Capture and drain that operation,
        // then cancel the provider once more to remove any late session state.
        let lateForwardingOperation = audioForwardingOperation
        audioForwardingOperation = nil
        if let lateForwardingOperation {
            await lateForwardingOperation.cancel { [streamingProvider] in
                if let streaming = streamingProvider {
                    streaming.setChunkHandler(nil)
                    await streaming.cancelStreaming()
                }
            }
        }

        // Setup may have resumed after the first sweep. Clear every session
        // field it can publish before allowing a subsequent activation.
        isStreamingSession = false
        audioSetupFailed = false
        recoveryAudio = nil
        recoveryContext = nil

        await coordinator.reset()
    }

    /// Mark this pipeline terminal and start cancellation without waiting.
    ///
    /// Composition uses this fence before beginning model shutdown so an
    /// invisible old recording cannot continue while Qwen cancellation drains.
    public func beginRetirement() {
        isRetired = true
        cancellationGeneration &+= 1
        _ = startCancellationDrain()
    }

    /// Permanently stop this pipeline before its providers are released.
    public func retire() async {
        beginRetirement()
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
        streaming: StreamingDictationProviding,
        streamingCandidateIsValid: Bool,
        audioBuffer: AudioBuffer,
        context: AppContext,
        coordinator: RecordingCoordinator
    ) async -> String? {
        guard streamingCandidateIsValid else {
            Log.debug("[Pipeline] Local streaming candidate is incomplete")
            retainRecovery(audio: audioBuffer.data, context: context)
            await coordinator.failDictation()
            return nil
        }

        Log.debug("[Pipeline] finishing streaming session (local)")
        do {
            let text = try await streaming.finishStreaming()
            let result = PolishPipeline.stripTrailingFiller(text)
            Log.debug("[Pipeline] local polished: \"\(result)\"")
            saveSampleIfCollecting(
                streaming: streaming, audio: audioBuffer.data,
                polished: result)
            return result
        } catch {
            Log.debug("[Pipeline] Local finishStreaming failed: \(error)")
            await streaming.cancelStreaming()
            retainRecovery(audio: audioBuffer.data, context: context)
            await coordinator.failDictation()
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
        streaming: StreamingDictationProviding,
        streamingCandidateIsValid: Bool,
        audioBuffer: AudioBuffer,
        context: AppContext,
        batchProvider: BatchDictationProviding,
        coordinator: RecordingCoordinator,
        diagnosticStartedAt: CFAbsoluteTime,
        silenceThreshold: Float
    ) async -> String? {
        var text: String?
        if streamingCandidateIsValid {
            Log.debug("[Pipeline] finishing streaming session (cloud)")
            let finishOperation = StreamingFinishOperation {
                try await streaming.finishStreaming()
            }
            let watchdogSeconds = streaming.finishStreamingWatchdog
            let timeout = watchdogSeconds.isFinite && watchdogSeconds >= 0
                ? watchdogSeconds : 30
            let outcome = await finishOperation.resolve(
                timeout: .seconds(timeout),
                cancelStreaming: { await streaming.cancelStreaming() })
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
            guard !Task.isCancelled else { return nil }
            Log.debug("[Pipeline] Falling back to batch HTTP")
            text = await batchDictate(
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
        return text
    }

    // MARK: - Result Injection

    /// Inject polished text at the cursor.
    ///
    /// Handle empty results, store transcript, transition state,
    /// inject via accessibility API, and log timing.
    private func injectResult(
        _ text: String,
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
        Log.debug("[Pipeline] dictation returned, injecting text: \"\(text)\"")

        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else {
            Log.debug("[Pipeline] Empty dictation result, skipping injection")
            if let store = micDiagnosticStore {
                await store.record(
                    MicDiagnosticEntry(
                        deviceName: audioProvider.deviceName,
                        proximity: audioProvider.micProximity.rawValue,
                        ambientRMS: audioProvider.ambientRMS,
                        peakRMS: audioProvider.peakRMS,
                        gain: audioProvider.gainFactor,
                        threshold: silenceThreshold,
                        duration: audioBuffer.duration,
                        latency: CFAbsoluteTimeGetCurrent() - t0,
                        result: "empty"
                    ))
            }
            await coordinator.reset()
            return
        }

        guard !Task.isCancelled else { return }

        await transcriptBuffer?.store(finalText)

        let injecting = await coordinator.startInjecting()
        guard injecting else {
            if !Task.isCancelled {
                await coordinator.reset()
            }
            return
        }

        // Yield once after publishing `.injecting` so cancellation observers can
        // run, then fence the last point before irreversible target publication.
        await Task.yield()
        guard !Task.isCancelled else {
            _ = await coordinator.failInjection()
            return
        }

        do {
            try await textInjector.inject(text: finalText, into: context)
        } catch {
            Log.debug("[Pipeline] Text injection failed: \(error)")
            await coordinator.failInjection()
            return
        }

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

        if let store = micDiagnosticStore {
            await store.record(
                MicDiagnosticEntry(
                    deviceName: audioProvider.deviceName,
                    proximity: audioProvider.micProximity.rawValue,
                    ambientRMS: audioProvider.ambientRMS,
                    peakRMS: audioProvider.peakRMS,
                    gain: audioProvider.gainFactor,
                    threshold: silenceThreshold,
                    duration: audioBuffer.duration,
                    latency: t5 - t0,
                    result: "ok"
                ))
        }

        await coordinator.finishInjecting()
    }

    // MARK: - Batch Dictation

    /// Send a complete WAV through the batch provider.
    ///
    /// Capture has already passed the session peak gate. Do not classify the
    /// complete WAV again by average RMS: brief speech followed by silence is
    /// still a valid dictation and must reach recovery unchanged.
    private func batchDictate(
        audioBuffer: AudioBuffer,
        context: AppContext,
        batchProvider: BatchDictationProviding,
        coordinator: RecordingCoordinator,
        diagnosticStartedAt: CFAbsoluteTime,
        silenceThreshold: Float
    ) async -> String? {
        guard !audioBuffer.data.isEmpty else {
            Log.debug("[Pipeline] Empty audio buffer, skipping dictation")
            await coordinator.reset()
            return nil
        }

        guard !Task.isCancelled else { return nil }

        // Send audio + context to the dictation service.
        do {
            let text = try await batchProvider.dictate(
                audio: audioBuffer.data, context: context)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Log.debug("[Pipeline] Batch returned no text; retaining complete WAV")
                if let store = micDiagnosticStore {
                    await store.record(
                        MicDiagnosticEntry(
                            deviceName: audioProvider.deviceName,
                            proximity: audioProvider.micProximity.rawValue,
                            ambientRMS: audioProvider.ambientRMS,
                            peakRMS: audioProvider.peakRMS,
                            gain: audioProvider.gainFactor,
                            threshold: silenceThreshold,
                            duration: audioBuffer.duration,
                            latency: CFAbsoluteTimeGetCurrent() - diagnosticStartedAt,
                            result: "empty"
                        ))
                }
                retainRecovery(audio: audioBuffer.data, context: context)
                await coordinator.failDictation()
                return nil
            }
            return text
        } catch let error as DictationError where error == .authenticationFailed {
            Log.debug("[Pipeline] Dictation returned 401, session expired")
            retainRecovery(audio: audioBuffer.data, context: context)
            await notifySessionExpired()
            return nil
        } catch {
            Log.debug("[Pipeline] Dictation failed: \(error)")
            retainRecovery(audio: audioBuffer.data, context: context)
            await coordinator.failDictation()
            return nil
        }
    }

    private func retainRecovery(audio: Data, context: AppContext) {
        recoveryAudio = audio
        recoveryContext = context
    }

    // MARK: - Session expiry

    /// Transition the coordinator to `.sessionExpired` and invoke the
    /// callback so the app can clear credentials and start recovery.
    private func notifySessionExpired() async {
        guard !Task.isCancelled else { return }
        let expired = await coordinator.expireSession()
        guard expired, !Task.isCancelled else { return }
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
        guard recoveryAudio != nil, recoveryContext != nil, batchProvider != nil else {
            await coordinator.reset()
            return
        }

        _ = await coordinator.prepareDictationRecovery()
    }

    /// Re-attempt batch transcription of the saved recovery audio.
    ///
    /// Called from the HUD "Retry" button. On success, inject the text
    /// and return to idle. On failure, stay in `.dictationFailed` so
    /// the user can try again or dismiss.
    public func retryDictation() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard let audio = recoveryAudio,
            let context = recoveryContext,
            let batchProvider
        else {
            await coordinator.reset()
            return
        }

        let started = await coordinator.retryDictation()
        guard started else { return }
        guard !isRetired else { return }

        do {
            let text = try await batchProvider.dictate(
                audio: audio, context: context)
            guard !isRetired else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.debug("[Pipeline] Retry returned no text; keeping recovery audio")
                _ = await coordinator.failDictation()
                return
            }

            await transcriptBuffer?.store(trimmed)
            recoveryAudio = nil
            recoveryContext = nil
            guard !isRetired else { return }
            let injecting = await coordinator.startInjecting()
            guard injecting else {
                await coordinator.reset()
                return
            }

            let freshContext = await contextProvider.readContext()
            guard !isRetired else { return }
            do {
                try await textInjector.inject(text: trimmed, into: freshContext)
                await coordinator.finishInjecting()
            } catch {
                Log.debug("[Pipeline] Recovery injection failed: \(error)")
                await coordinator.failInjection()
            }
        } catch let error as DictationError where error == .authenticationFailed {
            Log.debug("[Pipeline] Retry returned 401, session expired")
            await notifySessionExpired()
        } catch {
            Log.debug("[Pipeline] Retry dictation failed: \(error)")
            _ = await coordinator.failDictation()
        }
    }

    /// Discard the saved recovery audio and return to idle.
    ///
    /// Called from the HUD "Dismiss" button or Escape key.
    public func dismissDictationFailure() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        recoveryAudio = nil
        recoveryContext = nil
        await coordinator.reset()
    }
}
