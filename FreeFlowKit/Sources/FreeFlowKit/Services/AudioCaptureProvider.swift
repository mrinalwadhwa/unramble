import Foundation
import ObjCExceptionCatcher

#if canImport(AVFoundation)
    import AVFoundation
#endif

#if canImport(CoreAudio)
    import CoreAudio
#endif

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
        private var converter: AVAudioConverter?
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

    private var _pcmAudioStream: AsyncStream<Data>?
    private var pcmContinuation: AsyncStream<Data>.Continuation?

    public var pcmAudioStream: AsyncStream<Data>? {
        lock.withLock { _pcmAudioStream }
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
        #if canImport(AVFoundation)
            let soundProvider: SoundFeedbackProvider? = try lock.withLock {
                guard !_isRecording else {
                    throw AudioCaptureError.alreadyRecording
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
                self._pcmAudioStream = pcmStream
                self.pcmContinuation = pcmCont

                // Set up the audio level stream before starting capture.
                let (stream, continuation) = AsyncStream<Float>.makeStream()
                self._audioLevelStream = stream
                self.levelContinuation = continuation

                // Create or reuse the persistent engine.
                var engine = try ensureEngine()

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
                    engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) {
                        [weak self] buffer, _ in
                        self?.emitAudioLevel(buffer)
                        self?.processAudioBuffer(buffer)
                    }
                }

                if let tapException {
                    Log.debug(
                        "[AudioCapture] installTap failed: \(tapException.reason ?? tapException.name.rawValue), "
                            + "rebuilding engine and retrying"
                    )
                    tearDownEngineLocked()
                    engine = try ensureEngine()

                    let retryException = ObjCTryCatch {
                        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) {
                            [weak self] buffer, _ in
                            self?.emitAudioLevel(buffer)
                            self?.processAudioBuffer(buffer)
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
                    self.converter = nil
                }

                // Build the converter against the actual tap format.
                let _ = try ensureConverter()

                _isRecording = true
                _droppedFrameCount = 0
                return _soundFeedbackProvider
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

    public func stopRecording() async throws -> AudioBuffer {
        #if canImport(AVFoundation)
            // Grab the engine reference and mark not-recording under the
            // lock, but do NOT call removeTap inside the lock. removeTap
            // synchronously waits for any in-flight tap callback to
            // finish, and the tap callback acquires this same lock to
            // append PCM chunks — calling removeTap while holding the
            // lock deadlocks when a callback is in progress.
            let (engineToStop, soundFeedbackProvider): (AVAudioEngine?, SoundFeedbackProvider?) =
                lock.withLock {
                    guard _isRecording else { return (nil, nil) }
                    _isRecording = false
                    return (engine, _soundFeedbackProvider)
                }

            guard let engineToStop else {
                return .empty
            }

            // Remove the tap outside the lock. This blocks until any
            // in-flight tap callback completes, which is safe because
            // we are not holding the lock. After this returns, no more
            // callbacks will fire.
            engineToStop.inputNode.removeTap(onBus: 0)

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
            soundFeedbackProvider?.playStopSound()

            // Collect accumulated data and tear down streams under the
            // lock. No tap callbacks can race here because removeTap
            // has already drained them.
            let pcmData: Data = lock.withLock {
                pcmContinuation?.finish()
                pcmContinuation = nil
                _pcmAudioStream = nil
                levelContinuation?.finish()
                levelContinuation = nil
                _audioLevelStream = nil

                // Concatenate all accumulated PCM chunks.
                let totalSize = pcmChunks.reduce(0) { $0 + $1.count }
                var combined = Data(capacity: totalSize)
                for chunk in pcmChunks {
                    combined.append(chunk)
                }
                pcmChunks = []
                return combined
            }

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
            let peak = lock.withLock { _peakRMS }
            if peak == 0, duration > 0.5 {
                Log.debug(
                    "[AudioCapture] Zero audio captured (\(String(format: "%.2f", duration))s), "
                        + "tearing down engine"
                )
                lock.withLock {
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
    /// directly to unblock `engine.start()`, then marks for rebuild so
    /// the next session creates a fresh engine.
    public func forceReset() {
        #if canImport(AVFoundation)
            if lock.try() {
                tearDownEngineLocked()
                _isRecording = false
                lock.unlock()
                Log.debug("[AudioCapture] Force reset (lock available)")
            } else {
                // Lock is held — startRecording() is stuck. Stop the
                // engine directly to unblock engine.start().
                engine?.stop()
                _needsEngineRebuild = true
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
        private func ensureEngine() throws -> AVAudioEngine {
            let desiredDeviceID = _audioDeviceProvider?.selectedDeviceID

            if let engine {
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
                                return engine
                            }
                        }
                    } else {
                        return engine
                    }
                }
            }

            _engineCreatedAt = CFAbsoluteTimeGetCurrent()

            let engine = AVAudioEngine()

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

            self.engine = engine
            self.tapFormat = tapFmt
            // Invalidate the converter so it is rebuilt against the new tap format.
            self.converter = nil

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

        /// Return the existing converter or create one matching `tapFormat`.
        /// Must be called while `lock` is held and after `ensureEngine()`.
        private func ensureConverter() throws -> AVAudioConverter {
            if let converter {
                return converter
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

            guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
                throw AudioCaptureError.formatError
            }
            self.converter = converter
            return converter
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
            converter = nil
            tapFormat = nil
            _configuredDeviceID = nil
        }
    #endif

    // MARK: - Audio level metering

    #if canImport(AVFoundation)
        /// Compute RMS level from a float32 PCM buffer, update peak tracking,
        /// and emit the scaled level to the stream.
        /// Ambient calibration window in samples at the hardware sample
        /// rate. 0.5s × 16kHz = 8000 samples. The actual hardware rate
        /// may differ (44.1kHz, 48kHz) but we use the target rate as an
        /// approximation; the exact window length is not critical.
        private static let ambientCalibrationSamples: Int = Int(targetSampleRate * 0.5)

        private func emitAudioLevel(_ buffer: AVAudioPCMBuffer) {
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
            _ buffer: AVAudioPCMBuffer
        ) {
            // Acquire the converter under the lock. It is rebuilt when
            // the tap format changes (device switch).
            let converter: AVAudioConverter? = lock.withLock { self.converter }
            guard let converter else { return }

            // Convert the tap buffer to the target format (16kHz mono int16).
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * Self.targetSampleRate
                    / buffer.format.sampleRate
            )
            guard frameCapacity > 0 else { return }

            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: converter.outputFormat,
                    frameCapacity: frameCapacity + 1
                )
            else {
                return
            }

            var error: NSError?
            var inputConsumed = false

            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let error {
                // Log and skip this chunk rather than crashing.
                let count = lock.withLock {
                    _droppedFrameCount += 1
                    return _droppedFrameCount
                }
                Log.debug("[AudioCapture] Audio conversion error (dropped \(count)): \(error)")
                return
            }

            guard outputBuffer.frameLength > 0 else { return }

            // Extract raw int16 PCM bytes from the output buffer,
            // applying software gain for far-field mics to lift quiet
            // speech and whispers into a range the transcription model
            // handles well.
            let frameCount = Int(outputBuffer.frameLength)
            let gain: Float = lock.withLock { _gainFactor }
            let data: Data

            if let int16Data = outputBuffer.int16ChannelData {
                let byteCount = frameCount * (Self.targetBitsPerSample / 8)
                let raw = Data(bytes: int16Data[0], count: byteCount)
                data = Self.applySoftwareGain(raw, gain: gain)
            } else {
                return
            }

            lock.withLock {
                pcmChunks.append(data)
                pcmContinuation?.yield(data)
            }
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
        }
    }
}
