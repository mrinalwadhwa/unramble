import Foundation

/// Provides audio recording capabilities.
///
/// Real implementations use AVAudioEngine to capture from the default input device.
/// A mock implementation returns stub AudioBuffer values for testing.
public protocol AudioProviding: Sendable {

    /// Begin one owner-fenced capture generation.
    func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws

    /// Close only the named owner's publication boundary.
    @discardableResult
    func closeRecordingBoundary(owner: AudioCaptureOwner) -> Bool

    /// Close only the named owner at a physical-event host timestamp.
    @discardableResult
    func closeRecordingBoundary(
        owner: AudioCaptureOwner,
        atHostTime releaseHostTime: UInt64
    ) -> Bool

    /// Stop only the named capture. Concurrent duplicate calls for the same
    /// owner must join the same physical drain.
    func stopRecording(owner: AudioCaptureOwner) async throws -> AudioBuffer

    func isRecording(owner: AudioCaptureOwner) -> Bool
    func pcmAudioStream(owner: AudioCaptureOwner) -> AsyncStream<Data>?
    func audioLevelStream(owner: AudioCaptureOwner) -> AsyncStream<Float>?
    func metrics(owner: AudioCaptureOwner) -> AudioCaptureMetrics?

    /// Whether a capture that was not ready at key-up can still recover every
    /// sample from an already-running preview tap. This query must not wait on
    /// the provider's engine-start state lock.
    func canRecoverCaptureReleasedBeforeReadiness(
        owner: AudioCaptureOwner,
        pressHostTime: UInt64
    ) -> Bool

    /// Invalidate only the named capture or in-flight start.
    @discardableResult
    func forceReset(owner: AudioCaptureOwner) -> Bool

    /// Begin capturing audio from the default input device.
    ///
    /// Throws if the microphone is unavailable or permission has not been granted.
    func startRecording() async throws

    /// Begin capture and publish the exact point at which audio is live.
    ///
    /// The callback must run after capture can produce PCM and before this method
    /// performs any unrelated post-start work. The pipeline uses it to close the
    /// key-release boundary without reading provider state that may be locked by
    /// a slow engine start.
    func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws

    /// Begin capture for one physical press. Audio callbacks consult the shared
    /// boundary directly, so key-up takes effect before asynchronous pipeline
    /// completion reaches the provider.
    func startRecording(
        releaseBoundary: AudioCaptureReleaseBoundary,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws

    /// Close the current recording's callback publication boundary.
    ///
    /// This method must synchronously publish the audio sample timestamp at
    /// which capture ends. A callback queued across that boundary may retain
    /// samples timestamped before release, but must exclude samples at or after
    /// release. The PCM stream remains available until asynchronous stop drains
    /// every callback that can still contain a pre-release prefix.
    func closeRecordingBoundary()

    /// Close capture at a host timestamp recorded by the physical input event.
    /// Host time must use the same mach absolute clock as `AVAudioTime.hostTime`.
    func closeRecordingBoundary(atHostTime releaseHostTime: UInt64)

    /// Stop capturing and return the recorded audio.
    ///
    /// Returns the audio captured since `startRecording()` was called,
    /// encoded as WAV PCM data in an `AudioBuffer`.
    func stopRecording() async throws -> AudioBuffer

    /// Whether audio is currently being captured.
    var isRecording: Bool { get }

    /// A stream of raw PCM data chunks emitted during recording.
    ///
    /// Each chunk is 16-bit signed little-endian PCM at 16kHz mono,
    /// with no WAV header. Used by streaming dictation to forward audio
    /// to the server in real time during recording.
    ///
    /// Returns nil if the implementation does not support streaming.
    var pcmAudioStream: AsyncStream<Data>? { get }

    /// A stream of RMS audio levels (0.0 to 1.0) emitted while recording.
    ///
    /// Implementations that support live level metering return a non-nil
    /// stream. The stream yields values at roughly the audio tap rate
    /// (~10-15 per second). The stream finishes when recording stops.
    var audioLevelStream: AsyncStream<Float>? { get }

    /// The highest raw RMS level observed during the current or most recent
    /// recording session. Reset to 0 on each `startRecording()`.
    ///
    /// The pipeline reads this after `stopRecording()` to detect silent
    /// presses early, before sending audio to the server. Values are raw
    /// (unscaled) RMS on 16-bit PCM normalized to 0-1: ambient silence is
    /// ~0.0007, quiet speech starts around 0.01.
    var peakRMS: Float { get }

    /// The ambient (background noise) RMS level measured during the first
    /// ~0.5s of the current or most recent recording session. Reset to 0
    /// on each `startRecording()`.
    ///
    /// The pipeline uses this to compute an adaptive silence threshold:
    /// `max(ambientRMS * 1.2, 0.0005)`. This adapts to the environment
    /// (quiet room vs coffee shop) and to the mic type (built-in laptop
    /// mic has a lower noise floor than AirPods with noise cancellation).
    ///
    /// Returns 0 if calibration has not completed (recording shorter
    /// than 0.5s or no recording yet).
    var ambientRMS: Float { get }

    /// Mic proximity of the device used for the current or most recent
    /// recording session. The pipeline reads this after `startRecording()`
    /// to tell the server whether to apply near-field or far-field noise
    /// reduction.
    var micProximity: MicProximity { get }

    /// The software gain factor applied to the current or most recent
    /// recording session. Far-field mics use 10-16x; near-field use 1.0.
    /// Used by mic diagnostics to report the gain in effect.
    var gainFactor: Float { get }

    /// The name of the audio device used for the current or most recent
    /// recording session (e.g. "MacBook Pro Microphone", "AirPods").
    /// Used by mic diagnostics. Returns "System Default" if unknown.
    var deviceName: String { get }

    /// Tear down any persistent resources (e.g. a long-lived audio engine).
    ///
    /// Call on app termination. Implementations that do not hold persistent
    /// resources can use the default no-op implementation.
    func shutdown()

    /// Terminally invalidate the current audio capture after a failure or timeout.
    ///
    /// This method must be safe to call from outside a blocked recording
    /// operation and must prevent an invalidated start from later publishing
    /// capture readiness. It must also close the current publication boundary,
    /// finish retained streams as teardown unwinds, and leave the provider able
    /// to admit a fresh recording. Repeated calls must be safe.
    ///
    /// Unlike `shutdown()`, reset is part of the pipeline's failure ownership
    /// contract. Every provider must implement it explicitly.
    func forceReset()
}

extension AudioProviding {
    public func canRecoverCaptureReleasedBeforeReadiness(
        owner: AudioCaptureOwner,
        pressHostTime: UInt64
    ) -> Bool {
        false
    }

    public func startRecording(owner: AudioCaptureOwner) async throws {
        try await startRecording(
            owner: owner,
            configuration: .dictation,
            releaseBoundary: nil,
            onCaptureReady: {})
    }

    public func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration
    ) async throws {
        try await startRecording(
            owner: owner,
            configuration: configuration,
            releaseBoundary: nil,
            onCaptureReady: {})
    }

    public func startRecording(
        releaseBoundary: AudioCaptureReleaseBoundary,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await startRecording(onCaptureReady: onCaptureReady)
    }

    /// Providers without sample-time fencing fall back to their synchronous
    /// callback boundary.
    public func closeRecordingBoundary(atHostTime releaseHostTime: UInt64) {
        closeRecordingBoundary()
    }

    /// Default: gain 1.0 (no amplification).
    public var gainFactor: Float { 1.0 }

    /// Default: unknown device name.
    public var deviceName: String { "System Default" }

    /// Default implementation returns nil (no PCM streaming).
    public var pcmAudioStream: AsyncStream<Data>? { nil }

    /// Default implementation returns nil (no live level metering).
    public var audioLevelStream: AsyncStream<Float>? { nil }

    /// Default implementation returns 0 (no level tracking).
    public var peakRMS: Float { 0 }

    /// Default implementation returns 0 (no ambient calibration).
    public var ambientRMS: Float { 0 }

    /// Default implementation assumes a close-talking microphone.
    public var micProximity: MicProximity { .nearField }

    /// Default implementation is a no-op.
    public func shutdown() {}
}
