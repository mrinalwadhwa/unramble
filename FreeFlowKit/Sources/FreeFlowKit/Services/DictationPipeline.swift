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
///      await context, send audio + context to the dictation service,
///      inject text, return to `.idle`. In streaming mode, call
///      `finishStreaming()` instead of the batch dictation endpoint.
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
    /// session recovery flow. Invoked at most once per pipeline run.
    private let onSessionExpired: (@Sendable () -> Void)?

    /// Minimum audio duration (in seconds) worth sending to the server.
    private let minimumAudioDuration: TimeInterval = 0.1

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
    private let minimumAdaptiveThreshold: Float = 0.0005

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

    /// Background task that forwards PCM chunks to the streaming provider.
    private var audioForwardingTask: Task<Void, Never>?

    /// Task that performs audio setup after activate() returns.
    /// complete() awaits this to ensure audio is ready before stopping.
    private var audioSetupTask: Task<Void, Never>?

    /// Whether the current recording session is using streaming mode.
    private var isStreamingSession: Bool = false

    /// Set by performAudioSetup when startRecording fails. Checked by
    /// complete() to skip dictation and reset immediately.
    private var audioSetupFailed: Bool = false

    /// Thread-safe flag set by the chunk handler when at least one
    /// intermediate chunk has been injected. Read in `complete()` to
    /// decide whether the backup/batch race is safe.
    private var chunkInjectedFlag: ChunkInjectedFlag?

    /// Thread-safe flag that the `@Sendable` chunk handler can set
    /// from outside the actor.
    private final class ChunkInjectedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func set() { lock.withLock { _value = true } }
        var isSet: Bool { lock.withLock { _value } }
    }

    /// Thread-safe box to pass recovery data from inside the pipeline
    /// task closure back to the actor after the task ends.
    private final class RecoveryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _audio: Data?
        private var _context: AppContext?
        func set(audio: Data, context: AppContext) {
            lock.withLock { _audio = audio; _context = context }
        }
        var audio: Data? { lock.withLock { _audio } }
        var context: AppContext? { lock.withLock { _context } }
    }

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

    /// When true, skip the streaming-vs-batch race and use streaming
    /// result directly. Local on-device providers cannot run concurrent
    /// SpeechAnalyzer instances safely.
    private let localMode: Bool

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
        return silenceThreshold
    }

    // MARK: - PipelineProviding

    public var state: RecordingState {
        get async {
            await coordinator.state
        }
    }

    public func activate() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let currentState = await coordinator.state
        guard currentState == .idle else {
            Log.debug("[Pipeline] activate() ignored — state is \(currentState)")
            return
        }

        let t1 = CFAbsoluteTimeGetCurrent()
        let started = await coordinator.startRecording()
        guard started else { return }
        let t2 = CFAbsoluteTimeGetCurrent()
        Log.debug(
            "[Pipeline] activate() state check: \(String(format: "%.3f", t1 - t0))s, startRecording: \(String(format: "%.3f", t2 - t1))s"
        )

        recordingStartedAt = Date()
        audioSetupFailed = false

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
            // If startRecording() timed out, the background task may
            // finish and leave _isRecording=true permanently. Stop it
            // so the next session can start cleanly.
            Task { [audioProvider] in
                _ = try? await audioProvider.stopRecording()
            }
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

            let t5 = CFAbsoluteTimeGetCurrent()
            let micProximity = audioProvider.micProximity
            let language = self.language

            // Tell the provider to deliver intermediate chunks. Each
            // chunk is injected at the current cursor position as soon
            // as it is transcribed and polished. This gives rolling
            // text injection during long dictations without waiting
            // for finishStreaming.
            let injector = textInjector
            let chunkFlag = ChunkInjectedFlag()
            self.chunkInjectedFlag = chunkFlag
            streaming.setChunkHandler { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                chunkFlag.set()
                let ctx = await AXAppContextProvider().readContext()
                do {
                    try await injector.inject(text: trimmed, into: ctx)
                    Log.debug("[Pipeline] Injected chunk (\(trimmed.count) chars)")
                } catch {
                    Log.debug("[Pipeline] Chunk injection failed: \(error)")
                }
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

            // If streaming timed out, also cancel the session on the
            // provider so it tears down the broken connection cleanly
            // rather than leaving stale state for the next session.
            if !streamingStarted {
                await streaming.cancelStreaming()
            }

            guard streamingStarted else {
                Log.debug("[Pipeline] Streaming setup timed out or failed, falling back to batch")
                isStreamingSession = false
                return
            }
            let t6 = CFAbsoluteTimeGetCurrent()
            Log.debug(
                "[Pipeline] performAudioSetup() streaming.startStreaming: \(String(format: "%.3f", t6 - t5))s, total: \(String(format: "%.3f", t6 - t0))s"
            )

            // Start a background task that reads PCM chunks and sends them.
            audioForwardingTask = Task {
                for await chunk in pcmStream {
                    guard !Task.isCancelled else { break }
                    do {
                        try await streaming.sendAudio(chunk)
                    } catch {
                        Log.debug("[Pipeline] Error sending audio chunk: \(error)")
                        break
                    }
                }
            }
        } else {
            isStreamingSession = false
        }
    }

    public func complete() async {
        let completeEnteredAt = CFAbsoluteTimeGetCurrent()
        Log.debug("[Pipeline] complete() entering")
        let currentState = await coordinator.state
        guard currentState == .recording else {
            Log.debug("[Pipeline] complete() ignored — state is \(currentState)")
            return
        }

        Log.debug("[Pipeline] complete() transitioning to processing")
        let stopped = await coordinator.stopRecording()
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
                if let streaming = streamingProvider {
                    await streaming.cancelStreaming()
                }
                audioSetupTask = nil
            }
            isStreamingSession = false
            audioForwardingTask?.cancel()
            audioForwardingTask = nil

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
        let forwardingTask = audioForwardingTask
        audioForwardingTask = nil
        isStreamingSession = false

        // Clear the chunk handler before entering the pipeline task so
        // late-arriving chunks cannot inject text during finishStreaming.
        if useStreaming {
            streamingProvider?.setChunkHandler(nil)
        }

        let recoveryBox = RecoveryBox()

        let task = Task {
            [
                pendingContext, audioProvider, batchProvider, streamingProvider,
                textInjector, coordinator, minimumAudioDuration, transcriptBuffer,
                earlyThreshold, micDiagnosticStore, recoveryBox,
                completeEnteredAt
            ] in
            let t0 = CFAbsoluteTimeGetCurrent()

            // Stop audio capture and retrieve the buffer.
            Log.debug("[Pipeline] stopping audio capture")
            let audioBuffer: AudioBuffer
            do {
                audioBuffer = try await audioProvider.stopRecording()
            } catch {
                Log.debug("[Pipeline] Failed to stop recording: \(error)")
                if useStreaming, let streaming = streamingProvider {
                    forwardingTask?.cancel()
                    await streaming.cancelStreaming()
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
            // waiting on the streaming forwarding task or any network
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
                forwardingTask?.cancel()
                if useStreaming, let streaming = streamingProvider {
                    await streaming.cancelStreaming()
                }
                await coordinator.reset()
                return
            }

            // Wait for the audio forwarding task to finish. The PCM stream
            // ends when stopRecording() calls pcmContinuation.finish(), so
            // normally this returns immediately. However, if the forwarding
            // task is stuck in sendAudio() on a broken WebSocket,
            // URLSessionWebSocketTask.send() ignores cancellation. Use a
            // detached-task timeout to bound the wait. If it hangs, cancel
            // the streaming session (which cancels the WebSocket task and
            // forces send() to throw) and proceed with batch mode.
            if let ft = forwardingTask {
                ft.cancel()
                let forwardingDone = await detachedWithTimeout(seconds: 2.0) {
                    await ft.value
                    return true
                } ?? false
                if !forwardingDone {
                    Log.debug(
                        "[Pipeline] audio forwarding task timed out (2s), cancelling streaming")
                    if useStreaming, let streaming = streamingProvider {
                        await streaming.cancelStreaming()
                    }
                }
            }

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

            // Resolve the transcript from the appropriate provider.
            let dictatedText: String?
            if useStreaming, let streaming = streamingProvider {
                let chunksInjected = chunkInjectedFlag?.isSet ?? false
                chunkInjectedFlag = nil
                if localMode {
                    dictatedText = await finishLocalDictation(
                        streaming: streaming,
                        audioBuffer: audioBuffer,
                        context: context,
                        coordinator: coordinator,
                        recoveryBox: recoveryBox)
                } else if let batchProvider {
                    dictatedText = await finishCloudDictation(
                        streaming: streaming,
                        chunksAlreadyInjected: chunksInjected,
                        audioBuffer: audioBuffer,
                        context: context,
                        batchProvider: batchProvider,
                        minimumAudioDuration: minimumAudioDuration,
                        silenceThreshold: postRecordThreshold,
                        coordinator: coordinator,
                        recoveryBox: recoveryBox)
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
                    minimumAudioDuration: minimumAudioDuration,
                    silenceThreshold: postRecordThreshold,
                    coordinator: coordinator,
                    recoveryBox: recoveryBox)
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
        // dictations get the 30 s floor; long dictations get enough
        // time for transcription tail + polish + injection. Without
        // scaling, a 130 s monologue blows past a fixed 15 s deadline
        // and the force-reset races the batch HTTP fallback, dropping
        // a valid transcript instead of injecting it.
        let recordingDuration =
            recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let deadline = Self.pipelineDeadline(
            forRecordingDuration: recordingDuration)
        let pipelineDone = await detachedWithTimeout(seconds: deadline) {
            await task.value
            return true
        } ?? false
        if !pipelineDone { task.cancel() }
        if !pipelineDone {
            Log.debug(
                "[Pipeline] complete() pipeline task timed out (\(Int(deadline))s), force-resetting to idle"
            )
            if let streaming = streamingProvider {
                await streaming.cancelStreaming()
            }
            await coordinator.reset()
        }
        // If the pipeline task stored recovery data (tail batch failed
        // after chunks were injected), save it on the actor so the user
        // can retry via the HUD.
        if let audio = recoveryBox.audio, let ctx = recoveryBox.context {
            self.recoveryAudio = audio
            self.recoveryContext = ctx
        }

        self.pipelineTask = nil
        self.recordingStartedAt = nil
    }

    /// Compute the hard deadline for a pipeline task given how long the
    /// user held the hotkey. The budget is
    /// `max(30, recordingDuration + 45)` capped at 300 s. Short dictations
    /// fast-fail on hangs within 30 s; long ones get a proportional
    /// post-audio window for transcription tail, polish, and injection.
    static func pipelineDeadline(
        forRecordingDuration duration: TimeInterval
    ) -> TimeInterval {
        let budget = duration + 45.0
        return min(300.0, max(30.0, budget))
    }

    public func cancel() async {
        pipelineTask?.cancel()
        pipelineTask = nil
        pendingContext?.cancel()
        pendingContext = nil
        recordingStartedAt = nil
        chunkInjectedFlag = nil
        recoveryAudio = nil
        recoveryContext = nil

        audioSetupTask?.cancel()
        audioSetupTask = nil

        // Cancel audio forwarding if streaming.
        audioForwardingTask?.cancel()
        audioForwardingTask = nil

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

        await coordinator.reset()
    }

    // MARK: - Local Dictation

    /// Finish a local streaming session.
    ///
    /// Transcribe and polish on-device. No batch fallback — local
    /// providers cannot run concurrent sessions. Return the polished
    /// text, or nil on failure (coordinator already updated).
    private func finishLocalDictation(
        streaming: StreamingDictationProviding,
        audioBuffer: AudioBuffer,
        context: AppContext,
        coordinator: RecordingCoordinator,
        recoveryBox: RecoveryBox
    ) async -> String? {
        Log.debug("[Pipeline] finishing streaming session (local)")
        do {
            let text = try await streaming.finishStreaming()
            return PolishPipeline.stripTrailingFiller(text)
        } catch {
            Log.debug("[Pipeline] Local finishStreaming failed: \(error)")
            await streaming.cancelStreaming()
            recoveryBox.set(audio: audioBuffer.data, context: context)
            await coordinator.failDictation()
            return nil
        }
    }

    // MARK: - Cloud Dictation

    /// Finish a cloud streaming session.
    ///
    /// Handle three cases: chunks already injected (tail-only finish),
    /// no chunks yet (finish with batch fallback), or streaming failure
    /// (batch recovery). Return the final text, or nil on failure.
    private func finishCloudDictation(
        streaming: StreamingDictationProviding,
        chunksAlreadyInjected: Bool,
        audioBuffer: AudioBuffer,
        context: AppContext,
        batchProvider: BatchDictationProviding,
        minimumAudioDuration: TimeInterval,
        silenceThreshold: Float,
        coordinator: RecordingCoordinator,
        recoveryBox: RecoveryBox
    ) async -> String? {
        if chunksAlreadyInjected {
            return await finishCloudWithChunks(
                streaming: streaming,
                audioBuffer: audioBuffer,
                context: context,
                batchProvider: batchProvider,
                coordinator: coordinator,
                recoveryBox: recoveryBox)
        }

        // No chunks fired yet (short session). Finish streaming; fall
        // back to batch HTTP on failure.
        Log.debug("[Pipeline] finishing streaming session (cloud)")
        var text: String?
        do {
            let result = try await streaming.finishStreaming()
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                text = result
                Log.debug("[Pipeline] Streaming completed")
            }
        } catch {
            Log.debug("[Pipeline] Streaming failed: \(error)")
        }

        await streaming.cancelStreaming()

        if text == nil {
            Log.debug("[Pipeline] Falling back to batch HTTP")
            text = await batchDictate(
                audioBuffer: audioBuffer,
                context: context,
                batchProvider: batchProvider,
                minimumAudioDuration: minimumAudioDuration,
                silenceThreshold: silenceThreshold,
                coordinator: coordinator,
                recoveryBox: recoveryBox)
        }

        if text == nil {
            Log.debug("[Pipeline] Both streaming and batch failed")
        }
        return text
    }

    /// Finish a cloud session where intermediate chunks were already
    /// injected. Only the tail (uncommitted audio) needs transcription.
    /// On failure, attempt batch recovery of the tail audio.
    private func finishCloudWithChunks(
        streaming: StreamingDictationProviding,
        audioBuffer: AudioBuffer,
        context: AppContext,
        batchProvider: BatchDictationProviding,
        coordinator: RecordingCoordinator,
        recoveryBox: RecoveryBox
    ) async -> String? {
        Log.debug("[Pipeline] finishing streaming session (chunks injected)")
        do {
            return try await streaming.finishStreaming()
        } catch {
            Log.debug("[Pipeline] finishStreaming failed: \(error), attempting tail recovery")
            let tailWAV = Self.extractRecoveryWAV(
                from: audioBuffer,
                uncommittedDuration: streaming.uncommittedAudioDuration)

            guard let tailWAV else {
                await coordinator.reset()
                return nil
            }

            for attempt in 1...3 {
                if attempt > 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard !Task.isCancelled else { break }
                do {
                    let text = try await batchProvider.dictate(
                        audio: tailWAV, context: context)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                } catch {
                    Log.debug("[Pipeline] Tail recovery attempt \(attempt) failed: \(error)")
                }
            }

            recoveryBox.set(audio: tailWAV, context: context)
            await coordinator.failDictation()
            return nil
        }
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
        Log.debug("[Pipeline] dictation returned, injecting text")

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

        guard !Task.isCancelled else {
            await coordinator.reset()
            return
        }

        await transcriptBuffer?.store(finalText)

        let injecting = await coordinator.startInjecting()
        guard injecting else {
            await coordinator.reset()
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

    /// Run the batch dictation path: silence gate, then POST to /dictate.
    ///
    /// Return the dictated text on success, or nil if the pipeline should
    /// abort (audio too short, silent, cancelled, or dictation failed).
    /// On nil return, the coordinator has already been reset.
    private func batchDictate(
        audioBuffer: AudioBuffer,
        context: AppContext,
        batchProvider: BatchDictationProviding,
        minimumAudioDuration: TimeInterval,
        silenceThreshold: Float,
        coordinator: RecordingCoordinator,
        recoveryBox: RecoveryBox? = nil
    ) async -> String? {
        // Skip empty or very short audio.
        guard !audioBuffer.data.isEmpty, audioBuffer.duration >= minimumAudioDuration else {
            Log.debug(
                "[Pipeline] Audio too short (\(audioBuffer.duration)s), skipping dictation")
            await coordinator.reset()
            return nil
        }

        // Reject silent or noise-only audio before sending to the server.
        if AudioLevelAnalyzer.isSilent(audioBuffer, threshold: silenceThreshold) {
            let rms = AudioLevelAnalyzer.rmsLevel(of: audioBuffer)
            Log.debug(
                "[Pipeline] Audio below silence threshold "
                    + "(rms: \(rms), threshold: \(silenceThreshold)), skipping dictation")
            await coordinator.reset()
            return nil
        }

        guard !Task.isCancelled else {
            await coordinator.reset()
            return nil
        }

        // Send audio + context to the dictation service.
        do {
            let text = try await batchProvider.dictate(
                audio: audioBuffer.data, context: context)
            return text
        } catch let error as DictationError where error == .authenticationFailed {
            Log.debug("[Pipeline] Dictation returned 401, session expired")
            await notifySessionExpired()
            return nil
        } catch {
            Log.debug("[Pipeline] Dictation failed: \(error)")
            if let recoveryBox {
                recoveryBox.set(audio: audioBuffer.data, context: context)
                await coordinator.failDictation()
            } else {
                await coordinator.reset()
            }
            return nil
        }
    }

    // MARK: - Session expiry

    /// Transition the coordinator to `.sessionExpired` and invoke the
    /// callback so the app can clear credentials and start recovery.
    private func notifySessionExpired() async {
        await coordinator.expireSession()
        onSessionExpired?()
    }

    // MARK: - Dictation recovery

    /// Extract recovery audio from a full WAV buffer.
    ///
    /// When `uncommittedDuration` is positive, only the uncommitted
    /// tail is extracted (long session with chunks already injected).
    /// When zero, returns nil — the caller should use the full buffer.
    ///
    /// Returns nil if the duration is zero or the tail is empty.
    static func extractRecoveryWAV(
        from buffer: AudioBuffer,
        uncommittedDuration: TimeInterval
    ) -> Data? {
        guard uncommittedDuration > 0 else { return nil }
        let headerSize = WAVEncoder.headerSize
        guard buffer.data.count > headerSize else { return nil }

        // 16 kHz 16-bit mono = 32,000 bytes/sec.
        let bytesPerSecond = buffer.sampleRate * buffer.channels * (buffer.bitsPerSample / 8)
        let tailByteCount = min(
            Int(uncommittedDuration * Double(bytesPerSecond)),
            buffer.data.count - headerSize)
        guard tailByteCount > 0 else { return nil }

        let pcmStart = buffer.data.count - tailByteCount
        let tailPCM = buffer.data.subdata(in: pcmStart..<buffer.data.count)
        return WAVEncoder.encode(
            pcmData: tailPCM,
            sampleRate: buffer.sampleRate,
            channels: buffer.channels,
            bitsPerSample: buffer.bitsPerSample)
    }

    /// Re-attempt batch transcription of the saved recovery audio.
    ///
    /// Called from the HUD "Retry" button. On success, inject the text
    /// and return to idle. On failure, stay in `.dictationFailed` so
    /// the user can try again or dismiss.
    public func retryDictation() async {
        guard let audio = recoveryAudio,
            let context = recoveryContext,
            let batchProvider
        else {
            await coordinator.reset()
            return
        }

        let started = await coordinator.retryDictation()
        guard started else { return }

        do {
            let text = try await batchProvider.dictate(
                audio: audio, context: context)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                recoveryAudio = nil
                recoveryContext = nil
                await coordinator.reset()
                return
            }

            await transcriptBuffer?.store(trimmed)
            let injecting = await coordinator.startInjecting()
            guard injecting else {
                await coordinator.reset()
                return
            }

            let freshContext = await contextProvider.readContext()
            do {
                try await textInjector.inject(text: trimmed, into: freshContext)
                recoveryAudio = nil
                recoveryContext = nil
                await coordinator.finishInjecting()
            } catch {
                Log.debug("[Pipeline] Tail recovery injection failed: \(error)")
                await coordinator.failInjection()
            }
        } catch {
            Log.debug("[Pipeline] Retry tail recovery failed: \(error)")
            _ = await coordinator.failDictation()
        }
    }

    /// Discard the saved recovery audio and return to idle.
    ///
    /// Called from the HUD "Dismiss" button or Escape key.
    public func dismissDictationFailure() async {
        recoveryAudio = nil
        recoveryContext = nil
        await coordinator.reset()
    }
}
