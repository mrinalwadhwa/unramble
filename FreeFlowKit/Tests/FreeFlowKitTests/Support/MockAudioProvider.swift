import Foundation

@testable import FreeFlowKit

/// A mock AudioProviding implementation that returns stub data.
///
/// Used in tests to exercise the pipeline without real audio capture hardware.
public final class MockAudioProvider: AudioProviding, @unchecked Sendable {

    private let lock = NSLock()

    private var _isRecording = false
    private var activeOwner: AudioCaptureOwner?
    private var startingOwner: AudioCaptureOwner?
    private var metricsOwner: AudioCaptureOwner?
    private var legacyOwner: AudioCaptureOwner?
    private var captureConfiguration: AudioCaptureConfiguration = .dictation
    private var _recordingBoundaryIsOpen = false
    private var _startCallCount = 0
    private var _captureReadyCount = 0
    private var _stopCallCount = 0
    private var _releaseHostTimes: [UInt64] = []
    private var _captureReleaseBoundaries: [AudioCaptureReleaseBoundary] = []
    private var resetGeneration: UInt64 = 0

    private final class StopOperation: @unchecked Sendable {
        let id: UUID
        let owner: AudioCaptureOwner
        let hook: (@Sendable () async -> Void)?

        private let lock = NSLock()
        private var task: Task<Result<AudioBuffer, any Error>, Never>?

        init(
            id: UUID,
            owner: AudioCaptureOwner,
            hook: (@Sendable () async -> Void)?
        ) {
            self.id = id
            self.owner = owner
            self.hook = hook
        }

        func result(
            from provider: MockAudioProvider
        ) async -> Result<AudioBuffer, any Error> {
            let task = lock.withLock {
                if let existingTask = self.task { return existingTask }
                let id = id
                let owner = owner
                let hook = hook
                let task: Task<Result<AudioBuffer, any Error>, Never> =
                    Task.detached { [weak provider] in
                        if let hook { await hook() }
                        guard let provider else {
                            return .failure(CancellationError())
                        }
                        return provider.finishStop(
                            owner: owner,
                            operationID: id)
                    }
                self.task = task
                return task
            }
            return await task.value
        }
    }

    private var stopOperation: StopOperation?
    private var completedStopOperationID: UUID?

    /// The audio buffer returned by `stopRecording()`. Defaults to a short
    /// non-silent buffer so the silence gate does not reject it.
    public var stubbedBuffer: AudioBuffer

    /// The peak RMS level reported by `peakRMS`. Defaults to 0.1 (well
    /// above the 0.005 silence threshold) so the early silence gate in
    /// the pipeline does not reject mock recordings.
    public var stubbedPeakRMS: Float = 0.1

    /// The ambient RMS level reported by `ambientRMS`. Defaults to 0
    /// (no calibration) so existing tests use the fixed silence threshold
    /// fallback. Set to a positive value to test adaptive thresholds.
    public var stubbedAmbientRMS: Float = 0

    /// Mic proximity reported by `micProximity`. Defaults to `.nearField`
    /// so existing tests use the adaptive threshold path. Set to
    /// `.farField` to test the built-in mic fixed threshold bypass.
    public var stubbedMicProximity: MicProximity = .nearField

    /// When true, `startRecording()` creates a `pcmAudioStream` that
    /// emits each chunk passed to `emitPCMChunk(_:)`. Defaults to false
    /// so existing tests are unaffected.
    public var enablePCMStream: Bool = false

    /// When non-nil, `startRecording()` sleeps for this duration then
    /// throws the error. Simulates BT negotiation timeout or hardware
    /// failure.
    public var stubbedStartDelay: TimeInterval = 0
    public var stubbedStartError: (any Error)?

    /// Optional deterministic suspension point for ownership race tests.
    public var stopWillComplete: (@Sendable () async -> Void)?

    private var _pcmAudioStream: AsyncStream<Data>?
    private var pcmContinuation: AsyncStream<Data>.Continuation?
    private var _audioLevelStream: AsyncStream<Float>?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    /// Number of times `startRecording()` has been called.
    public var startCallCount: Int {
        lock.withLock { _startCallCount }
    }

    /// Number of capture-ready boundaries published by `startRecording()`.
    public var captureReadyCount: Int {
        lock.withLock { _captureReadyCount }
    }

    /// Number of times `stopRecording()` has been called.
    public var stopCallCount: Int {
        lock.withLock { _stopCallCount }
    }

    /// Physical release timestamps received from the pipeline.
    public var releaseHostTimes: [UInt64] {
        lock.withLock { _releaseHostTimes }
    }

    /// Per-activation boundaries installed by the pipeline.
    public var captureReleaseBoundaries: [AudioCaptureReleaseBoundary] {
        lock.withLock { _captureReleaseBoundaries }
    }

    public init(stubbedBuffer: AudioBuffer? = nil) {
        self.stubbedBuffer =
            stubbedBuffer
            ?? Self.makeNonSilentBuffer()
    }

    /// Build a 1-second WAV buffer with audible samples.
    ///
    /// Alternates ±3000 samples so the RMS (~0.09) is well above the
    /// default silence threshold (0.005). Uses WAVEncoder to produce a
    /// valid WAV file with a proper RIFF header.
    private static func makeNonSilentBuffer() -> AudioBuffer {
        let sampleRate = 16000
        let channels = 1
        let bitsPerSample = 16
        let sampleCount = sampleRate  // 1 second

        var pcmData = Data(capacity: sampleCount * (bitsPerSample / 8))
        for i in 0..<sampleCount {
            let sample: Int16 = i % 2 == 0 ? 3000 : -3000
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }

        let wavData = WAVEncoder.encode(
            pcmData: pcmData,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        let duration = WAVEncoder.duration(
            byteCount: pcmData.count,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        return AudioBuffer(
            data: wavData,
            duration: duration,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
    }

    public var isRecording: Bool {
        lock.withLock { _isRecording }
    }

    public var pcmAudioStream: AsyncStream<Data>? {
        lock.withLock { _pcmAudioStream }
    }

    public func pcmAudioStream(owner: AudioCaptureOwner) -> AsyncStream<Data>? {
        lock.withLock {
            guard activeOwner == owner else { return nil }
            return _pcmAudioStream
        }
    }

    public func audioLevelStream(owner: AudioCaptureOwner) -> AsyncStream<Float>? {
        lock.withLock {
            guard activeOwner == owner else { return nil }
            return _audioLevelStream
        }
    }

    public func isRecording(owner: AudioCaptureOwner) -> Bool {
        lock.withLock { activeOwner == owner && _isRecording }
    }

    public func metrics(owner: AudioCaptureOwner) -> AudioCaptureMetrics? {
        lock.withLock {
            guard metricsOwner == owner else { return nil }
            return AudioCaptureMetrics(
                peakRMS: stubbedPeakRMS,
                ambientRMS: stubbedAmbientRMS,
                micProximity: stubbedMicProximity,
                gainFactor: 1,
                deviceName: "Mock audio input")
        }
    }

    public func startRecording() async throws {
        try await startRecording(onCaptureReady: {})
    }

    public func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let owner = AudioCaptureOwner.preview()
        lock.withLock { legacyOwner = owner }
        do {
            try await startRecordingOwned(
                owner: owner,
                configuration: .dictation,
                releaseBoundary: nil,
                onCaptureReady: onCaptureReady)
        } catch {
            lock.withLock {
                if legacyOwner == owner { legacyOwner = nil }
            }
            throw error
        }
    }

    public func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await startRecordingOwned(
            owner: owner,
            configuration: configuration,
            releaseBoundary: releaseBoundary,
            onCaptureReady: onCaptureReady)
    }

    public func startRecording(
        releaseBoundary: AudioCaptureReleaseBoundary,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let owner = AudioCaptureOwner.preview()
        lock.withLock { legacyOwner = owner }
        do {
            try await startRecordingOwned(
                owner: owner,
                configuration: .dictation,
                releaseBoundary: releaseBoundary,
                onCaptureReady: onCaptureReady)
        } catch {
            lock.withLock {
                if legacyOwner == owner { legacyOwner = nil }
            }
            throw error
        }
    }

    private func startRecordingOwned(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let startGeneration: UInt64 = try lock.withLock {
            if let operation = stopOperation {
                guard completedStopOperationID == operation.id else {
                    throw AudioCaptureError.alreadyRecording
                }
                stopOperation = nil
                completedStopOperationID = nil
            }
            guard activeOwner == nil, startingOwner == nil else {
                throw AudioCaptureError.alreadyRecording
            }
            startingOwner = owner
            return resetGeneration
        }
        do {
            if stubbedStartDelay > 0 {
                try await Task.sleep(
                    nanoseconds: UInt64(stubbedStartDelay * 1_000_000_000))
            }
            if let error = stubbedStartError {
                throw error
            }
        } catch {
            lock.withLock {
                if startingOwner == owner, resetGeneration == startGeneration {
                    startingOwner = nil
                }
            }
            throw error
        }
        let didStart = lock.withLock {
            guard resetGeneration == startGeneration,
                startingOwner == owner,
                activeOwner == nil
            else { return false }
            startingOwner = nil
            activeOwner = owner
            metricsOwner = owner
            captureConfiguration = configuration
            _isRecording = true
            _recordingBoundaryIsOpen = true
            _startCallCount += 1
            if let releaseBoundary {
                _captureReleaseBoundaries.append(releaseBoundary)
            }

            if enablePCMStream, configuration.retainsPCM {
                let (stream, continuation) = AsyncStream<Data>.makeStream()
                _pcmAudioStream = stream
                pcmContinuation = continuation
            } else {
                _pcmAudioStream = nil
                pcmContinuation = nil
            }
            let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream(
                bufferingPolicy: .bufferingNewest(1))
            _audioLevelStream = levelStream
            self.levelContinuation = levelContinuation
            onCaptureReady()
            _captureReadyCount += 1
            return true
        }
        guard didStart else { throw CancellationError() }
    }

    /// Emit a PCM chunk to the `pcmAudioStream`. Only works when
    /// `enablePCMStream` is true and recording is active.
    public func emitPCMChunk(_ data: Data) {
        lock.withLock {
            guard _recordingBoundaryIsOpen else { return }
            pcmContinuation?.yield(data)
        }
    }

    public func closeRecordingBoundary() {
        guard let owner = lock.withLock({ legacyOwner }) else { return }
        _ = closeRecordingBoundary(owner: owner)
    }

    public func closeRecordingBoundary(atHostTime releaseHostTime: UInt64) {
        guard let owner = lock.withLock({ legacyOwner }) else { return }
        _ = closeRecordingBoundary(owner: owner, atHostTime: releaseHostTime)
    }

    @discardableResult
    public func closeRecordingBoundary(owner: AudioCaptureOwner) -> Bool {
        lock.withLock {
            guard activeOwner == owner else { return false }
            _recordingBoundaryIsOpen = false
            return true
        }
    }

    @discardableResult
    public func closeRecordingBoundary(
        owner: AudioCaptureOwner,
        atHostTime releaseHostTime: UInt64
    ) -> Bool {
        lock.withLock {
            guard activeOwner == owner else { return false }
            _releaseHostTimes.append(releaseHostTime)
            _recordingBoundaryIsOpen = false
            return true
        }
    }

    public var audioLevelStream: AsyncStream<Float>? {
        lock.withLock { _audioLevelStream }
    }

    public var peakRMS: Float {
        lock.withLock { stubbedPeakRMS }
    }

    public var ambientRMS: Float {
        lock.withLock { stubbedAmbientRMS }
    }

    public var micProximity: MicProximity {
        lock.withLock { stubbedMicProximity }
    }

    public func stopRecording() async throws -> AudioBuffer {
        guard let owner = lock.withLock({ legacyOwner }) else { return .empty }
        let buffer = try await stopRecording(owner: owner)
        lock.withLock {
            if legacyOwner == owner { legacyOwner = nil }
        }
        return buffer
    }

    public func stopRecording(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        let operation: StopOperation = try lock.withLock {
            if let operation = stopOperation {
                guard operation.owner == owner else {
                    throw AudioCaptureError.ownerMismatch
                }
                return operation
            }
            guard activeOwner == owner else {
                throw AudioCaptureError.ownerMismatch
            }
            let id = UUID()
            let hook = stopWillComplete
            let operation = StopOperation(id: id, owner: owner, hook: hook)
            stopOperation = operation
            return operation
        }

        return try await operation.result(from: self).get()
    }

    private func finishStop(
        owner: AudioCaptureOwner,
        operationID: UUID
    ) -> Result<AudioBuffer, any Error> {
        lock.withLock {
            guard activeOwner == owner else {
                return .failure(AudioCaptureError.ownerMismatch)
            }
            activeOwner = nil
            _isRecording = false
            _recordingBoundaryIsOpen = false
            _stopCallCount += 1
            pcmContinuation?.finish()
            pcmContinuation = nil
            _pcmAudioStream = nil
            levelContinuation?.finish()
            levelContinuation = nil
            _audioLevelStream = nil
            if stopOperation?.id == operationID {
                completedStopOperationID = operationID
            }
            return .success(
                captureConfiguration.retainsPCM ? stubbedBuffer : .empty)
        }
    }

    public func forceReset() {
        guard let owner = lock.withLock({ legacyOwner ?? activeOwner ?? startingOwner })
        else { return }
        _ = forceReset(owner: owner)
    }

    @discardableResult
    public func forceReset(owner: AudioCaptureOwner) -> Bool {
        lock.withLock {
            guard activeOwner == owner || startingOwner == owner else {
                return false
            }
            resetGeneration &+= 1
            if activeOwner == owner { activeOwner = nil }
            if startingOwner == owner { startingOwner = nil }
            if metricsOwner == owner { metricsOwner = nil }
            if legacyOwner == owner { legacyOwner = nil }
            if stopOperation?.owner == owner {
                stopOperation = nil
                completedStopOperationID = nil
            }
            _isRecording = false
            _recordingBoundaryIsOpen = false
            pcmContinuation?.finish()
            pcmContinuation = nil
            _pcmAudioStream = nil
            levelContinuation?.finish()
            levelContinuation = nil
            _audioLevelStream = nil
            return true
        }
    }
}
