import Foundation
import ObjCExceptionCatcher

#if canImport(AVFoundation)
    import AVFoundation
#endif

#if canImport(CoreAudio)
    import CoreAudio
#endif

/// Tracks ownership of an audio-engine start independently of the provider's
/// main state lock. A timeout can therefore invalidate and reach the engine
/// even while `AVAudioEngine.start()` is holding that main lock.
final class AudioEngineStartResetLedger<Engine: AnyObject>: @unchecked Sendable {
    struct Attempt: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    struct Invalidation {
        let attempt: Attempt
        let engine: Engine?
    }

    private struct Entry {
        let attempt: Attempt
        var engine: Engine?
        var isValid = true
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var active: Entry?

    func begin() -> Attempt {
        guard let attempt = beginIfIdle() else {
            preconditionFailure("An audio-engine start attempt is already active")
        }
        return attempt
    }

    func beginIfIdle() -> Attempt? {
        lock.withLock {
            guard active == nil else { return nil }
            nextID &+= 1
            let attempt = Attempt(id: nextID)
            active = Entry(attempt: attempt)
            return attempt
        }
    }

    @discardableResult
    func publish(_ engine: Engine, for attempt: Attempt) -> Bool {
        lock.withLock {
            guard active?.attempt == attempt, active?.isValid == true else {
                return false
            }
            active?.engine = engine
            return true
        }
    }

    func invalidateActiveAttempt() -> Invalidation? {
        lock.withLock {
            guard let entry = active else { return nil }
            active?.isValid = false
            return Invalidation(attempt: entry.attempt, engine: entry.engine)
        }
    }

    func isValid(_ attempt: Attempt) -> Bool {
        lock.withLock {
            active?.attempt == attempt && active?.isValid == true
        }
    }

    @discardableResult
    func withValidAttempt(_ attempt: Attempt, _ body: () -> Void) -> Bool {
        lock.withLock {
            guard active?.attempt == attempt, active?.isValid == true else {
                return false
            }
            body()
            return true
        }
    }

    /// Publish capture state and readiness at one reset boundary. A reset can
    /// linearize before both callbacks or after both callbacks, never between
    /// recording becoming live and the pipeline observing that fact.
    @discardableResult
    func commitCaptureReady(
        _ attempt: Attempt,
        publish: () -> Void,
        onCaptureReady: () -> Void
    ) -> Bool {
        withValidAttempt(attempt) {
            publish()
            onCaptureReady()
        }
    }

    func end(_ attempt: Attempt) {
        lock.withLock {
            guard active?.attempt == attempt else { return }
            active = nil
        }
    }
}

/// Fences tap callbacks independently of the provider's main state lock.
/// Closing a boundary timestamps release while callbacks remain admissible for
/// pre-release sample classification until normal stop drains them. Reset
/// invalidates all admissions before a replacement can publish state.
final class AudioCapturePublicationLedger<Token: Equatable & Sendable>:
    @unchecked Sendable
{
    struct Publication: Sendable {
        fileprivate let token: Token
        fileprivate let generation: UInt64
    }

    struct CallbackAdmission: Sendable {
        fileprivate let token: Token
        fileprivate let generation: UInt64
    }

    private enum Phase {
        case open
        case draining(releaseHostTime: UInt64)
    }

    private struct Entry {
        let token: Token
        let generation: UInt64
        let releaseBoundary: AudioCaptureReleaseBoundary?
        var phase: Phase
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var entry: Entry?

    var canBegin: Bool {
        lock.withLock { entry == nil }
    }

    var drainingToken: Token? {
        lock.withLock {
            guard let entry else { return nil }
            guard case .draining = entry.phase else { return nil }
            return entry.token
        }
    }

    @discardableResult
    func begin(
        _ token: Token,
        releaseBoundary: AudioCaptureReleaseBoundary? = nil
    ) -> Publication {
        lock.withLock {
            precondition(entry == nil, "An audio capture publication is still owned")
            nextGeneration &+= 1
            entry = Entry(
                token: token,
                generation: nextGeneration,
                releaseBoundary: releaseBoundary,
                phase: .open)
            return Publication(token: token, generation: nextGeneration)
        }
    }

    /// Admit one callback owned by this publication. Draining callbacks remain
    /// admissible because a queued buffer can straddle the release timestamp.
    func admitCallback(for publication: Publication) -> CallbackAdmission? {
        lock.withLock {
            guard let entry,
                entry.token == publication.token,
                entry.generation == publication.generation
            else {
                return nil
            }
            return CallbackAdmission(
                token: publication.token,
                generation: publication.generation)
        }
    }

    /// Timestamp release and enter the drain phase. This is idempotent so
    /// `stopRecording()` can join a boundary closed synchronously earlier.
    @discardableResult
    func beginDraining(
        _ token: Token,
        releaseHostTime: UInt64 = AudioCaptureReleaseFence.currentHostTime()
    ) -> Bool {
        lock.withLock {
            guard var entry, entry.token == token else { return false }
            if case .open = entry.phase {
                entry.phase = .draining(releaseHostTime: releaseHostTime)
                self.entry = entry
            }
            return true
        }
    }

    /// Close whichever capture currently owns publication. This token-free
    /// entry point lets the provider publish the sample-time boundary without
    /// first taking the main engine lock.
    @discardableResult
    func beginDrainingCurrentCapture(
        releaseHostTime: UInt64 = AudioCaptureReleaseFence.currentHostTime()
    ) -> Bool {
        lock.withLock {
            guard var entry else { return false }
            if case .open = entry.phase {
                entry.phase = .draining(releaseHostTime: releaseHostTime)
                self.entry = entry
            }
            return true
        }
    }

    /// Whether a callback admitted before the boundary may still publish.
    /// Reset invalidates its generation; normal draining does not.
    func accepts(_ admission: CallbackAdmission) -> Bool {
        lock.withLock {
            guard let entry else { return false }
            return entry.token == admission.token
                && entry.generation == admission.generation
        }
    }

    /// Return the exact sample prefix owned by this publication. Callbacks may
    /// enter during drain so a queued buffer can retain samples captured before
    /// release while excluding samples at or after the release timestamp.
    func preReleaseFrameCount(
        for admission: CallbackAdmission,
        bufferStartHostTime: UInt64?,
        sampleRate: Double,
        frameLength: Int
    ) -> Int? {
        lock.withLock {
            guard let entry,
                entry.token == admission.token,
                entry.generation == admission.generation
            else { return nil }

            let physicalReleaseHostTime = entry.releaseBoundary?.releaseHostTime
            let releaseHostTime: UInt64?
            switch entry.phase {
            case .open:
                releaseHostTime = physicalReleaseHostTime
            case .draining(let drainedReleaseHostTime):
                releaseHostTime = physicalReleaseHostTime.map {
                    min($0, drainedReleaseHostTime)
                } ?? drainedReleaseHostTime
            }

            guard let releaseHostTime else {
                return frameLength
            }
            // AVAudioEngine normally supplies a valid first-sample host time.
            // If it does not, retain the buffer: preserving dictated speech is
            // more important than excluding an unknowable post-release suffix.
            guard let bufferStartHostTime else { return frameLength }
            return AudioCaptureReleaseFence.preReleaseFrameCount(
                bufferStartHostTime: bufferStartHostTime,
                releaseHostTime: releaseHostTime,
                sampleRate: sampleRate,
                frameLength: frameLength)
        }
    }

    func finishDraining(_ token: Token) {
        lock.withLock {
            guard let entry, entry.token == token else { return }
            guard case .draining = entry.phase else { return }
            self.entry = nil
        }
    }

    func reset() {
        lock.withLock {
            entry = nil
        }
    }

    /// Reset only the named capture. A delayed stop must not invalidate a
    /// replacement capture that has already opened a new generation.
    @discardableResult
    func reset(_ token: Token) -> Bool {
        lock.withLock {
            guard entry?.token == token else { return false }
            entry = nil
            return true
        }
    }
}

/// Capture audio from the default input device via AVAudioEngine.
///
/// Records audio and converts it to 16kHz, mono, 16-bit PCM. On stop,
/// the accumulated samples are WAV-encoded into an `AudioBuffer`.
///
/// The engine is created once on the first `startRecording()` call and
/// kept running across sessions. Start/stop only installs and removes
/// the input tap, avoiding the 0.5-1.2s engine setup cost on each
/// press. The engine is torn down on audio device changes
/// (`AVAudioEngineConfigurationChange`) and rebuilt on the next
/// recording. Call `shutdown()` on app termination.
///
/// Requires microphone permission before calling `startRecording()`.
public final class AudioCaptureProvider: AudioProviding, @unchecked Sendable {

    /// Target audio format for dictation: 16kHz, mono, 16-bit integer PCM.
    static let targetSampleRate: Double = 16000
    static let targetChannels: AVAudioChannelCount = 1
    static let targetBitsPerSample = 16

    private let lock = NSLock()
    private var _isRecording = false

    #if canImport(AVFoundation)
        private typealias CaptureAttempt =
            AudioEngineStartResetLedger<AVAudioEngine>.Attempt
        private typealias CaptureCallbackAdmission =
            AudioCapturePublicationLedger<CaptureAttempt>.CallbackAdmission
        private typealias CapturePublication =
            AudioCapturePublicationLedger<CaptureAttempt>.Publication

        private let engineStartResetLedger = AudioEngineStartResetLedger<AVAudioEngine>()
        private var recordingStartAttempt: CaptureAttempt?
        private let publicationLedger =
            AudioCapturePublicationLedger<CaptureAttempt>()
        private let captureSinkOwnership =
            AudioCaptureSinkOwnershipLedger<CaptureAttempt>()
        private var startCleanupInProgress = false
    #endif

    private var _peakRMS: Float = 0
    private var _ambientRMS: Float = 0
    private var _ambientSampleCount: Int = 0
    private var _ambientSumOfSquares: Double = 0
    private var _ambientCalibrated: Bool = false
    private var _micProximity: MicProximity = .nearField
    private var _deviceName: String = "System Default"
    private var pcmChunks: [Data] = []

    /// Software gain factor applied to outbound PCM audio for far-field
    /// (built-in) mics. Lifts quiet speech and whispers into a range
    /// where the server's transcription model works reliably. Computed
    /// once after ambient calibration completes. Near-field mics always
    /// use 1.0 (no gain). Raw peak/ambient RMS values are unaffected
    /// so the silence gate logic is unchanged.
    private var _droppedFrameCount: Int = 0
    private var _gainFactor: Float = 1.0

    /// Target RMS level for gained audio. Quiet speech on a near-field
    /// mic produces RMS ~0.02; lifting far-field audio to this level
    /// gives the transcription model a strong signal without clipping.
    private static let targetGainRMS: Float = 0.02

    /// Maximum gain multiplier. Caps amplification to prevent noise
    /// from being amplified into distortion. At 16x, a sample of
    /// ±2048 (RMS ~0.06, loud speech) reaches ±32768 (Int16 boundary).
    private static let maxGainFactor: Float = 16.0

    /// Optional sound feedback provider for start/stop audio cues.
    private var _soundFeedbackProvider: SoundFeedbackProvider?

    /// Optional device provider for mic selection. When set, the engine
    /// is configured to capture from the selected device instead of the
    /// system default.
    private weak var _audioDeviceProvider: CoreAudioDeviceProvider?

    /// The device ID the engine was last configured with, or nil for
    /// system default. Used to detect when the device changed and the
    /// engine needs rebuilding.
    private var _configuredDeviceID: UInt32?

    /// Set by `handleConfigChangeLocked` when a device switch occurs
    /// mid-recording. The current session keeps its tap and streams
    /// intact; `ensureEngine()` checks this flag on the next
    /// `startRecording()` and rebuilds the engine then.
    private var _needsEngineRebuild: Bool = false

    #if canImport(AVFoundation)
        /// Persistent engine, created on first recording and reused.
        private var engine: AVAudioEngine?
        private var converterLifecycle: PCMConverterLifecycle?
        /// The tap format negotiated with the hardware on engine creation.
        private var tapFormat: AVAudioFormat?
        /// Observer token for audio device configuration changes.
        private var configChangeObserver: NSObjectProtocol?
        /// Timestamp when the engine was last created. Config-change
        /// notifications that arrive within a short window after
        /// creation are ignored because they are caused by our own
        /// `setInputDevice` / `engine.start()` setup, not by an
        /// external hardware change.
        private var _engineCreatedAt: CFAbsoluteTime = 0
    #endif

    // MARK: - PCM audio stream

    private let pcmStreamSnapshot = AudioCapturePCMStreamSnapshot()
    private var pcmContinuation: AsyncStream<Data>.Continuation?

    public var pcmAudioStream: AsyncStream<Data>? {
        pcmStreamSnapshot.current
    }

    // MARK: - Audio level stream

    private var _audioLevelStream: AsyncStream<Float>?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    public var audioLevelStream: AsyncStream<Float>? {
        lock.withLock { _audioLevelStream }
    }

    /// The highest RMS level observed during the current (or most recent)
    /// recording session. Reset to 0 on each `startRecording()`. The
    /// pipeline reads this after `stopRecording()` to detect silent
    /// presses before sending audio to the server.
    public var peakRMS: Float {
        lock.withLock { _peakRMS }
    }

    /// The ambient (background noise) RMS level measured during the first
    /// ~0.5s of the current or most recent recording session. Used by
    /// the pipeline to compute an adaptive silence threshold.
    ///
    /// Returns 0 if calibration has not completed (recording shorter
    /// than 0.5s or no recording yet).
    public var ambientRMS: Float {
        lock.withLock { _ambientRMS }
    }

    /// Mic proximity of the device used for the current or most recent
    /// recording session. Set during engine creation based on the
    /// configured device's transport type. Defaults to `.nearField`.
    public var micProximity: MicProximity {
        lock.withLock { _micProximity }
    }

    /// The software gain factor applied to outbound audio for the
    /// current or most recent recording session. Far-field mics use
    /// 10-16x; near-field mics use 1.0.
    public var gainFactor: Float {
        lock.withLock { _gainFactor }
    }

    /// The name of the audio device used for the current or most
    /// recent recording session. Set during engine creation.
    public var deviceName: String {
        lock.withLock { _deviceName }
    }

    public init() {}

    /// Set the device provider used for mic selection.
    ///
    /// Call once during setup, before the first recording session. The
    /// provider is held weakly to avoid retain cycles with `AppDelegate`.
    public func setAudioDeviceProvider(_ provider: CoreAudioDeviceProvider) {
        lock.withLock { _audioDeviceProvider = provider }
    }

    /// Set the sound feedback provider for start/stop audio cues.
    ///
    /// Call once during setup. The provider uses its own dedicated
    /// playback engine; this reference lets `startRecording()` and
    /// `stopRecording()` trigger sounds at the exact moments the
    /// capture state changes. Pass `nil` to mute sound cues (e.g.
    /// during mic preview in the settings window).
    public func setSoundFeedbackProvider(_ provider: SoundFeedbackProvider?) {
        lock.withLock { _soundFeedbackProvider = provider }
    }

    deinit {
        #if canImport(AVFoundation)
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            engine?.stop()
        #endif
    }

    // MARK: - AudioProviding

    public var isRecording: Bool {
        lock.withLock { _isRecording }
    }

    public func startRecording() async throws {
        try await startRecording(onCaptureReady: {})
    }

    public func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await startRecordingOwned(
            releaseBoundary: nil,
            onCaptureReady: onCaptureReady)
    }

    public func startRecording(
        releaseBoundary: AudioCaptureReleaseBoundary,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await startRecordingOwned(
            releaseBoundary: releaseBoundary,
            onCaptureReady: onCaptureReady)
    }

    private func startRecordingOwned(
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        #if canImport(AVFoundation)
            // Reserve reset ownership before waiting on the engine lock. A
            // concurrent reset can now invalidate even a start that has not
            // entered provider state yet.
            guard let attempt = engineStartResetLedger.beginIfIdle() else {
                throw AudioCaptureError.alreadyRecording
            }
            var failedEngine: AVAudioEngine?
            var claimedProviderState = false
            let soundProvider: SoundFeedbackProvider?
            do {
                soundProvider = try lock.withLock {
                    guard !_isRecording, !startCleanupInProgress,
                        publicationLedger.canBegin
                    else {
                        throw AudioCaptureError.alreadyRecording
                    }
                    guard captureSinkOwnership.begin(attempt) else {
                        throw AudioCaptureError.alreadyRecording
                    }

                    claimedProviderState = true
                    var didStart = false
                    defer {
                        if !didStart {
                            failedEngine = engineStartResetLedger
                                .invalidateActiveAttempt()?.engine
                            startCleanupInProgress = true
                            discardCaptureStateLocked(ownedBy: attempt)
                            engineStartResetLedger.end(attempt)
                        }
                    }

                    pcmChunks = []
                    _peakRMS = 0
                    _ambientRMS = 0
                    _ambientSampleCount = 0
                    _ambientSumOfSquares = 0
                    _ambientCalibrated = false
                    _gainFactor = 1.0

                    // Set up the PCM audio stream before starting capture.
                    let (pcmStream, pcmCont) = AsyncStream<Data>.makeStream()
                    self.pcmContinuation = pcmCont

                    // Set up the audio level stream before starting capture.
                    let (stream, continuation) = AsyncStream<Float>.makeStream()
                    self._audioLevelStream = stream
                    self.levelContinuation = continuation

                    // Create or reuse the persistent engine.
                    var engine = try ensureEngine(for: attempt)

                    // Open callback admission before installing the tap. A running
                    // engine can invoke the tap immediately; opening later would
                    // discard the first captured buffer while this lock is held.
                    let tapPublication = publicationLedger.begin(
                        attempt,
                        releaseBoundary: releaseBoundary)

                    // Install the audio tap. Pass nil as the format so
                    // AVAudioEngine uses the input node's current native
                    // format, avoiding a crash when the hardware sample
                    // rate changes between ensureEngine() and installTap()
                    // (e.g. AirPods finishing Bluetooth negotiation).
                    //
                    // AVAudioEngine throws ObjC exceptions (not Swift
                    // errors) on installTap failures such as stale audio
                    // hardware state after device switches. Catch the
                    // exception, tear down, rebuild, and retry once.
                    let bufferSize: AVAudioFrameCount = 4096
                    let tapException = ObjCTryCatch {
                        engine.inputNode.installTap(
                            onBus: 0,
                            bufferSize: bufferSize,
                            format: nil
                        ) { [weak self] buffer, timestamp in
                            self?.processTapBuffer(
                                buffer,
                                timestamp: timestamp,
                                publication: tapPublication)
                        }
                    }

                    if let tapException {
                        Log.debug(
                            "[AudioCapture] installTap failed: \(tapException.reason ?? tapException.name.rawValue), "
                                + "rebuilding engine and retrying"
                        )
                        tearDownEngineLocked()
                        engine = try ensureEngine(for: attempt)
                        publicationLedger.reset()
                        let retryTapPublication = publicationLedger.begin(
                            attempt,
                            releaseBoundary: releaseBoundary)

                        let retryException = ObjCTryCatch {
                            engine.inputNode.installTap(
                                onBus: 0,
                                bufferSize: bufferSize,
                                format: nil
                            ) { [weak self] buffer, timestamp in
                                self?.processTapBuffer(
                                    buffer,
                                    timestamp: timestamp,
                                    publication: retryTapPublication)
                            }
                        }
                        if let retryException {
                            Log.debug(
                                "[AudioCapture] installTap retry failed: "
                                    + "\(retryException.reason ?? retryException.name.rawValue)"
                            )
                            tearDownEngineLocked()
                            throw AudioCaptureError.noInputDevice
                        }
                    }

                    // Read the actual tap format from the input node after
                    // installation. This is the format buffers will arrive
                    // in, which may differ from what outputFormat(forBus:)
                    // reported during ensureEngine().
                    let actualTapFormat = engine.inputNode.outputFormat(forBus: 0)
                    if self.tapFormat?.sampleRate != actualTapFormat.sampleRate
                        || self.tapFormat?.channelCount != actualTapFormat.channelCount
                    {
                        Log.debug(
                            "[AudioCapture] Tap format updated: "
                                + "sampleRate=\(actualTapFormat.sampleRate), "
                                + "channels=\(actualTapFormat.channelCount)"
                        )
                        self.tapFormat = actualTapFormat
                        self.converterLifecycle = nil
                    }

                    // Every recording gets a fresh converter session. Reusing a
                    // converter leaks its resampler state across dictations.
                    do {
                        try ensureConverterLifecycle().begin()
                    } catch {
                        throw AudioCaptureError.formatError
                    }

                    guard
                        engineStartResetLedger.commitCaptureReady(
                            attempt,
                            publish: {
                                _isRecording = true
                                recordingStartAttempt = attempt
                                _droppedFrameCount = 0
                                pcmStreamSnapshot.publish(pcmStream)
                            },
                            onCaptureReady: onCaptureReady)
                    else {
                        tearDownEngineLocked()
                        throw resetDuringEngineStartError
                    }
                    didStart = true
                    return _soundFeedbackProvider
                }
            } catch {
                if claimedProviderState {
                    cleanUpFailedStart(engine: failedEngine)
                } else {
                    engineStartResetLedger.end(attempt)
                }
                throw error
            }

            // Play the start sound after the lock is released. The
            // capture engine is fully running and the tap is installed,
            // so the dedicated playback engine is not contending with
            // engine setup. Calling outside the lock eliminates the
            // intermittent misses caused by lock contention between
            // the capture and playback engines.
            soundProvider?.playStartSound()
        #else
            throw AudioCaptureError.noInputDevice
        #endif
    }

    public func closeRecordingBoundary() {
        #if canImport(AVFoundation)
            let releaseHostTime = AudioCaptureReleaseFence.currentHostTime()
            closeRecordingBoundary(atHostTime: releaseHostTime)
        #endif
    }

    public func closeRecordingBoundary(atHostTime releaseHostTime: UInt64) {
        #if canImport(AVFoundation)
            publicationLedger.beginDrainingCurrentCapture(
                releaseHostTime: releaseHostTime)
        #endif
    }

    public func stopRecording() async throws -> AudioBuffer {
        #if canImport(AVFoundation)
            let releaseHostTime = AudioCaptureReleaseFence.currentHostTime()
            // Grab the engine reference and mark not-recording under the
            // lock, but do NOT call removeTap inside the lock. removeTap
            // synchronously waits for any in-flight tap callback to
            // finish, and the tap callback acquires this same lock to
            // append PCM chunks — calling removeTap while holding the
            // lock deadlocks when a callback is in progress.
            let stopClaim: (
                engine: AVAudioEngine,
                sound: SoundFeedbackProvider?,
                attempt: CaptureAttempt
            )? = lock.withLock {
                    guard _isRecording,
                        let attempt = recordingStartAttempt,
                        let engine,
                        publicationLedger.beginDraining(
                            attempt,
                            releaseHostTime: releaseHostTime)
                    else { return nil }
                    _isRecording = false
                    engineStartResetLedger.end(attempt)
                    recordingStartAttempt = nil
                    return (engine, _soundFeedbackProvider, attempt)
                }

            guard let stopClaim else {
                return .empty
            }
            let engineToStop = stopClaim.engine
            let attempt = stopClaim.attempt

            // Remove the tap outside the lock. This blocks until any
            // in-flight tap callback completes, which is safe because
            // we are not holding the lock. After this returns, no more
            // callbacks will fire.
            let removeTapException = ObjCTryCatch {
                engineToStop.inputNode.removeTap(onBus: 0)
            }
            if let removeTapException {
                let resetOwnedPublication = publicationLedger.reset(attempt)
                engineToStop.stop()
                let discardedOwnedState = lock.withLock {
                    guard captureSinkOwnership.owns(attempt) else { return false }
                    if engine === engineToStop {
                        tearDownEngineLocked()
                    }
                    discardCaptureStateLocked(ownedBy: attempt)
                    return true
                }
                guard resetOwnedPublication, discardedOwnedState else {
                    return .empty
                }
                throw AudioCaptureError.engineStopFailed(
                    removeTapException.reason ?? removeTapException.name.rawValue
                )
            }

            // Stop the engine to release the microphone hardware. This
            // dismisses the orange mic indicator in the menu bar between
            // sessions. The engine is kept around for fast restart:
            // ensureEngine() calls engine.start() which re-acquires the
            // hardware without the full ~800ms creation cost.
            engineToStop.stop()

            // Play the stop sound after the capture engine is stopped.
            // The dedicated playback engine handles output independently.
            // Playing after engine.stop() ensures the mic is released,
            // so the sound is not captured by the next recording session's
            // ambient calibration window (which would inflate the silence
            // threshold and reject real speech).
            stopClaim.sound?.playStopSound()

            // With the tap removed, all admitted callbacks have completed and
            // the converter can be ended without racing a consume call. Append
            // and stream the exact same tail bytes before closing either sink.
            let converterClaim: (owned: Bool, session: PCMConverterLifecycle?) =
                lock.withLock {
                    guard captureSinkOwnership.owns(attempt) else {
                        return (false, nil)
                    }
                    defer { converterLifecycle = nil }
                    return (true, converterLifecycle)
                }
            guard converterClaim.owned else { return .empty }
            let converterSession = converterClaim.session
            let converterTail: Data
            do {
                let rawTail = try converterSession?.finish() ?? Data()
                let gain = lock.withLock { _gainFactor }
                converterTail = Self.applySoftwareGain(rawTail, gain: gain)
            } catch {
                converterSession?.discard()
                converterTail = Data()
                Log.debug("[AudioCapture] Audio converter tail drain failed: \(error)")
            }

            // Collect accumulated data and tear down streams under the
            // lock. No tap callbacks can race here because removeTap
            // has already drained them.
            let captureResult: (data: Data, peak: Float) = lock.withLock {
                guard captureSinkOwnership.owns(attempt) else {
                    return (Data(), 0)
                }
                let ownsDrain = publicationLedger.drainingToken == attempt
                if ownsDrain {
                    publishPCMDataLocked(converterTail)
                }
                pcmContinuation?.finish()
                pcmContinuation = nil
                pcmStreamSnapshot.clear()
                levelContinuation?.finish()
                levelContinuation = nil
                _audioLevelStream = nil
                if ownsDrain {
                    publicationLedger.finishDraining(attempt)
                }
                captureSinkOwnership.finish(attempt)
                let peak = _peakRMS

                guard ownsDrain else {
                    pcmChunks = []
                    return (Data(), peak)
                }

                // Concatenate all accumulated PCM chunks.
                let totalSize = pcmChunks.reduce(0) { $0 + $1.count }
                var combined = Data(capacity: totalSize)
                for chunk in pcmChunks {
                    combined.append(chunk)
                }
                pcmChunks = []
                return (combined, peak)
            }
            let pcmData = captureResult.data

            if pcmData.isEmpty {
                return .empty
            }

            let duration = WAVEncoder.duration(
                byteCount: pcmData.count,
                sampleRate: Int(Self.targetSampleRate),
                channels: Int(Self.targetChannels),
                bitsPerSample: Self.targetBitsPerSample
            )

            let wavData = WAVEncoder.encode(
                pcmData: pcmData,
                sampleRate: Int(Self.targetSampleRate),
                channels: Int(Self.targetChannels),
                bitsPerSample: Self.targetBitsPerSample
            )

            let buffer = AudioBuffer(
                data: wavData,
                duration: duration,
                sampleRate: Int(Self.targetSampleRate),
                channels: Int(Self.targetChannels),
                bitsPerSample: Self.targetBitsPerSample
            )

            // If peak RMS is exactly zero, the audio tap received no
            // data at all. This happens when Bluetooth devices (AirPods)
            // fail to re-establish their SCO audio channel after a
            // device switch. Tear down the engine so the next session
            // gets a fresh one instead of reusing the broken state.
            if captureResult.peak == 0, duration > 0.5 {
                Log.debug(
                    "[AudioCapture] Zero audio captured (\(String(format: "%.2f", duration))s), "
                        + "tearing down engine"
                )
                lock.withLock {
                    guard !captureSinkOwnership.hasOwner,
                        engine === engineToStop
                    else { return }
                    tearDownEngineLocked()
                }
            }

            return buffer
        #else
            return .empty
        #endif
    }

    /// Tear down the audio engine. Call on app termination.
    public func shutdown() {
        #if canImport(AVFoundation)
            lock.withLock {
                tearDownEngineLocked()
            }
        #endif
    }

    /// Force-reset the audio engine after a timeout.
    ///
    /// When `startRecording()` hangs inside `engine.start()` (BT SCO
    /// negotiation), it holds the lock indefinitely. This method uses
    /// `lock.try()` — if the lock is available, it tears down normally.
    /// If the lock is held (stuck `startRecording`), it stops the engine
    /// directly to unblock `engine.start()`. The invalidated start owner
    /// tears down its state as it unwinds and cannot publish recording.
    public func forceReset() {
        #if canImport(AVFoundation)
            // Publish/reset ownership is independent of `lock`, so the
            // first engine is reachable even while its start call blocks.
            let invalidated = engineStartResetLedger.invalidateActiveAttempt()
            publicationLedger.reset()
            pcmStreamSnapshot.clear()
            if lock.try() {
                tearDownEngineLocked()
                _isRecording = false
                if let attempt = recordingStartAttempt {
                    engineStartResetLedger.end(attempt)
                    recordingStartAttempt = nil
                }
                discardCaptureStateLocked()
                lock.unlock()
                Log.debug("[AudioCapture] Force reset (lock available)")
            } else {
                // The candidate was published before `engine.start()`.
                // Stopping it can unblock BT SCO negotiation without
                // reading provider state outside its main lock.
                invalidated?.engine?.stop()
                if let attempt = invalidated?.attempt {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.finishForceReset(for: attempt)
                    }
                }
                Log.debug("[AudioCapture] Force reset (lock held, engine stopped)")
            }
        #endif
    }

    /// Mark the engine for rebuild on the next recording session.
    ///
    /// Called by `CoreAudioDeviceProvider` when the device list or
    /// default input device changes. AVAudioEngine does not emit
    /// `AVAudioEngineConfigurationChange` when it is stopped, so
    /// device changes that happen between recording sessions leave
    /// the engine with stale CoreAudio state. Without this, the
    /// next `ensureEngine()` tries to reuse the stopped engine,
    /// and `engine.start()` hangs indefinitely.
    public func markNeedsRebuild() {
        #if canImport(AVFoundation)
            lock.withLock {
                guard !_isRecording else { return }
                guard engine != nil else { return }
                _needsEngineRebuild = true
                Log.debug(
                    "[AudioCapture] Marked for rebuild (external device change while idle)"
                )
            }
        #endif
    }

    // MARK: - Persistent engine management

    #if canImport(AVFoundation)
        /// Return the existing engine or create a new one. Must be called
        /// while `lock` is held. Starts the engine and registers for
        /// configuration change notifications on first creation.
        ///
        /// If a `CoreAudioDeviceProvider` is set and has a selected device,
        /// the engine's input node is configured to capture from that device.
        /// When the selected device changes between sessions, the existing
        /// engine is torn down and rebuilt for the new device.
        private func ensureEngine(
            for attempt: AudioEngineStartResetLedger<AVAudioEngine>.Attempt
        ) throws -> AVAudioEngine {
            let desiredDeviceID = _audioDeviceProvider?.selectedDeviceID

            if let engine {
                guard engineStartResetLedger.publish(engine, for: attempt) else {
                    throw resetDuringEngineStartError
                }
                // If the selected device changed or a config change was
                // deferred during a previous recording, tear down and
                // rebuild with the current hardware.
                if desiredDeviceID != _configuredDeviceID || _needsEngineRebuild {
                    Log.debug(
                        "[AudioCapture] Device changed from \(_configuredDeviceID?.description ?? "default") "
                            + "to \(desiredDeviceID?.description ?? "default")"
                            + "\(_needsEngineRebuild ? " (deferred rebuild)" : "")"
                            + ", rebuilding engine"
                    )
                    _needsEngineRebuild = false
                    tearDownEngineLocked()
                    // Fall through to create a new engine.
                } else {
                    // Engine exists for the correct device. Reuse it
                    // for low latency. Re-query mic proximity in case
                    // the system default device changed while the engine
                    // was stopped (e.g. AirPods connected between
                    // sessions). The engine follows the new default
                    // automatically on restart, but _micProximity was
                    // stale from the previous device.
                    _micProximity =
                        _audioDeviceProvider?.micProximityForDevice(
                            _configuredDeviceID
                        ) ?? .nearField
                    _deviceName =
                        _audioDeviceProvider?.deviceNameForDevice(
                            _configuredDeviceID
                        ) ?? "System Default"
                    if !engine.isRunning {
                        // Validate the hardware format before reusing a
                        // stopped engine. AVAudioEngine does not emit
                        // configurationChange notifications when stopped,
                        // so device changes between sessions can leave
                        // the engine with stale CoreAudio state. If the
                        // hardware format changed (sample rate, channels,
                        // or reports 0), tear down and rebuild.
                        let currentFormat = engine.inputNode.outputFormat(forBus: 0)
                        if currentFormat.sampleRate <= 0
                            || currentFormat.sampleRate != tapFormat?.sampleRate
                            || currentFormat.channelCount != tapFormat?.channelCount
                        {
                            Log.debug(
                                "[AudioCapture] Hardware format changed while stopped "
                                    + "(was \(tapFormat?.sampleRate ?? 0)/\(tapFormat?.channelCount ?? 0), "
                                    + "now \(currentFormat.sampleRate)/\(currentFormat.channelCount)), "
                                    + "rebuilding engine"
                            )
                            tearDownEngineLocked()
                            // Fall through to create a new engine.
                        } else {
                            guard engineStartResetLedger.isValid(attempt) else {
                                throw resetDuringEngineStartError
                            }
                            engine.prepare()
                            var startError: Error?
                            let startException = ObjCTryCatch {
                                do { try engine.start() } catch { startError = error }
                            }
                            if let startException {
                                Log.debug(
                                    "[AudioCapture] engine.start() ObjC exception on reuse: "
                                        + "\(startException.reason ?? startException.name.rawValue), "
                                        + "rebuilding engine"
                                )
                                tearDownEngineLocked()
                                // Fall through to create a new engine.
                            } else if let startError {
                                Log.debug(
                                    "[AudioCapture] engine.start() failed on reuse: "
                                        + "\(startError), rebuilding engine"
                                )
                                tearDownEngineLocked()
                                // Fall through to create a new engine.
                            } else {
                                guard engineStartResetLedger.isValid(attempt) else {
                                    engine.stop()
                                    tearDownEngineLocked()
                                    throw resetDuringEngineStartError
                                }
                                return engine
                            }
                        }
                    } else {
                        guard engineStartResetLedger.isValid(attempt) else {
                            throw resetDuringEngineStartError
                        }
                        return engine
                    }
                }
            }

            guard engineStartResetLedger.isValid(attempt) else {
                throw resetDuringEngineStartError
            }

            _engineCreatedAt = CFAbsoluteTimeGetCurrent()

            let engine = AVAudioEngine()
            guard engineStartResetLedger.publish(engine, for: attempt) else {
                throw resetDuringEngineStartError
            }

            // Configure the input device before accessing inputNode's
            // format. Setting the device after reading the format would
            // use the wrong sample rate and channel count.
            #if canImport(CoreAudio)
                if let deviceID = desiredDeviceID {
                    do {
                        try setInputDevice(deviceID, on: engine)
                    } catch {
                        // Device is no longer available (disconnected
                        // AirPods, unplugged USB mic, etc.). Clear the
                        // selection and fall back to the system default.
                        Log.debug(
                            "[AudioCapture] Device \(deviceID) unavailable, "
                                + "falling back to system default"
                        )
                        _audioDeviceProvider?.clearSelection()
                        // Continue without setInputDevice — the engine
                        // will use the system default input device.
                    }
                }
            #endif
            _configuredDeviceID = _audioDeviceProvider?.selectedDeviceID
            _micProximity =
                _audioDeviceProvider?.micProximityForDevice(
                    _configuredDeviceID
                ) ?? .nearField
            _deviceName =
                _audioDeviceProvider?.deviceNameForDevice(
                    _configuredDeviceID
                ) ?? "System Default"

            let inputNode = engine.inputNode

            let hardwareFormat = inputNode.outputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0 else {
                throw AudioCaptureError.noInputDevice
            }

            // Use a float intermediate for the tap, then convert to int16.
            guard
                let tapFmt = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: hardwareFormat.sampleRate,
                    channels: hardwareFormat.channelCount,
                    interleaved: false
                )
            else {
                throw AudioCaptureError.formatError
            }

            engine.prepare()
            guard engineStartResetLedger.isValid(attempt) else {
                engine.stop()
                throw resetDuringEngineStartError
            }
            var startError: Error?
            let startException = ObjCTryCatch {
                do { try engine.start() } catch { startError = error }
            }
            if let startException {
                throw AudioCaptureError.engineStartFailed(
                    startException.reason ?? startException.name.rawValue
                )
            }
            if let startError {
                throw startError
            }
            guard engineStartResetLedger.isValid(attempt) else {
                engine.stop()
                throw resetDuringEngineStartError
            }

            self.engine = engine
            self.tapFormat = tapFmt
            // Invalidate the converter so it is rebuilt against the new tap format.
            self.converterLifecycle = nil

            registerConfigChangeObserver()

            Log.debug(
                "[AudioCapture] Engine created (device=\(desiredDeviceID?.description ?? "default"), "
                    + "sampleRate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount))"
            )

            return engine
        }

        #if canImport(CoreAudio)
            /// Set the input device on an AVAudioEngine's input node.
            ///
            /// Uses `AudioUnitSetProperty` with `kAudioOutputUnitProperty_CurrentDevice`
            /// to route the engine's input to the specified Core Audio device.
            private func setInputDevice(
                _ deviceID: AudioObjectID, on engine: AVAudioEngine
            ) throws {
                guard let audioUnit = engine.inputNode.audioUnit else {
                    throw AudioCaptureError.deviceSelectionFailed(deviceID)
                }

                var mutableDeviceID = deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &mutableDeviceID,
                    UInt32(MemoryLayout<AudioObjectID>.size)
                )

                guard status == noErr else {
                    Log.debug(
                        "[AudioCapture] Failed to set input device \(deviceID): OSStatus \(status)"
                    )
                    throw AudioCaptureError.deviceSelectionFailed(deviceID)
                }

                Log.debug("[AudioCapture] Input device set to \(deviceID)")
            }
        #endif

        /// Return the converter lifecycle matching `tapFormat`.
        /// Must be called while `lock` is held and after `ensureEngine()`.
        private func ensureConverterLifecycle() throws -> PCMConverterLifecycle {
            if let converterLifecycle {
                return converterLifecycle
            }

            guard let tapFormat else {
                throw AudioCaptureError.formatError
            }

            guard
                let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Self.targetSampleRate,
                    channels: Self.targetChannels,
                    interleaved: true
                )
            else {
                throw AudioCaptureError.formatError
            }

            let lifecycle = PCMConverterLifecycle(
                inputFormat: tapFormat,
                outputFormat: targetFormat
            )
            self.converterLifecycle = lifecycle
            return lifecycle
        }

        /// Register for `AVAudioEngineConfigurationChange` to handle device
        /// switches (e.g. AirPods connect/disconnect). Tears down the engine
        /// so it is rebuilt with the new hardware format on the next recording.
        private func registerConfigChangeObserver() {
            // Remove any previous observer before registering a new one.
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }

            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                Log.debug("[AudioCapture] Engine configuration changed (device switch)")
                self.lock.withLock {
                    self.handleConfigChangeLocked()
                }
            }
        }

        /// Handle an audio configuration change while `lock` is held.
        ///
        /// If a recording is in progress, defer the teardown: set
        /// `_needsEngineRebuild` so the next `ensureEngine()` call
        /// (at the start of the next recording session) rebuilds the
        /// engine with the new hardware. The current session keeps its
        /// tap and streams intact and finishes normally with whatever
        /// audio was captured before the switch. This avoids ripping
        /// out the tap mid-recording and producing zero audio.
        ///
        /// If not recording, tear down immediately so the engine is
        /// rebuilt fresh on the next session.
        private func handleConfigChangeLocked() {
            // Ignore config-change notifications that arrive shortly
            // after engine creation. Setting the input device and
            // starting the engine fire AVAudioEngineConfigurationChange
            // asynchronously; without this guard the handler would tear
            // down the engine and remove the tap mid-recording.
            let age = CFAbsoluteTimeGetCurrent() - _engineCreatedAt
            if age < 1.0 {
                Log.debug(
                    "[AudioCapture] Config change ignored (engine created "
                        + "\(String(format: "%.3f", age))s ago)"
                )
                return
            }
            if publicationLedger.drainingToken != nil {
                _needsEngineRebuild = true
                Log.debug(
                    "[AudioCapture] Config change while stopping, deferring rebuild"
                )
                return
            }
            if _isRecording {
                // Check if the hardware format actually changed before
                // deferring a rebuild. AVAudioEngine fires spurious
                // config change notifications during BT negotiation
                // that don't indicate a real device change.
                if let engine, let tapFmt = tapFormat {
                    let hwFormat = engine.inputNode.outputFormat(forBus: 0)
                    if hwFormat.sampleRate == tapFmt.sampleRate
                        && hwFormat.channelCount == tapFmt.channelCount
                    {
                        Log.debug(
                            "[AudioCapture] Config change during recording ignored"
                                + " (format unchanged: \(hwFormat.sampleRate)Hz)")
                        return
                    }
                }
                _needsEngineRebuild = true
                Log.debug(
                    "[AudioCapture] Config change during recording, deferring rebuild"
                        + " (format changed)")
                return
            }
            tearDownEngineLocked()
        }

        /// Stop the engine and clear cached state. Must be called while
        /// `lock` is held.
        private func tearDownEngineLocked() {
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            engine?.stop()
            engine = nil
            converterLifecycle?.discard()
            converterLifecycle = nil
            tapFormat = nil
            _configuredDeviceID = nil
        }

        private var resetDuringEngineStartError: AudioCaptureError {
            .engineStartFailed("Audio engine was reset while starting")
        }

        /// Finish a reset that could not acquire `lock` synchronously. The
        /// attempt check prevents delayed cleanup from touching a replacement.
        private func finishForceReset(
            for attempt: AudioEngineStartResetLedger<AVAudioEngine>.Attempt
        ) {
            lock.withLock {
                guard recordingStartAttempt == attempt else { return }
                tearDownEngineLocked()
                discardCaptureStateLocked(ownedBy: attempt)
                engineStartResetLedger.end(attempt)
            }
        }

        /// Tear down an engine/tap allocated by a failed start without holding
        /// the provider lock while removeTap drains callbacks. The cleanup flag
        /// prevents a replacement start from claiming the engine in between.
        private func cleanUpFailedStart(engine failedEngine: AVAudioEngine?) {
            if let failedEngine {
                _ = ObjCTryCatch {
                    failedEngine.inputNode.removeTap(onBus: 0)
                }
                failedEngine.stop()
            }
            lock.withLock {
                if let failedEngine, engine === failedEngine {
                    tearDownEngineLocked()
                }
                startCleanupInProgress = false
            }
        }

        /// Clear state allocated before a failed start. Must be called
        /// while `lock` is held.
        private func discardCaptureStateLocked(
            ownedBy attempt: CaptureAttempt? = nil
        ) {
            if let attempt {
                guard captureSinkOwnership.finish(attempt) else { return }
                publicationLedger.reset(attempt)
            } else {
                captureSinkOwnership.reset()
                publicationLedger.reset()
            }
            _isRecording = false
            recordingStartAttempt = nil
            pcmContinuation?.finish()
            pcmContinuation = nil
            pcmStreamSnapshot.clear()
            levelContinuation?.finish()
            levelContinuation = nil
            _audioLevelStream = nil
            pcmChunks = []
            converterLifecycle?.discard()
        }
    #endif

    // MARK: - Audio level metering

    #if canImport(AVFoundation)
        /// Classify the callback against the key-release host timestamp before
        /// either metering or conversion. A callback queued until after release
        /// can still contribute its pre-release prefix, but never its suffix.
        private func processTapBuffer(
            _ buffer: AVAudioPCMBuffer,
            timestamp: AVAudioTime,
            publication: CapturePublication
        ) {
            guard let admission = publicationLedger.admitCallback(for: publication)
            else { return }

            let frameLength = Int(buffer.frameLength)
            let sampleRate = buffer.format.sampleRate
            let bufferStartHostTime = AudioCaptureReleaseFence.bufferStartHostTime(
                timestamp: timestamp)
            guard
                let retainedFrameCount = publicationLedger.preReleaseFrameCount(
                    for: admission,
                    bufferStartHostTime: bufferStartHostTime,
                    sampleRate: sampleRate,
                    frameLength: frameLength),
                let retainedBuffer = AudioCaptureReleaseFence.trimToPrefix(
                    buffer,
                    frameCount: retainedFrameCount)
            else { return }

            emitAudioLevel(retainedBuffer, admission: admission)
            processAudioBuffer(retainedBuffer, admission: admission)
        }

        /// Compute RMS level from a float32 PCM buffer, update peak tracking,
        /// and emit the scaled level to the stream.
        /// Ambient calibration window in samples at the hardware sample
        /// rate. 0.5s × 16kHz = 8000 samples. The actual hardware rate
        /// may differ (44.1kHz, 48kHz) but we use the target rate as an
        /// approximation; the exact window length is not critical.
        private static let ambientCalibrationSamples: Int = Int(targetSampleRate * 0.5)

        private func emitAudioLevel(
            _ buffer: AVAudioPCMBuffer,
            admission: CaptureCallbackAdmission
        ) {
            guard let floatData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            let samples = floatData[0]
            var sumOfSquares: Float = 0
            for i in 0..<frameLength {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }
            let rms = sqrtf(sumOfSquares / Float(frameLength))

            lock.withLock {
                guard publicationLedger.accepts(admission) else { return }
                // Track the raw (unscaled) peak for silence detection.
                // Raw values are used so the silence gate in
                // DictationPipeline is unaffected by gain.
                if rms > _peakRMS {
                    _peakRMS = rms
                }

                // Accumulate ambient noise level during the calibration
                // window (first ~0.5s of recording). After enough samples,
                // compute the ambient RMS once and stop accumulating.
                // Then compute the software gain factor for far-field mics.
                if !_ambientCalibrated {
                    _ambientSumOfSquares += Double(sumOfSquares)
                    _ambientSampleCount += frameLength
                    if _ambientSampleCount >= Self.ambientCalibrationSamples {
                        _ambientRMS = Float(
                            sqrt(
                                _ambientSumOfSquares / Double(_ambientSampleCount)
                            ))
                        _ambientCalibrated = true
                        _gainFactor = Self.computeGainFactor(
                            ambientRMS: _ambientRMS,
                            micProximity: _micProximity
                        )
                        Log.debug(
                            "[AudioCapture] Ambient calibrated: RMS=\(_ambientRMS), "
                                + "proximity=\(_micProximity.rawValue), "
                                + "gain=\(_gainFactor)"
                        )
                    }
                }

                // Apply gain to the visualization so the HUD level bar
                // reflects the amplified signal the server will receive.
                // Without this, the bar barely moves for built-in mic
                // whispers even though the server gets a strong signal.
                let displayRMS = rms * _gainFactor
                let scaled = min(sqrtf(displayRMS * 25.0), 1.0)
                levelContinuation?.yield(scaled)
            }
        }
    #endif

    // MARK: - Internal

    #if canImport(AVFoundation)
        private func processAudioBuffer(
            _ buffer: AVAudioPCMBuffer,
            admission: CaptureCallbackAdmission
        ) {
            let converterLifecycle: PCMConverterLifecycle? = lock.withLock {
                guard publicationLedger.accepts(admission) else { return nil }
                return self.converterLifecycle
            }
            guard let converterLifecycle else { return }

            let rawData: Data
            do {
                rawData = try converterLifecycle.consume(buffer)
            } catch {
                // Log and skip this chunk rather than crashing.
                let count: Int? = lock.withLock {
                    guard publicationLedger.accepts(admission) else { return nil }
                    _droppedFrameCount += 1
                    return _droppedFrameCount
                }
                if let count {
                    Log.debug(
                        "[AudioCapture] Audio conversion error (dropped \(count)): \(error)")
                }
                return
            }

            guard !rawData.isEmpty else { return }

            // Apply software gain for far-field mics to lift quiet speech and
            // whispers into a range the transcription model handles well.
            let gain: Float? = lock.withLock {
                guard publicationLedger.accepts(admission) else { return nil }
                return _gainFactor
            }
            guard let gain else { return }
            let data = Self.applySoftwareGain(rawData, gain: gain)

            lock.withLock {
                guard publicationLedger.accepts(admission) else { return }
                publishPCMDataLocked(data)
            }
        }

        /// Publish one byte-identical PCM chunk to both the live stream and
        /// the eventual WAV accumulator. Must be called while `lock` is held.
        private func publishPCMDataLocked(_ data: Data) {
            guard !data.isEmpty else { return }
            pcmChunks.append(data)
            pcmContinuation?.yield(data)
        }
    #endif

    // MARK: - Software gain helpers

    /// Compute the gain factor for a far-field mic given the measured
    /// ambient RMS. Returns 1.0 for near-field mics or when ambient
    /// is zero. Clamps to `[1.0, maxGainFactor]`.
    static func computeGainFactor(
        ambientRMS: Float,
        micProximity: MicProximity
    ) -> Float {
        guard micProximity == .farField, ambientRMS > 0 else {
            return 1.0
        }
        let raw = targetGainRMS / ambientRMS
        return min(max(raw, 1.0), maxGainFactor)
    }

    /// Apply a gain factor to raw Int16 PCM data, clamping each sample
    /// to `Int16.min...Int16.max` to prevent overflow wrapping.
    /// Returns the input unchanged when gain is <= 1.0.
    static func applySoftwareGain(
        _ pcmData: Data,
        gain: Float
    ) -> Data {
        guard gain > 1.0 else { return pcmData }
        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { return pcmData }

        var output = Data(capacity: pcmData.count)
        pcmData.withUnsafeBytes { rawBuffer in
            for i in 0..<sampleCount {
                let lo = UInt16(rawBuffer[i * 2])
                let hi = UInt16(rawBuffer[i * 2 + 1])
                let sample = Int16(bitPattern: lo | (hi << 8))
                let amplified = Int32(Float(sample) * gain)
                let clamped = Int16(clamping: amplified)
                var le = clamped.littleEndian
                withUnsafeBytes(of: &le) { output.append(contentsOf: $0) }
            }
        }
        return output
    }
}

// MARK: - Errors

/// Errors that can occur during audio capture.
public enum AudioCaptureError: Error, Sendable, CustomStringConvertible {
    /// `startRecording()` was called while already recording.
    case alreadyRecording
    /// No audio input device is available.
    case noInputDevice
    /// Failed to create the required audio format or converter.
    case formatError
    /// Failed to set the requested input device on the audio engine.
    case deviceSelectionFailed(UInt32)
    /// The audio engine threw an exception during start.
    case engineStartFailed(String)
    /// The audio engine threw an exception while removing its input tap.
    case engineStopFailed(String)

    public var description: String {
        switch self {
        case .alreadyRecording:
            return "Audio capture is already in progress"
        case .noInputDevice:
            return "No audio input device available"
        case .formatError:
            return "Failed to configure audio format"
        case .deviceSelectionFailed(let id):
            return "Failed to select audio input device \(id)"
        case .engineStartFailed(let reason):
            return "Audio engine failed to start: \(reason)"
        case .engineStopFailed(let reason):
            return "Audio engine failed to stop: \(reason)"
        }
    }
}
