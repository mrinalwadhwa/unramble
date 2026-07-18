import XCTest

@testable import UnrambleKit

private final class RecordingLimitSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var _requestedDurations: [Duration] = []
    private var _observedCancellation: Bool?

    var callCount: Int {
        lock.withLock { _requestedDurations.count }
    }

    var requestedDurations: [Duration] {
        lock.withLock { _requestedDurations }
    }

    var observedCancellation: Bool? {
        lock.withLock { _observedCancellation }
    }

    func sleep(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                _requestedDurations.append(duration)
                if released { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
        lock.withLock {
            _observedCancellation = Task.isCancelled
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class MultiRecordingLimitSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var durations: [Duration] = []
    private var cancellations: [Int: Bool] = [:]

    var callCount: Int {
        lock.withLock { durations.count }
    }

    func observedCancellation(for call: Int) -> Bool? {
        lock.withLock { cancellations[call] }
    }

    func sleep(for duration: Duration) async {
        let call = lock.withLock {
            let call = durations.count
            durations.append(duration)
            return call
        }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if released.contains(call) { return true }
                continuations[call] = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
        lock.withLock {
            cancellations[call] = Task.isCancelled
        }
    }

    func release(call: Int) {
        let continuation = lock.withLock {
            released.insert(call)
            return continuations.removeValue(forKey: call)
        }
        continuation?.resume()
    }
}

private actor RecordingLimitClaimGate {
    private var claimed = false
    private var released = false
    private var observedCancellation: Bool?
    private var claimWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseAfterClaim() async {
        claimed = true
        let waiters = claimWaiters
        claimWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        observedCancellation = Task.isCancelled
    }

    func waitUntilClaimed() async {
        guard !claimed else { return }
        await withCheckedContinuation { continuation in
            claimWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func cancellationObserved() -> Bool? {
        observedCancellation
    }
}

private actor AsyncCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func hasCompleted() -> Bool {
        completed
    }
}

private final class CompletionWaitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false

    var hasWaiter: Bool {
        lock.withLock { waiting }
    }

    func markWaiting() {
        lock.withLock { waiting = true }
    }
}

private actor SuspensionGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor CancellationInsensitiveFirstContextProvider: AppContextProviding {
    private var readCount = 0
    private var firstReadEntered = false
    private var firstReadReleased = false
    private var cancellationObserved = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func readContext() async -> AppContext {
        readCount += 1
        guard readCount == 1 else { return .stub }

        firstReadEntered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        waitingForEntry.forEach { $0.resume() }

        await withTaskCancellationHandler {
            if !firstReadReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        return .stub
    }

    func waitUntilFirstReadEnters() async {
        guard !firstReadEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func waitUntilCancellationIsObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func releaseFirstRead() {
        guard !firstReadReleased else { return }
        firstReadReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }

    private func recordCancellation() {
        guard !cancellationObserved else { return }
        cancellationObserved = true
        let waitingForCancellation = cancellationWaiters
        cancellationWaiters.removeAll()
        waitingForCancellation.forEach { $0.resume() }
    }
}

private final class CooperativeFirstContextProvider: AppContextProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var firstReadContinuation: CheckedContinuation<Void, Never>?
    private var firstReadReleased = false
    private var _readCount = 0
    private var _firstReadEntered = false
    private var _firstReadCancelled = false

    var readCount: Int { lock.withLock { _readCount } }
    var firstReadEntered: Bool { lock.withLock { _firstReadEntered } }
    var firstReadCancelled: Bool { lock.withLock { _firstReadCancelled } }

    func readContext() async -> AppContext {
        let call = lock.withLock {
            _readCount += 1
            return _readCount
        }
        guard call == 1 else { return .stub }

        lock.withLock { _firstReadEntered = true }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    guard !firstReadReleased else { return true }
                    firstReadContinuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            self.cancelFirstRead()
        }
        return .stub
    }

    func releaseFirstRead() {
        resumeFirstRead(cancelled: false)
    }

    private func cancelFirstRead() {
        resumeFirstRead(cancelled: true)
    }

    private func resumeFirstRead(cancelled: Bool) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !firstReadReleased else { return nil }
            firstReadReleased = true
            _firstReadCancelled = cancelled
            let continuation = firstReadContinuation
            firstReadContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private actor CancellationInsensitiveSecondContextProvider: AppContextProviding {
    private var readCount = 0
    private var secondReadEntered = false
    private var secondReadReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func readContext() async -> AppContext {
        readCount += 1
        guard readCount == 2 else { return .stub }

        secondReadEntered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        waitingForEntry.forEach { $0.resume() }

        if !secondReadReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return .stub
    }

    func waitUntilSecondReadEnters() async {
        guard !secondReadEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func releaseSecondRead() {
        guard !secondReadReleased else { return }
        secondReadReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private final class GatedStartAudioProvider: AudioProviding, @unchecked Sendable {
    private let base = MockAudioProvider()
    private let startGate: SuspensionGate
    private let resetLock = NSLock()
    private var resetGeneration: UInt64 = 0
    private var currentOwner: AudioCaptureOwner?

    init(startGate: SuspensionGate, enablePCMStream: Bool = false) {
        self.startGate = startGate
        base.enablePCMStream = enablePCMStream
    }

    var isRecording: Bool { base.isRecording }
    var pcmAudioStream: AsyncStream<Data>? { base.pcmAudioStream }
    var audioLevelStream: AsyncStream<Float>? { base.audioLevelStream }
    var peakRMS: Float { base.peakRMS }
    var ambientRMS: Float { base.ambientRMS }
    var micProximity: MicProximity { base.micProximity }
    var gainFactor: Float { base.gainFactor }
    var deviceName: String { base.deviceName }
    func isRecording(owner: AudioCaptureOwner) -> Bool {
        base.isRecording(owner: owner)
    }
    func pcmAudioStream(owner: AudioCaptureOwner) -> AsyncStream<Data>? {
        base.pcmAudioStream(owner: owner)
    }
    func audioLevelStream(owner: AudioCaptureOwner) -> AsyncStream<Float>? {
        base.audioLevelStream(owner: owner)
    }
    func metrics(owner: AudioCaptureOwner) -> AudioCaptureMetrics? {
        base.metrics(owner: owner)
    }
    func startRecording() async throws {
        try await startRecording(onCaptureReady: {})
    }

    func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let generation = resetLock.withLock { resetGeneration }
        await startGate.waitForRelease()
        try await base.startRecording(onCaptureReady: {
            self.resetLock.withLock {
                guard self.resetGeneration == generation else { return }
                onCaptureReady()
            }
        })
        guard resetLock.withLock({ resetGeneration == generation }) else {
            base.forceReset()
            throw CancellationError()
        }
    }

    func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let generation: UInt64 = try resetLock.withLock {
            guard currentOwner == nil else {
                throw AudioCaptureError.alreadyRecording
            }
            currentOwner = owner
            return resetGeneration
        }
        await startGate.waitForRelease()
        do {
            try await base.startRecording(
                owner: owner,
                configuration: configuration,
                releaseBoundary: releaseBoundary,
                onCaptureReady: {
                    self.resetLock.withLock {
                        guard self.currentOwner == owner,
                            self.resetGeneration == generation
                        else { return }
                        onCaptureReady()
                    }
                })
        } catch {
            resetLock.withLock {
                if currentOwner == owner { currentOwner = nil }
            }
            throw error
        }
        guard resetLock.withLock({
            currentOwner == owner && resetGeneration == generation
        }) else {
            base.forceReset(owner: owner)
            throw CancellationError()
        }
    }

    func stopRecording() async throws -> AudioBuffer {
        try await base.stopRecording()
    }

    func closeRecordingBoundary() {
        base.closeRecordingBoundary()
    }

    func forceReset() {
        resetLock.withLock { resetGeneration &+= 1 }
        base.forceReset()
        Task { await startGate.release() }
    }

    func stopRecording(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        let buffer = try await base.stopRecording(owner: owner)
        resetLock.withLock {
            if currentOwner == owner { currentOwner = nil }
        }
        return buffer
    }

    @discardableResult
    func closeRecordingBoundary(owner: AudioCaptureOwner) -> Bool {
        base.closeRecordingBoundary(owner: owner)
    }

    @discardableResult
    func closeRecordingBoundary(
        owner: AudioCaptureOwner,
        atHostTime releaseHostTime: UInt64
    ) -> Bool {
        base.closeRecordingBoundary(owner: owner, atHostTime: releaseHostTime)
    }

    @discardableResult
    func forceReset(owner: AudioCaptureOwner) -> Bool {
        let ownsStart = resetLock.withLock { () -> Bool in
            guard currentOwner == owner else { return false }
            resetGeneration &+= 1
            currentOwner = nil
            return true
        }
        guard ownsStart else { return false }
        _ = base.forceReset(owner: owner)
        Task { await startGate.release() }
        return true
    }
}

private final class StartReturnGatedAudioProvider: AudioProviding, @unchecked Sendable {
    private let base = MockAudioProvider()
    private let startGate: SuspensionGate
    private let initialPCMChunk: Data

    init(startGate: SuspensionGate, initialPCMChunk: Data) {
        self.startGate = startGate
        self.initialPCMChunk = initialPCMChunk
        base.enablePCMStream = true
    }

    var isRecording: Bool { base.isRecording }
    var pcmAudioStream: AsyncStream<Data>? { base.pcmAudioStream }
    var peakRMS: Float { base.peakRMS }
    var ambientRMS: Float { base.ambientRMS }
    var micProximity: MicProximity { base.micProximity }
    func isRecording(owner: AudioCaptureOwner) -> Bool {
        base.isRecording(owner: owner)
    }
    func pcmAudioStream(owner: AudioCaptureOwner) -> AsyncStream<Data>? {
        base.pcmAudioStream(owner: owner)
    }
    func audioLevelStream(owner: AudioCaptureOwner) -> AsyncStream<Float>? {
        base.audioLevelStream(owner: owner)
    }
    func metrics(owner: AudioCaptureOwner) -> AudioCaptureMetrics? {
        base.metrics(owner: owner)
    }

    func startRecording() async throws {
        try await startRecording(onCaptureReady: {})
    }

    func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await base.startRecording(onCaptureReady: onCaptureReady)
        base.emitPCMChunk(initialPCMChunk)
        await startGate.waitForRelease()
    }

    func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await base.startRecording(
            owner: owner,
            configuration: configuration,
            releaseBoundary: releaseBoundary,
            onCaptureReady: onCaptureReady)
        base.emitPCMChunk(initialPCMChunk)
        await startGate.waitForRelease()
    }

    func stopRecording() async throws -> AudioBuffer {
        let buffer = try await base.stopRecording()
        await startGate.release()
        return buffer
    }

    func closeRecordingBoundary() {
        base.closeRecordingBoundary()
    }

    func forceReset() {
        base.forceReset()
        Task { await startGate.release() }
    }

    func stopRecording(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        let buffer = try await base.stopRecording(owner: owner)
        await startGate.release()
        return buffer
    }

    @discardableResult
    func closeRecordingBoundary(owner: AudioCaptureOwner) -> Bool {
        base.closeRecordingBoundary(owner: owner)
    }

    @discardableResult
    func closeRecordingBoundary(
        owner: AudioCaptureOwner,
        atHostTime releaseHostTime: UInt64
    ) -> Bool {
        base.closeRecordingBoundary(owner: owner, atHostTime: releaseHostTime)
    }

    @discardableResult
    func forceReset(owner: AudioCaptureOwner) -> Bool {
        let reset = base.forceReset(owner: owner)
        if reset { Task { await startGate.release() } }
        return reset
    }
}

private final class StopGatedAudioProvider: AudioProviding, @unchecked Sendable {
    private let stopGate = SuspensionGate()
    private let startReturnGate: SuspensionGate?
    private let stopFails: Bool
    private let lock = NSLock()
    private var _isRecording = false
    private var _isHardwareRunning = false
    private var _captureBoundaryOpen = false
    private var _stopAttemptCount = 0
    private var _completedStopCount = 0
    private var _forceResetCount = 0
    private var _startCancellationCount = 0
    private var _captureReadyCount = 0
    private var activeOwner: AudioCaptureOwner?
    private var metricsOwner: AudioCaptureOwner?
    private var chunks: [Data] = []
    private var stream: AsyncStream<Data>?
    private var continuation: AsyncStream<Data>.Continuation?

    init(
        startReturnGate: SuspensionGate? = nil,
        stopFails: Bool = false
    ) {
        self.startReturnGate = startReturnGate
        self.stopFails = stopFails
    }

    var isRecording: Bool { lock.withLock { _isRecording } }
    var isHardwareRunning: Bool { lock.withLock { _isHardwareRunning } }
    var pcmAudioStream: AsyncStream<Data>? { lock.withLock { stream } }
    var audioLevelStream: AsyncStream<Float>? { nil }
    var peakRMS: Float { 0.1 }
    var ambientRMS: Float { 0 }
    var micProximity: MicProximity { .nearField }
    var gainFactor: Float { 1 }
    var deviceName: String { "Controlled capture" }
    var stopAttemptCount: Int { lock.withLock { _stopAttemptCount } }
    var completedStopCount: Int { lock.withLock { _completedStopCount } }
    var forceResetCount: Int { lock.withLock { _forceResetCount } }
    var startCancellationCount: Int { lock.withLock { _startCancellationCount } }
    var captureReadyCount: Int { lock.withLock { _captureReadyCount } }
    func isRecording(owner: AudioCaptureOwner) -> Bool {
        lock.withLock { activeOwner == owner && _isRecording }
    }
    func pcmAudioStream(owner: AudioCaptureOwner) -> AsyncStream<Data>? {
        lock.withLock { activeOwner == owner ? stream : nil }
    }
    func audioLevelStream(owner: AudioCaptureOwner) -> AsyncStream<Float>? { nil }
    func metrics(owner: AudioCaptureOwner) -> AudioCaptureMetrics? {
        lock.withLock {
            guard metricsOwner == owner else { return nil }
            return AudioCaptureMetrics(
                peakRMS: 0.1,
                ambientRMS: 0,
                micProximity: .nearField,
                gainFactor: 1,
                deviceName: "Controlled capture")
        }
    }

    func startRecording() async throws {
        try await startRecording(onCaptureReady: {})
    }

    func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await startRecordingOwned(owner: nil, onCaptureReady: onCaptureReady)
    }

    func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await startRecordingOwned(owner: owner, onCaptureReady: onCaptureReady)
    }

    private func startRecordingOwned(
        owner: AudioCaptureOwner?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let (newStream, newContinuation) = AsyncStream<Data>.makeStream()
        try lock.withLock {
            guard !_isRecording, activeOwner == nil else {
                throw AudioCaptureError.alreadyRecording
            }
            activeOwner = owner
            metricsOwner = owner
            _isRecording = true
            _isHardwareRunning = true
            _captureBoundaryOpen = true
            chunks = []
            stream = newStream
            continuation = newContinuation
        }
        onCaptureReady()
        lock.withLock { _captureReadyCount += 1 }
        if let startReturnGate {
            await withTaskCancellationHandler {
                await startReturnGate.waitForRelease()
            } onCancel: {
                self.lock.withLock { self._startCancellationCount += 1 }
            }
        }
    }

    @discardableResult
    func emitPCMChunk(_ data: Data) -> Bool {
        let continuation: AsyncStream<Data>.Continuation? = lock.withLock {
            guard _captureBoundaryOpen else { return nil }
            chunks.append(data)
            return self.continuation
        }
        continuation?.yield(data)
        return continuation != nil
    }

    func closeRecordingBoundary() {
        lock.withLock {
            _captureBoundaryOpen = false
            _isRecording = false
        }
    }

    func stopRecording() async throws -> AudioBuffer {
        try await stopRecordingOwned(owner: nil)
    }

    func stopRecording(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        try await stopRecordingOwned(owner: owner)
    }

    private func stopRecordingOwned(
        owner: AudioCaptureOwner?
    ) async throws -> AudioBuffer {
        try lock.withLock {
            if let owner, activeOwner != owner {
                throw AudioCaptureError.ownerMismatch
            }
        }
        lock.withLock { _stopAttemptCount += 1 }
        await stopGate.waitForRelease()
        if stopFails {
            throw ControlledCaptureError.stopFailed
        }
        let pcmData: Data = lock.withLock {
            _isRecording = false
            _isHardwareRunning = false
            _captureBoundaryOpen = false
            activeOwner = nil
            _completedStopCount += 1
            continuation?.finish()
            continuation = nil
            stream = nil
            return chunks.reduce(into: Data()) { $0.append($1) }
        }
        guard !pcmData.isEmpty else { return .empty }
        return AudioBuffer(
            data: WAVEncoder.encode(
                pcmData: pcmData,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16),
            duration: WAVEncoder.duration(
                byteCount: pcmData.count,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16),
            sampleRate: 16_000,
            channels: 1,
            bitsPerSample: 16)
    }

    func forceReset() {
        forceResetOwned(owner: nil)
    }

    @discardableResult
    func forceReset(owner: AudioCaptureOwner) -> Bool {
        forceResetOwned(owner: owner)
    }

    @discardableResult
    private func forceResetOwned(owner: AudioCaptureOwner?) -> Bool {
        lock.withLock {
            if let owner, activeOwner != owner { return false }
            _forceResetCount += 1
            _isRecording = false
            _isHardwareRunning = false
            _captureBoundaryOpen = false
            continuation?.finish()
            continuation = nil
            stream = nil
            chunks = []
            activeOwner = nil
            if metricsOwner == owner || owner == nil { metricsOwner = nil }
            return true
        }
    }

    @discardableResult
    func closeRecordingBoundary(owner: AudioCaptureOwner) -> Bool {
        lock.withLock {
            guard activeOwner == owner else { return false }
            _captureBoundaryOpen = false
            _isRecording = false
            return true
        }
    }

    @discardableResult
    func closeRecordingBoundary(
        owner: AudioCaptureOwner,
        atHostTime releaseHostTime: UInt64
    ) -> Bool {
        closeRecordingBoundary(owner: owner)
    }

    func waitUntilStopStarts() async {
        await stopGate.waitUntilEntered()
    }

    func releaseStop() async {
        await stopGate.release()
    }

    func releaseStartReturn() async {
        await startReturnGate?.release()
    }
}

private enum ControlledCaptureError: Error {
    case stopFailed
}

private final class CaptureStopSelectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var selected = false

    func record(_ selected: Bool) {
        lock.withLock { self.selected = selected }
    }

    var value: Bool { lock.withLock { selected } }
}

/// Models a slow audio start whose capture becomes live only after the user
/// has released the dictation key. The emitted PCM is therefore outside the
/// accepted capture interval and must never become a transcript candidate.
private final class PostReleaseStartAudioProvider: AudioProviding, @unchecked Sendable {
    private let base = MockAudioProvider()
    private let startGate: SuspensionGate
    private let postReleasePCM: Data
    private let retainsPreviewPreRoll: Bool
    private let stopFails: Bool
    private let resetLock = NSLock()
    private var resetGeneration: UInt64 = 0
    private var currentOwner: AudioCaptureOwner?
    private var _stopAttemptCount = 0

    init(
        startGate: SuspensionGate,
        postReleasePCM: Data,
        retainsPreviewPreRoll: Bool = false,
        stopFails: Bool = false
    ) {
        self.startGate = startGate
        self.postReleasePCM = postReleasePCM
        self.retainsPreviewPreRoll = retainsPreviewPreRoll
        self.stopFails = stopFails
        base.enablePCMStream = true
        if !retainsPreviewPreRoll {
            base.stubbedBuffer = .empty
        }
    }

    var isRecording: Bool { base.isRecording }
    var pcmAudioStream: AsyncStream<Data>? { base.pcmAudioStream }
    var peakRMS: Float { base.peakRMS }
    var ambientRMS: Float { base.ambientRMS }
    var micProximity: MicProximity { base.micProximity }
    var startCallCount: Int { base.startCallCount }
    var stopCallCount: Int { base.stopCallCount }
    var stopAttemptCount: Int { resetLock.withLock { _stopAttemptCount } }
    var releaseHostTimes: [UInt64] { base.releaseHostTimes }
    func isRecording(owner: AudioCaptureOwner) -> Bool {
        base.isRecording(owner: owner)
    }
    func pcmAudioStream(owner: AudioCaptureOwner) -> AsyncStream<Data>? {
        base.pcmAudioStream(owner: owner)
    }
    func audioLevelStream(owner: AudioCaptureOwner) -> AsyncStream<Float>? {
        base.audioLevelStream(owner: owner)
    }
    func metrics(owner: AudioCaptureOwner) -> AudioCaptureMetrics? {
        base.metrics(owner: owner)
    }
    func canRecoverCaptureReleasedBeforeReadiness(
        owner: AudioCaptureOwner,
        pressHostTime: UInt64
    ) -> Bool {
        retainsPreviewPreRoll
    }

    func startRecording() async throws {
        try await startRecording(onCaptureReady: {})
    }

    func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let generation = resetLock.withLock { resetGeneration }
        await startGate.waitForRelease()
        try await base.startRecording(onCaptureReady: {
            self.resetLock.withLock {
                guard self.resetGeneration == generation else { return }
                onCaptureReady()
            }
        })
        guard resetLock.withLock({ resetGeneration == generation }) else {
            base.forceReset()
            throw CancellationError()
        }
        if retainsPreviewPreRoll {
            base.emitPCMChunk(postReleasePCM)
        }
    }

    func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        let generation: UInt64 = try resetLock.withLock {
            guard currentOwner == nil else {
                throw AudioCaptureError.alreadyRecording
            }
            currentOwner = owner
            return resetGeneration
        }
        await startGate.waitForRelease()
        do {
            try await base.startRecording(
                owner: owner,
                configuration: configuration,
                releaseBoundary: releaseBoundary,
                onCaptureReady: {
                    self.resetLock.withLock {
                        guard self.currentOwner == owner,
                            self.resetGeneration == generation
                        else { return }
                        onCaptureReady()
                    }
                })
        } catch {
            resetLock.withLock {
                if currentOwner == owner { currentOwner = nil }
            }
            throw error
        }
        guard resetLock.withLock({
            currentOwner == owner && resetGeneration == generation
        }) else {
            base.forceReset(owner: owner)
            throw CancellationError()
        }
        if retainsPreviewPreRoll {
            base.emitPCMChunk(postReleasePCM)
        }
    }

    func stopRecording() async throws -> AudioBuffer {
        try await base.stopRecording()
    }

    func closeRecordingBoundary() {
        base.closeRecordingBoundary()
    }

    func forceReset() {
        resetLock.withLock { resetGeneration &+= 1 }
        base.forceReset()
        Task { await startGate.release() }
    }

    func stopRecording(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        let shouldFail = resetLock.withLock {
            _stopAttemptCount += 1
            return stopFails
        }
        if shouldFail {
            throw ControlledCaptureError.stopFailed
        }
        let buffer = try await base.stopRecording(owner: owner)
        resetLock.withLock {
            if currentOwner == owner { currentOwner = nil }
        }
        return buffer
    }

    @discardableResult
    func closeRecordingBoundary(owner: AudioCaptureOwner) -> Bool {
        base.closeRecordingBoundary(owner: owner)
    }

    @discardableResult
    func closeRecordingBoundary(
        owner: AudioCaptureOwner,
        atHostTime releaseHostTime: UInt64
    ) -> Bool {
        base.closeRecordingBoundary(owner: owner, atHostTime: releaseHostTime)
    }

    @discardableResult
    func forceReset(owner: AudioCaptureOwner) -> Bool {
        let ownsStart = resetLock.withLock { () -> Bool in
            guard currentOwner == owner else { return false }
            resetGeneration &+= 1
            currentOwner = nil
            return true
        }
        guard ownsStart else { return false }
        _ = base.forceReset(owner: owner)
        Task { await startGate.release() }
        return true
    }
}

/// Publishes capture readiness while the recovery capability query is in
/// flight, matching preview promotion clearing its one-shot proof immediately
/// after `onCaptureReady` runs.
private final class RecoveryQueryReadinessAudioProvider: AudioProviding,
    @unchecked Sendable
{
    private let base = MockAudioProvider()
    private let startReturnGate = SuspensionGate()
    private let lock = NSLock()
    private var captureReady: (@Sendable () -> Void)?

    init() {
        base.enablePCMStream = true
    }

    var isRecording: Bool { base.isRecording }
    var pcmAudioStream: AsyncStream<Data>? { base.pcmAudioStream }
    var peakRMS: Float { base.peakRMS }
    var ambientRMS: Float { base.ambientRMS }
    var micProximity: MicProximity { base.micProximity }

    func isRecording(owner: AudioCaptureOwner) -> Bool {
        base.isRecording(owner: owner)
    }

    func pcmAudioStream(owner: AudioCaptureOwner) -> AsyncStream<Data>? {
        base.pcmAudioStream(owner: owner)
    }

    func audioLevelStream(owner: AudioCaptureOwner) -> AsyncStream<Float>? {
        base.audioLevelStream(owner: owner)
    }

    func metrics(owner: AudioCaptureOwner) -> AudioCaptureMetrics? {
        base.metrics(owner: owner)
    }

    func canRecoverCaptureReleasedBeforeReadiness(
        owner: AudioCaptureOwner,
        pressHostTime: UInt64
    ) -> Bool {
        let callback = lock.withLock {
            let callback = captureReady
            captureReady = nil
            return callback
        }
        callback?()
        Task { await startReturnGate.release() }
        return false
    }

    func startRecording() async throws {
        try await base.startRecording()
    }

    func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await base.startRecording(onCaptureReady: onCaptureReady)
    }

    func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try await base.startRecording(
            owner: owner,
            configuration: configuration,
            releaseBoundary: releaseBoundary,
            onCaptureReady: {})
        lock.withLock { captureReady = onCaptureReady }
        await startReturnGate.waitForRelease()
    }

    func closeRecordingBoundary() {
        base.closeRecordingBoundary()
    }

    @discardableResult
    func closeRecordingBoundary(owner: AudioCaptureOwner) -> Bool {
        base.closeRecordingBoundary(owner: owner)
    }

    @discardableResult
    func closeRecordingBoundary(
        owner: AudioCaptureOwner,
        atHostTime releaseHostTime: UInt64
    ) -> Bool {
        base.closeRecordingBoundary(
            owner: owner,
            atHostTime: releaseHostTime)
    }

    func stopRecording() async throws -> AudioBuffer {
        try await base.stopRecording()
    }

    func stopRecording(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        try await base.stopRecording(owner: owner)
    }

    func forceReset() {
        base.forceReset()
        Task { await startReturnGate.release() }
    }

    @discardableResult
    func forceReset(owner: AudioCaptureOwner) -> Bool {
        let reset = base.forceReset(owner: owner)
        Task { await startReturnGate.release() }
        return reset
    }

    func waitUntilStartEnters() async {
        await startReturnGate.waitUntilEntered()
    }
}

private final class BlockingStartStatusAudioProvider: AudioProviding,
    @unchecked Sendable
{
    private let base = MockAudioProvider()
    private let startGate = SuspensionGate()
    private let stateLock = NSLock()
    private let statusCondition = NSCondition()
    private var resetRequested = false
    private var statusReleased = false
    private var _statusReadCount = 0
    private var _forceResetCount = 0
    private var currentOwner: AudioCaptureOwner?

    init() {
        base.enablePCMStream = true
    }

    var statusReadCount: Int { stateLock.withLock { _statusReadCount } }
    var forceResetCount: Int { stateLock.withLock { _forceResetCount } }
    var pcmAudioStream: AsyncStream<Data>? { base.pcmAudioStream }
    var peakRMS: Float { base.peakRMS }
    var ambientRMS: Float { base.ambientRMS }
    var micProximity: MicProximity { base.micProximity }
    func isRecording(owner: AudioCaptureOwner) -> Bool {
        base.isRecording(owner: owner)
    }
    func pcmAudioStream(owner: AudioCaptureOwner) -> AsyncStream<Data>? {
        base.pcmAudioStream(owner: owner)
    }
    func audioLevelStream(owner: AudioCaptureOwner) -> AsyncStream<Float>? {
        base.audioLevelStream(owner: owner)
    }
    func metrics(owner: AudioCaptureOwner) -> AudioCaptureMetrics? {
        base.metrics(owner: owner)
    }

    var isRecording: Bool {
        stateLock.withLock { _statusReadCount += 1 }
        statusCondition.lock()
        while !statusReleased {
            statusCondition.wait()
        }
        statusCondition.unlock()
        return base.isRecording
    }

    func startRecording() async throws {
        try await startRecording(onCaptureReady: {})
    }

    func startRecording(
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        await startGate.waitForRelease()
        let wasReset = stateLock.withLock { resetRequested }
        guard !wasReset else { throw CancellationError() }
        try await base.startRecording(onCaptureReady: onCaptureReady)
    }

    func startRecording(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration,
        releaseBoundary: AudioCaptureReleaseBoundary?,
        onCaptureReady: @escaping @Sendable () -> Void
    ) async throws {
        try stateLock.withLock {
            guard currentOwner == nil else {
                throw AudioCaptureError.alreadyRecording
            }
            currentOwner = owner
        }
        await startGate.waitForRelease()
        let wasReset = stateLock.withLock { resetRequested }
        guard !wasReset else { throw CancellationError() }
        do {
            try await base.startRecording(
                owner: owner,
                configuration: configuration,
                releaseBoundary: releaseBoundary,
                onCaptureReady: onCaptureReady)
        } catch {
            stateLock.withLock {
                if currentOwner == owner { currentOwner = nil }
            }
            throw error
        }
    }

    func stopRecording() async throws -> AudioBuffer {
        try await base.stopRecording()
    }

    func closeRecordingBoundary() {
        base.closeRecordingBoundary()
    }

    func forceReset() {
        stateLock.withLock {
            resetRequested = true
            _forceResetCount += 1
        }
        base.forceReset()
        Task { await startGate.release() }
    }

    func stopRecording(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        let buffer = try await base.stopRecording(owner: owner)
        stateLock.withLock {
            if currentOwner == owner { currentOwner = nil }
        }
        return buffer
    }

    @discardableResult
    func closeRecordingBoundary(owner: AudioCaptureOwner) -> Bool {
        base.closeRecordingBoundary(owner: owner)
    }

    @discardableResult
    func closeRecordingBoundary(
        owner: AudioCaptureOwner,
        atHostTime releaseHostTime: UInt64
    ) -> Bool {
        base.closeRecordingBoundary(owner: owner, atHostTime: releaseHostTime)
    }

    @discardableResult
    func forceReset(owner: AudioCaptureOwner) -> Bool {
        let ownsStart = stateLock.withLock { () -> Bool in
            guard currentOwner == owner else { return false }
            resetRequested = true
            _forceResetCount += 1
            currentOwner = nil
            return true
        }
        guard ownsStart else { return false }
        _ = base.forceReset(owner: owner)
        Task { await startGate.release() }
        return true
    }

    func waitUntilStartEnters() async {
        await startGate.waitUntilEntered()
    }

    func releaseForCleanup() async {
        releaseStatusRead()
        await startGate.release()
    }

    private func releaseStatusRead() {
        statusCondition.lock()
        statusReleased = true
        statusCondition.broadcast()
        statusCondition.unlock()
    }
}

final class StreamingPipelineTests: XCTestCase {

    // MARK: - Helpers

    /// Build a MockAudioProvider that supports PCM streaming by default.
    private func makeStreamingAudioProvider() -> MockAudioProvider {
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        return audio
    }

    /// Build raw 16-bit PCM data with alternating ±3000 samples.
    private func makeNonSilentPCMChunk(sampleCount: Int = 1600) -> Data {
        var data = Data(capacity: sampleCount * 2)
        for i in 0..<sampleCount {
            let sample: Int16 = i % 2 == 0 ? 3000 : -3000
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func makeSparseAudibleBuffer() -> AudioBuffer {
        let sampleRate = 16_000
        let sampleCount = sampleRate * 4
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let sample: Int16 = index < 160
                ? (index.isMultiple(of: 2) ? 3_000 : -3_000)
                : 0
            withUnsafeBytes(of: sample.littleEndian) {
                pcm.append(contentsOf: $0)
            }
        }
        return AudioBuffer(
            data: WAVEncoder.encode(
                pcmData: pcm,
                sampleRate: sampleRate,
                channels: 1,
                bitsPerSample: 16),
            duration: 4,
            sampleRate: sampleRate,
            channels: 1,
            bitsPerSample: 16)
    }

    /// Build a batch mock with a delay. Used as the default dictation
    /// provider in test pipelines where batch is not the focus.
    private func makeSlowBatchProvider() -> MockBatchProvider {
        let batch = MockBatchProvider()
        batch.stubbedDelay = 5.0
        return batch
    }

    private func makeStreamingPipeline(
        audioProvider: MockAudioProvider? = nil,
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        batchProvider: MockBatchProvider? = nil,
        streamingProvider: MockStreamingProvider = MockStreamingProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        transcriptBuffer: TranscriptBuffer? = nil,
        micDiagnosticStore: MicDiagnosticStore? = nil,
        localMode: Bool = false,
        onSessionExpired: (@Sendable () -> Void)? = nil,
        cloudRecordingLimitSleep: @escaping @Sendable (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        }
    ) -> (
        DictationPipeline, MockAudioProvider, MockAppContextProvider,
        MockBatchProvider, MockStreamingProvider,
        MockTextInjector, RecordingCoordinator
    ) {
        let audio = audioProvider ?? makeStreamingAudioProvider()
        let dictation = batchProvider ?? makeSlowBatchProvider()
        let backend: DictationBackend = localMode
            ? .local(streaming: streamingProvider)
            : .cloud(realtime: streamingProvider, fallback: dictation)
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: contextProvider,
            backend: backend,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            onSessionExpired: onSessionExpired,
            micDiagnosticStore: micDiagnosticStore,
            cloudRecordingLimitSleep: cloudRecordingLimitSleep
        )
        return (
            pipeline, audio, contextProvider, dictation,
            streamingProvider, textInjector, coordinator
        )
    }

    // MARK: - Cloud recording limit

    func testActivationSnapshotsLanguageBeforeAsyncSetup() async {
        let setupGate = SuspensionGate()
        let audio = GatedStartAudioProvider(
            startGate: setupGate,
            enablePCMStream: true)
        let streaming = MockStreamingProvider()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator)

        await pipeline.setLanguage("en")
        await pipeline.activate()
        await setupGate.waitUntilEntered()

        await pipeline.setLanguage("fr")
        await setupGate.release()

        let setupFinished = await waitUntil {
            streaming.startCallCount == 1
        }
        XCTAssertTrue(setupFinished)
        XCTAssertEqual(streaming.receivedLanguages, ["en"])

        await pipeline.cancel()
    }

    func testConcurrentActivationsAdmitExactlyOneSession() async {
        for _ in 0..<25 {
            let (pipeline, audio, _, _, _, _, coordinator) =
                makeStreamingPipeline()

            let first = Task { await pipeline.activate() }
            let second = Task { await pipeline.activate() }
            let accepted = await [first.value, second.value].compactMap { $0 }
            let currentSessionID = await pipeline.currentSessionID
            let currentState = await coordinator.state

            XCTAssertEqual(accepted.count, 1)
            XCTAssertEqual(currentSessionID, accepted.first)
            XCTAssertEqual(currentState, .recording)

            let captureStarted = await waitUntil {
                audio.startCallCount == 1
            }
            XCTAssertTrue(captureStarted)
            XCTAssertEqual(audio.startCallCount, 1)

            if let sessionID = accepted.first {
                await pipeline.cancel(sessionID: sessionID)
            }
        }
    }

    func testCancelDuringReservedActivationPreventsCaptureAdmission() async {
        let admissionGate = SuspensionGate()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            activationDidReserve: {
                await admissionGate.waitForRelease()
            })

        let activationTask = Task { await pipeline.activate() }
        await admissionGate.waitUntilEntered()

        await pipeline.cancel()
        let stateAfterCancel = await coordinator.state
        XCTAssertEqual(audio.startCallCount, 0)
        XCTAssertEqual(streaming.cancelCallCount, 0)
        XCTAssertEqual(stateAfterCancel, .idle)

        await admissionGate.release()
        let acceptedSession = await activationTask.value
        let currentSessionID = await pipeline.currentSessionID
        let finalState = await coordinator.state

        XCTAssertNil(acceptedSession)
        XCTAssertNil(currentSessionID)
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(audio.startCallCount, 0)
        XCTAssertEqual(streaming.startCallCount, 0)
    }

    func testCompleteAlreadyCancelledBeforeEntryDrainsRecording() async {
        let entryGate = SuspensionGate()
        let (pipeline, audio, _, dictation, streaming, injector, coordinator) =
            makeStreamingPipeline()

        await pipeline.activate()
        let recordingStarted = await waitUntil { audio.startCallCount == 1 }
        XCTAssertTrue(recordingStarted)

        let completeTask = Task {
            await entryGate.waitForRelease()
            await pipeline.complete()
        }
        await entryGate.waitUntilEntered()
        completeTask.cancel()
        await entryGate.release()
        await completeTask.value

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testCompleteCancellationDuringSetupDrainsProcessing() async {
        let setupGate = SuspensionGate()
        let audio = GatedStartAudioProvider(startGate: setupGate)
        let dictation = MockBatchProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: injector,
            coordinator: coordinator)

        await pipeline.activate()
        await setupGate.waitUntilEntered()

        let completeTask = Task { await pipeline.complete() }
        let processingStarted = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(processingStarted)

        completeTask.cancel()
        await setupGate.release()
        await completeTask.value

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testExplicitCancelInvalidatesManualCompleteSuspendedDuringSetup() async {
        let setupGate = SuspensionGate()
        let cancelCompletion = AsyncCompletionProbe()
        let audio = GatedStartAudioProvider(startGate: setupGate)
        let dictation = MockBatchProvider(stubbedText: "Late dictation")
        let streaming = MockStreamingProvider(stubbedText: "Late streaming result")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: dictation),
            textInjector: injector,
            coordinator: coordinator)

        await pipeline.activate()
        await setupGate.waitUntilEntered()

        let completeTask = Task { await pipeline.complete() }
        let processingStarted = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(processingStarted)

        let cancelTask = Task {
            await pipeline.cancel()
            await cancelCompletion.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > 0
        }
        XCTAssertTrue(cancellationEntered)
        let completedBeforeSetupRelease = await cancelCompletion.hasCompleted()
        XCTAssertFalse(completedBeforeSetupRelease)

        await setupGate.release()
        await cancelTask.value
        await completeTask.value

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testCancellationInsensitiveContextReadDoesNotBlockReplacementAdmission() async {
        let contextProvider = CancellationInsensitiveFirstContextProvider()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: contextProvider,
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator)

        guard let firstSessionID = await pipeline.activate() else {
            return XCTFail("Expected initial session admission")
        }
        await contextProvider.waitUntilFirstReadEnters()
        let captureStarted = await waitUntil { audio.startCallCount == 1 }
        XCTAssertTrue(captureStarted)

        let cancellationReturned = expectation(
            description: "cancellation does not join irrelevant context read")
        let cancelTask = Task {
            await pipeline.cancel(sessionID: firstSessionID)
            cancellationReturned.fulfill()
        }
        await contextProvider.waitUntilCancellationIsObserved()

        let replacementReturned = expectation(
            description: "replacement admission is not held by old context read")
        let replacementTask = Task {
            let sessionID = await pipeline.activate()
            replacementReturned.fulfill()
            return sessionID
        }

        // The first context provider deliberately ignores cancellation until
        // released below. Neither pipeline teardown nor replacement admission
        // owns that observational read after the old session is fenced.
        await fulfillment(
            of: [cancellationReturned, replacementReturned],
            timeout: 0.25)

        // Always release the cancellation-insensitive operation so the red
        // implementation can drain and this regression leaves no live tasks.
        await contextProvider.releaseFirstRead()
        await cancelTask.value
        let replacementSessionID = await replacementTask.value

        XCTAssertNotNil(replacementSessionID)
        XCTAssertNotEqual(replacementSessionID, firstSessionID)
        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
    }

    func testCompletionCancelsContextOwnerAfterFinalObservation() async {
        let contextProvider = CooperativeFirstContextProvider()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "completed dictation")
        let streamingStarted = expectation(description: "streaming started")
        streaming.startStreamingHook = { streamingStarted.fulfill() }
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: contextProvider,
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected initial session admission")
        }
        let contextEntered = await waitUntil {
            contextProvider.firstReadEntered
        }
        XCTAssertTrue(contextEntered)
        await fulfillment(of: [streamingStarted], timeout: 1)
        streaming.startStreamingHook = nil

        audio.emitPCMChunk(makeNonSilentPCMChunk())
        await pipeline.complete(sessionID: sessionID)

        let contextOwnerCancelled = await waitUntil {
            contextProvider.firstReadCancelled
        }
        XCTAssertTrue(
            contextOwnerCancelled,
            "The context owner must be cancelled after its final deadline observation")

        let replacementSessionID = await pipeline.activate()
        XCTAssertNotNil(
            replacementSessionID,
            "Releasing context ownership must not delay replacement admission")
        let replacementReadStarted = await waitUntil {
            contextProvider.readCount == 2
        }
        XCTAssertTrue(replacementReadStarted)

        contextProvider.releaseFirstRead()
        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
    }

    func testCompletionCancellationCancelsCapturedContextOwner() async {
        let contextProvider = CooperativeFirstContextProvider()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "cancelled dictation")
        let streamingStarted = expectation(description: "streaming started")
        streaming.startStreamingHook = { streamingStarted.fulfill() }
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: contextProvider,
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected initial session admission")
        }
        let contextEntered = await waitUntil {
            contextProvider.firstReadEntered
        }
        XCTAssertTrue(contextEntered)
        await fulfillment(of: [streamingStarted], timeout: 1)
        streaming.startStreamingHook = nil

        audio.emitPCMChunk(makeNonSilentPCMChunk())
        let completionTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        let completionTookContextOwnership = await waitUntil {
            audio.stopCallCount == 1
        }
        XCTAssertTrue(completionTookContextOwnership)

        await pipeline.cancel(sessionID: sessionID)

        let contextOwnerCancelled = await waitUntil {
            contextProvider.firstReadCancelled
        }
        XCTAssertTrue(
            contextOwnerCancelled,
            "Cancellation must reach context after completion clears pendingContext")

        let replacementSessionID = await pipeline.activate()
        XCTAssertNotNil(
            replacementSessionID,
            "Context teardown must not block replacement admission")

        contextProvider.releaseFirstRead()
        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
        await completionTask.value
    }

    func testCompleteEnteringDuringCancellationDrainIsRejected() async {
        let cancelGate = SuspensionGate()
        let completeCompletion = AsyncCompletionProbe()
        let batch = MockBatchProvider(stubbedText: "Late dictation")
        let streaming = MockStreamingProvider(stubbedText: "Late streaming result")
        streaming.cancelStreamingHook = {
            if streaming.cancelCallCount == 1 {
                await cancelGate.waitForRelease()
            }
        }
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: batch,
            streamingProvider: streaming)

        await pipeline.activate()
        let setupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(setupFinished)

        let cancelTask = Task { await pipeline.cancel() }
        await cancelGate.waitUntilEntered()
        let stateWhileDrainBlocked = await coordinator.state
        XCTAssertEqual(stateWhileDrainBlocked, .recording)

        let completeTask = Task {
            await pipeline.complete()
            await completeCompletion.markCompleted()
        }
        var completeReturned = false
        for _ in 0..<10_000 {
            if await completeCompletion.hasCompleted() {
                completeReturned = true
                break
            }
            await Task.yield()
        }

        XCTAssertTrue(completeReturned)
        let stateAfterLateComplete = await coordinator.state
        XCTAssertEqual(stateAfterLateComplete, .recording)
        XCTAssertEqual(batch.dictateCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)

        await cancelGate.release()
        await cancelTask.value
        await completeTask.value
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testStaleManualCompleteCannotCancelReplacementRecording() async {
        let handoffGate = SuspensionGate()
        let activationWaitProbe = CompletionWaitProbe()
        let activationCompletion = AsyncCompletionProbe()
        let audio = makeStreamingAudioProvider()
        let dictation = MockBatchProvider(stubbedText: "Stale dictation")
        let streaming = MockStreamingProvider(stubbedText: "Stale streaming result")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: dictation),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            completionWillHandoff: {
                await handoffGate.waitForRelease()
            },
            activationDidBeginWaitingForCompletion: {
                activationWaitProbe.markWaiting()
            })

        await pipeline.activate()
        let firstSetupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(firstSetupFinished)

        let staleCompleteTask = Task { await pipeline.complete() }
        await handoffGate.waitUntilEntered()
        await pipeline.cancel()

        let cancelledState = await coordinator.state
        XCTAssertEqual(cancelledState, .idle)

        let replacementActivationTask = Task {
            await pipeline.activate()
            await activationCompletion.markCompleted()
        }
        let activationReachedBarrierOrStarted = await waitUntil {
            activationWaitProbe.hasWaiter || audio.startCallCount == 2
        }
        XCTAssertTrue(activationReachedBarrierOrStarted)
        XCTAssertTrue(activationWaitProbe.hasWaiter)
        XCTAssertEqual(audio.startCallCount, 1)
        let completedWhileStaleOwnerActive = await activationCompletion.hasCompleted()
        XCTAssertFalse(completedWhileStaleOwnerActive)

        await handoffGate.release()
        await staleCompleteTask.value
        await replacementActivationTask.value

        let replacementStarted = await waitUntil {
            audio.startCallCount == 2 && streaming.startCallCount == 2
        }
        XCTAssertTrue(replacementStarted)

        let stateAfterStaleCompletion = await coordinator.state
        XCTAssertEqual(stateAfterStaleCompletion, .recording)
        XCTAssertTrue(audio.isRecording)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.cancel()
    }

    func testHotkeyReleaseCancelsActivationWaitingForCompletionDrain() async {
        let handoffGate = SuspensionGate()
        let activationWaitProbe = CompletionWaitProbe()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "first dictation")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            completionWillHandoff: {
                await handoffGate.waitForRelease()
            },
            activationDidBeginWaitingForCompletion: {
                activationWaitProbe.markWaiting()
            })

        guard let firstSessionID = await pipeline.activate() else {
            XCTFail("Expected initial session")
            return
        }
        let firstCaptureStarted = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(firstCaptureStarted)
        audio.emitPCMChunk(makeNonSilentPCMChunk())

        let staleCompletion = Task {
            await pipeline.complete(sessionID: firstSessionID)
        }
        await handoffGate.waitUntilEntered()
        await pipeline.cancel()
        let stateAfterCancellation = await coordinator.state
        XCTAssertEqual(stateAfterCancellation, .idle)

        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        driver.submit(.pressed)
        let activationReachedDrain = await waitUntil {
            activationWaitProbe.hasWaiter
        }
        XCTAssertTrue(activationReachedDrain)
        XCTAssertEqual(audio.startCallCount, 1)

        driver.submit(.released)
        // Establish that release cancelled the activation before allowing the
        // stale completion owner to drain.
        await driver.waitForSubmittedCommands()
        await handoffGate.release()
        await staleCompletion.value
        await driver.waitForSubmittedEvents()

        let finalSessionID = await pipeline.currentSessionID
        let finalState = await coordinator.state
        XCTAssertNil(finalSessionID)
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertEqual(streaming.startCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 0)
        driver.invalidate()
    }

    func testKeyUpCompletesActivationAfterSessionOwnershipIsPublished() async {
        let admittedGate = SuspensionGate()
        let captureStartGate = SuspensionGate()
        let preReleasePCM = makeNonSilentPCMChunk()
        let audio = PostReleaseStartAudioProvider(
            startGate: captureStartGate,
            postReleasePCM: preReleasePCM,
            retainsPreviewPreRoll: true)
        let streaming = MockStreamingProvider(stubbedText: "short dictation")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            activationDidPublishSessionOwner: {
                await admittedGate.waitForRelease()
            })
        let driver = HotkeyPipelineDriver(pipeline: pipeline)

        driver.submit(.pressed, hostTime: 10_000)
        await admittedGate.waitUntilEntered()
        driver.submit(.released, hostTime: 11_000)
        await driver.waitForSubmittedCommands()
        await admittedGate.release()
        await captureStartGate.waitUntilEntered()
        await captureStartGate.release()
        await driver.waitForSubmittedEvents()

        let finalState = await coordinator.state
        let finalSessionID = await pipeline.currentSessionID
        XCTAssertEqual(
            injector.injectionCount,
            1,
            "Key-up must complete a session already admitted by the pipeline")
        XCTAssertEqual(streaming.receivedAudioChunks, [preReleasePCM])
        XCTAssertEqual(audio.releaseHostTimes, [11_000])
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalSessionID)
        driver.invalidate()
    }

    func testScopedCompletionForOldSessionCannotStopReplacementRecording() async {
        let (pipeline, audio, _, batch, streaming, injector, coordinator) =
            makeStreamingPipeline()

        let firstSession = await pipeline.activate()
        XCTAssertNotNil(firstSession)
        let firstStarted = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(firstStarted)

        await pipeline.cancel()

        let replacementSession = await pipeline.activate()
        XCTAssertNotNil(replacementSession)
        XCTAssertNotEqual(firstSession, replacementSession)
        let replacementStarted = await waitUntil {
            audio.startCallCount == 2 && streaming.startCallCount == 2
        }
        XCTAssertTrue(replacementStarted)

        if let firstSession {
            await pipeline.complete(sessionID: firstSession)
        }

        let replacementState = await coordinator.state
        XCTAssertEqual(replacementState, .recording)
        XCTAssertTrue(audio.isRecording)
        XCTAssertEqual(batch.dictateCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.cancel()
    }

    func testCancellationAfterInjectionStartsWaitsBeforeReplacementActivation() async {
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "one atomic result")
        let injector = GatedTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator)

        let sessionID = await pipeline.activate()
        XCTAssertNotNil(sessionID)
        let setupFinished = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(setupFinished)
        audio.emitPCMChunk(makeNonSilentPCMChunk())

        let completionTask = Task {
            if let sessionID {
                await pipeline.complete(sessionID: sessionID)
            }
        }
        await injector.waitUntilInjectionStarts()

        let cancelProbe = AsyncCompletionProbe()
        let cancelTask = Task {
            await pipeline.cancel()
            await cancelProbe.markCompleted()
        }
        let activationProbe = AsyncCompletionProbe()
        let replacementTask = Task {
            _ = await pipeline.activate()
            await activationProbe.markCompleted()
        }

        for _ in 0..<100 {
            await Task.yield()
        }
        let cancelCompletedEarly = await cancelProbe.hasCompleted()
        let activationCompletedEarly = await activationProbe.hasCompleted()
        let writesBeforeRelease = await injector.injectionCount
        XCTAssertFalse(cancelCompletedEarly)
        XCTAssertFalse(activationCompletedEarly)
        XCTAssertEqual(writesBeforeRelease, 0)

        await injector.releaseInjection()
        await completionTask.value
        await cancelTask.value
        await replacementTask.value

        let finalWriteCount = await injector.injectionCount
        let replacementState = await coordinator.state
        XCTAssertEqual(finalWriteCount, 1)
        XCTAssertEqual(replacementState, .recording)
        await pipeline.cancel()
    }

    func testActivationRechecksCancellationInstalledWhileWaitingForCompletion() async {
        let activationWaitProbe = CompletionWaitProbe()
        let cancellationDrainGate = SuspensionGate()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "one atomic result")
        let injector = GatedTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            cancellationDrainDidStart: {
                await cancellationDrainGate.waitForRelease()
            },
            activationDidBeginWaitingForCompletion: {
                activationWaitProbe.markWaiting()
            })

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected initial session admission")
        }
        let setupFinished = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(setupFinished)
        audio.emitPCMChunk(makeNonSilentPCMChunk())

        let completionTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await injector.waitUntilInjectionStarts()

        let activationProbe = AsyncCompletionProbe()
        let replacementTask = Task {
            let replacementSessionID = await pipeline.activate()
            await activationProbe.markCompleted()
            return replacementSessionID
        }
        let activationReachedCompletionBarrier = await waitUntil {
            activationWaitProbe.hasWaiter
        }
        XCTAssertTrue(activationReachedCompletionBarrier)

        let cancelTask = Task {
            await pipeline.cancel(sessionID: sessionID)
        }
        await cancellationDrainGate.waitUntilEntered()

        // Completion now releases its waiter while cancellation remains installed
        // but deliberately blocked. Activation must discover that newer barrier
        // instead of observing the old `.injecting` state and returning nil.
        await injector.releaseInjection()
        await completionTask.value
        for _ in 0..<10_000 {
            if await activationProbe.hasCompleted() { break }
            await Task.yield()
        }
        let activationReturnedBeforeDrain = await activationProbe.hasCompleted()
        XCTAssertFalse(
            activationReturnedBeforeDrain,
            "Replacement activation must recheck a cancellation drain installed while it waited"
        )

        await cancellationDrainGate.release()
        await cancelTask.value
        let replacementSessionID = await replacementTask.value
        XCTAssertNotNil(replacementSessionID)
        let replacementState = await coordinator.state
        XCTAssertEqual(replacementState, .recording)

        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
    }

    func testReplacementActivationWaitsForStaleEarlySilenceCleanup() async {
        let cleanupGate = SuspensionGate()
        let activationWaitProbe = CompletionWaitProbe()
        let activationCompletion = AsyncCompletionProbe()
        let audio = makeStreamingAudioProvider()
        audio.stubbedPeakRMS = 0.001
        let dictation = MockBatchProvider(stubbedText: "Unexpected dictation")
        let streaming = MockStreamingProvider(stubbedText: "Unexpected streaming result")
        streaming.cancelStreamingHook = {
            if streaming.cancelCallCount == 1 {
                await cleanupGate.waitForRelease()
            }
        }
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: dictation),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            activationDidBeginWaitingForCompletion: {
                activationWaitProbe.markWaiting()
            })

        await pipeline.activate()
        let firstSetupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(firstSetupFinished)

        let staleCompleteTask = Task { await pipeline.complete() }
        await cleanupGate.waitUntilEntered()
        await pipeline.cancel()

        let replacementActivationTask = Task {
            await pipeline.activate()
            await activationCompletion.markCompleted()
        }
        let activationReachedBarrierOrStarted = await waitUntil {
            activationWaitProbe.hasWaiter || audio.startCallCount == 2
        }
        XCTAssertTrue(activationReachedBarrierOrStarted)
        XCTAssertTrue(activationWaitProbe.hasWaiter)
        XCTAssertEqual(audio.startCallCount, 1)
        let completedWhileStaleOwnerActive = await activationCompletion.hasCompleted()
        XCTAssertFalse(completedWhileStaleOwnerActive)

        await cleanupGate.release()
        await staleCompleteTask.value
        await replacementActivationTask.value

        let replacementStarted = await waitUntil {
            audio.startCallCount == 2 && streaming.startCallCount == 2
        }
        XCTAssertTrue(replacementStarted)
        let replacementState = await coordinator.state
        XCTAssertEqual(replacementState, .recording)
        XCTAssertTrue(audio.isRecording)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.cancel()
    }

    func testCancelDoesNotAwaitClaimedCompletionDuringSetupDrain() async {
        let sleepGate = RecordingLimitSleepGate()
        let setupGate = SuspensionGate()
        let cancelCompletion = AsyncCompletionProbe()
        let audio = GatedStartAudioProvider(startGate: setupGate)
        let streaming = MockStreamingProvider()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        await setupGate.waitUntilEntered()
        let automaticCompletionArmed = await waitUntil {
            sleepGate.callCount == 1
        }
        XCTAssertTrue(automaticCompletionArmed)

        sleepGate.release()
        let processingStarted = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(processingStarted)

        let cancelTask = Task {
            await pipeline.cancel()
            await cancelCompletion.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > 0
        }
        XCTAssertTrue(cancellationEntered)
        await setupGate.release()

        var cancellationCompleted = false
        for _ in 0..<10_000 {
            if await cancelCompletion.hasCompleted() {
                cancellationCompleted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(cancellationCompleted)
        if cancellationCompleted {
            await cancelTask.value
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(audio.isRecording)
    }

    func testCloudRecordingLimitCompletesWithExactWAVAndLateReleaseIsNoOp() async {
        let sleepGate = RecordingLimitSleepGate()
        let audio = makeStreamingAudioProvider()
        // Timer scheduling is not a correctness boundary. Even a capture that
        // exceeds the Realtime hard guard must reach whole-WAV recovery intact.
        let sourcePCM = Data(
            repeating: 0x01,
            count: 310 * 16_000 * MemoryLayout<Int16>.size + 4_096)
        let expectedWAV = WAVEncoder.encode(
            pcmData: sourcePCM,
            sampleRate: 16_000,
            channels: 1,
            bitsPerSample: 16)
        audio.stubbedBuffer = AudioBuffer(
            data: expectedWAV,
            duration: WAVEncoder.duration(
                byteCount: sourcePCM.count,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16),
            sampleRate: 16_000,
            channels: 1,
            bitsPerSample: 16)
        let batch = MockBatchProvider(stubbedText: "Recovered complete dictation")
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = OpenAIRealtimeCommitSession.Failure
            .hardBoundaryHasContinuation
        let (pipeline, _, _, _, _, injector, coordinator) = makeStreamingPipeline(
            audioProvider: audio,
            batchProvider: batch,
            streamingProvider: streaming,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let armed = await waitUntil {
            sleepGate.callCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(armed)
        XCTAssertEqual(sleepGate.requestedDurations, [.seconds(300)])

        sleepGate.release()
        let injected = await waitUntil { injector.injectionCount == 1 }
        let returnedToIdle = await waitUntilState(.idle, coordinator: coordinator)
        let finalState = await coordinator.state
        XCTAssertTrue(injected)
        XCTAssertTrue(returnedToIdle)
        XCTAssertEqual(batch.lastReceivedAudio, expectedWAV)
        XCTAssertEqual(injector.lastInjectedText, "Recovered complete dictation")
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(sleepGate.observedCancellation, false)

        // The physical key release arrives after automatic completion.
        await pipeline.complete()
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(batch.dictateCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testManualCompleteCancelsCloudRecordingLimit() async {
        let sleepGate = RecordingLimitSleepGate()
        let (pipeline, audio, _, _, streaming, injector, _) = makeStreamingPipeline(
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let armed = await waitUntil { sleepGate.callCount == 1 }
        XCTAssertTrue(armed)
        let captureReady = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(captureReady)

        await pipeline.complete()
        sleepGate.release()
        let timerReturned = await waitUntil { sleepGate.observedCancellation != nil }

        XCTAssertTrue(timerReturned)
        XCTAssertEqual(sleepGate.observedCancellation, true)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testCancelCancelsCloudRecordingLimit() async {
        let sleepGate = RecordingLimitSleepGate()
        let (pipeline, audio, _, _, streaming, injector, coordinator) =
            makeStreamingPipeline(cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let armed = await waitUntil {
            sleepGate.callCount == 1 && audio.startCallCount == 1
        }
        XCTAssertTrue(armed)

        await pipeline.cancel()
        sleepGate.release()
        let timerReturned = await waitUntil { sleepGate.observedCancellation != nil }
        let finalState = await coordinator.state

        XCTAssertTrue(timerReturned)
        XCTAssertEqual(sleepGate.observedCancellation, true)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
        XCTAssertEqual(finalState, .idle)
    }

    func testRetireCancelsCloudRecordingLimit() async {
        let sleepGate = RecordingLimitSleepGate()
        let (pipeline, _, _, _, streaming, injector, _) = makeStreamingPipeline(
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let armed = await waitUntil { sleepGate.callCount == 1 }
        XCTAssertTrue(armed)

        await pipeline.retire()
        sleepGate.release()
        let timerReturned = await waitUntil { sleepGate.observedCancellation != nil }

        XCTAssertTrue(timerReturned)
        XCTAssertEqual(sleepGate.observedCancellation, true)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testLocalRecordingDoesNotArmCloudRecordingLimit() async {
        let sleepGate = RecordingLimitSleepGate()
        let (pipeline, _, _, _, streaming, injector, _) = makeStreamingPipeline(
            localMode: true,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let started = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(sleepGate.callCount, 0)

        await pipeline.complete()

        XCTAssertEqual(sleepGate.callCount, 0)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testLocalCompletionRetainsPCMStreamWhenStartReturnsAfterRelease() async {
        let startGate = SuspensionGate()
        let audio = StartReturnGatedAudioProvider(
            startGate: startGate,
            initialPCMChunk: makeNonSilentPCMChunk())
        let streaming = MockStreamingProvider(stubbedText: "Retained local transcript")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator)

        let sessionID = await pipeline.activate()
        XCTAssertNotNil(sessionID)
        await startGate.waitUntilEntered()

        if let sessionID {
            await pipeline.complete(sessionID: sessionID)
        }

        let finalState = await coordinator.state
        XCTAssertEqual(streaming.startCallCount, 1)
        XCTAssertEqual(streaming.sendCallCount, 1)
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Retained local transcript")
        XCTAssertEqual(finalState, .idle)
    }

    func testCloudCompletionStopsCaptureAtReleaseBeforeRealtimeSetupFinishes() async {
        let setupGate = SuspensionGate()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "bounded cloud result")
        streaming.startStreamingHook = {
            await setupGate.waitForRelease()
        }
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        await setupGate.waitUntilEntered()

        let beforeRelease = makeNonSilentPCMChunk(sampleCount: 160)
        let afterRelease = makeNonSilentPCMChunk(sampleCount: 320)
        audio.emitPCMChunk(beforeRelease)

        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        var enteredProcessing = false
        for _ in 0..<10_000 {
            if await coordinator.state == .processing {
                enteredProcessing = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(enteredProcessing)
        let stoppedAtRelease = await waitUntil { audio.stopCallCount == 1 }

        audio.emitPCMChunk(afterRelease)
        await setupGate.release()
        await completeTask.value

        XCTAssertTrue(
            stoppedAtRelease,
            "Cloud capture must stop at key release, not after Realtime setup")
        XCTAssertEqual(
            streaming.receivedAudioChunks,
            [beforeRelease],
            "Post-release PCM must never become a cloud transcript candidate")
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testReleaseFencePreservesExactPCMForStreamingAndWAVFallback() async {
        let audio = StopGatedAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "unused")
        streaming.stubbedFinishError = ControlledCaptureError.stopFailed
        let batch = MockBatchProvider(stubbedText: "exact fallback")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let claimGate = SuspensionGate()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(realtime: streaming, fallback: batch),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            captureStopDidClaim: {
                await claimGate.waitForRelease()
            })

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let streamingStarted = await waitUntil {
            streaming.startCallCount == 1 && audio.isHardwareRunning
        }
        XCTAssertTrue(streamingStarted)

        let beforeRelease = makeNonSilentPCMChunk(sampleCount: 160)
        let afterRelease = makeNonSilentPCMChunk(sampleCount: 320)
        XCTAssertTrue(audio.emitPCMChunk(beforeRelease))

        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await claimGate.waitUntilEntered()

        XCTAssertFalse(
            audio.emitPCMChunk(afterRelease),
            "The synchronous release fence must close before async stop starts")
        await audio.waitUntilStopStarts()
        await audio.releaseStop()
        await claimGate.release()
        await completeTask.value

        XCTAssertEqual(streaming.receivedAudioChunks, [beforeRelease])
        let fallbackWAV = try? XCTUnwrap(batch.lastReceivedAudio)
        let fallbackPCM = fallbackWAV.map {
            Data($0.dropFirst(WAVEncoder.headerSize))
        }
        XCTAssertEqual(fallbackPCM, beforeRelease)
        XCTAssertEqual(injector.lastInjectedText, "exact fallback")
        XCTAssertEqual(audio.stopAttemptCount, 1)
    }

    func testCancellationJoinsCaptureStopClaimedByCompletion() async {
        let audio = StopGatedAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "unused")
        let coordinator = RecordingCoordinator()
        let claimGate = SuspensionGate()
        let cancellationObserved = expectation(
            description: "cancellation selected the session capture stop")
        let selection = CaptureStopSelectionProbe()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            captureStopDidClaim: {
                await claimGate.waitForRelease()
            },
            cancellationDidSelectCaptureStop: { selected in
                selection.record(selected)
                cancellationObserved.fulfill()
            })

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureIsLive = await waitUntil { audio.captureReadyCount == 1 }
        XCTAssertTrue(captureIsLive)

        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await claimGate.waitUntilEntered()

        let cancellationFinished = AsyncCompletionProbe()
        let cancelTask = Task {
            await pipeline.cancel(sessionID: sessionID)
            await cancellationFinished.markCompleted()
        }
        await fulfillment(of: [cancellationObserved], timeout: 1)

        XCTAssertTrue(selection.value)
        await audio.waitUntilStopStarts()
        XCTAssertEqual(audio.stopAttemptCount, 1)
        XCTAssertFalse(audio.isRecording)
        XCTAssertTrue(audio.isHardwareRunning)
        let cancellationCompletedEarly = await cancellationFinished.hasCompleted()
        XCTAssertFalse(cancellationCompletedEarly)

        await audio.releaseStop()
        await cancelTask.value
        XCTAssertFalse(audio.isRecording)
        XCTAssertFalse(audio.isHardwareRunning)
        XCTAssertEqual(audio.stopAttemptCount, 1)
        XCTAssertEqual(audio.completedStopCount, 1)

        await claimGate.release()
        await completeTask.value
    }

    func testCancellationRetainsClaimedStopIfCompletionClearsActorStateFirst() async {
        let audio = StopGatedAudioProvider()
        let claimGate = SuspensionGate()
        let selectionGate = SuspensionGate()
        let selection = CaptureStopSelectionProbe()
        let selectionObserved = expectation(
            description: "cancellation used its synchronously retained stop")
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator(),
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            captureStopDidClaim: {
                await claimGate.waitForRelease()
            },
            cancellationDrainDidStart: {
                await selectionGate.waitForRelease()
            },
            cancellationDidSelectCaptureStop: { selected in
                selection.record(selected)
                selectionObserved.fulfill()
            })

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureIsLive = await waitUntil { audio.captureReadyCount == 1 }
        XCTAssertTrue(captureIsLive)

        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await claimGate.waitUntilEntered()
        await audio.waitUntilStopStarts()

        let cancelTask = Task {
            await pipeline.cancel(sessionID: sessionID)
        }
        await selectionGate.waitUntilEntered()

        await claimGate.release()
        await completeTask.value
        await selectionGate.release()
        await fulfillment(of: [selectionObserved], timeout: 1)

        XCTAssertTrue(
            selection.value,
            "Cancellation must retain the stop it claimed synchronously")
        XCTAssertTrue(audio.isHardwareRunning)

        await audio.releaseStop()
        await cancelTask.value
        XCTAssertFalse(audio.isHardwareRunning)
        XCTAssertEqual(audio.stopAttemptCount, 1)
    }

    func testDuplicateCompletionSharesCaptureStopOperation() async {
        let audio = StopGatedAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "one result")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let claimGate = SuspensionGate()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            captureStopDidClaim: {
                await claimGate.waitForRelease()
            })

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureIsLive = await waitUntil { audio.captureReadyCount == 1 }
        XCTAssertTrue(captureIsLive)
        XCTAssertTrue(audio.emitPCMChunk(makeNonSilentPCMChunk(sampleCount: 160)))

        let firstCompletion = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await claimGate.waitUntilEntered()
        await audio.waitUntilStopStarts()
        XCTAssertEqual(
            audio.stopAttemptCount,
            1,
            "Capture stop ownership must be published before completion suspends")

        let secondCompletion = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await audio.waitUntilStopStarts()
        XCTAssertEqual(audio.stopAttemptCount, 1)

        await audio.releaseStop()
        await claimGate.release()
        await firstCompletion.value
        await secondCompletion.value

        XCTAssertFalse(audio.isRecording)
        XCTAssertFalse(audio.isHardwareRunning)
        XCTAssertEqual(audio.stopAttemptCount, 1)
        XCTAssertEqual(audio.completedStopCount, 1)
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testFailedSharedCaptureStopForceResetsWithoutRetryingStop() async {
        let audio = StopGatedAudioProvider(stopFails: true)
        let streaming = MockStreamingProvider(stubbedText: "must not inject")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider(stubbedText: "must not inject")),
            textInjector: injector,
            coordinator: coordinator)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureIsLive = await waitUntil { audio.captureReadyCount == 1 }
        XCTAssertTrue(captureIsLive)
        XCTAssertTrue(audio.emitPCMChunk(makeNonSilentPCMChunk(sampleCount: 160)))

        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await audio.waitUntilStopStarts()
        await audio.releaseStop()
        await completeTask.value

        XCTAssertFalse(audio.isHardwareRunning)
        XCTAssertEqual(audio.forceResetCount, 1)
        XCTAssertEqual(audio.stopAttemptCount, 1)
        XCTAssertEqual(injector.injectionCount, 0)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .dictationFailed)
    }

    func testCancellationWaitsForFailedSharedStopToForceResetCapture() async {
        let audio = StopGatedAudioProvider(stopFails: true)
        let coordinator = RecordingCoordinator()
        let claimGate = SuspensionGate()
        let cancellationSelectedStop = expectation(
            description: "cancellation selected the shared stop")
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            captureStopDidClaim: {
                await claimGate.waitForRelease()
            },
            cancellationDidSelectCaptureStop: { selected in
                if selected { cancellationSelectedStop.fulfill() }
            })

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureIsLive = await waitUntil { audio.captureReadyCount == 1 }
        XCTAssertTrue(captureIsLive)

        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await claimGate.waitUntilEntered()
        await audio.waitUntilStopStarts()

        let cancellationFinished = AsyncCompletionProbe()
        let cancelTask = Task {
            await pipeline.cancel(sessionID: sessionID)
            await cancellationFinished.markCompleted()
        }
        await fulfillment(of: [cancellationSelectedStop], timeout: 1)
        XCTAssertTrue(audio.isHardwareRunning)
        let cancellationCompletedEarly = await cancellationFinished.hasCompleted()
        XCTAssertFalse(cancellationCompletedEarly)

        await audio.releaseStop()
        await cancelTask.value

        XCTAssertFalse(audio.isHardwareRunning)
        XCTAssertEqual(audio.forceResetCount, 1)
        XCTAssertEqual(audio.stopAttemptCount, 1)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)

        await claimGate.release()
        await completeTask.value
    }

    func testCancellationDirectlyClaimsAndDrainsCaptureStop() async {
        let audio = StopGatedAudioProvider()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureIsLive = await waitUntil { audio.captureReadyCount == 1 }
        XCTAssertTrue(captureIsLive)

        let cancellationFinished = AsyncCompletionProbe()
        let cancelTask = Task {
            await pipeline.cancel(sessionID: sessionID)
            await cancellationFinished.markCompleted()
        }
        await audio.waitUntilStopStarts()

        XCTAssertFalse(audio.isRecording)
        XCTAssertTrue(audio.isHardwareRunning)
        let cancellationCompletedEarly = await cancellationFinished.hasCompleted()
        XCTAssertFalse(cancellationCompletedEarly)

        await audio.releaseStop()
        await cancelTask.value

        XCTAssertFalse(audio.isHardwareRunning)
        XCTAssertEqual(audio.stopAttemptCount, 1)
        XCTAssertEqual(audio.completedStopCount, 1)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testRetirementDirectlyClaimsAndDrainsCaptureStop() async {
        let audio = StopGatedAudioProvider()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator)

        guard await pipeline.activate() != nil else {
            return XCTFail("Expected session admission")
        }
        let captureIsLive = await waitUntil { audio.captureReadyCount == 1 }
        XCTAssertTrue(captureIsLive)

        let retirementFinished = AsyncCompletionProbe()
        let retireTask = Task {
            await pipeline.retire()
            await retirementFinished.markCompleted()
        }
        await audio.waitUntilStopStarts()

        XCTAssertFalse(audio.isRecording)
        XCTAssertTrue(audio.isHardwareRunning)
        let retirementCompletedEarly = await retirementFinished.hasCompleted()
        XCTAssertFalse(retirementCompletedEarly)

        await audio.releaseStop()
        await retireTask.value

        XCTAssertFalse(audio.isHardwareRunning)
        XCTAssertEqual(audio.stopAttemptCount, 1)
        XCTAssertEqual(audio.completedStopCount, 1)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testReadyCaptureSurvivesStartReturnObservationDeadline() async {
        let startReturnGate = SuspensionGate()
        let audio = StopGatedAudioProvider(startReturnGate: startReturnGate)
        let streaming = MockStreamingProvider(stubbedText: "preserved dictation")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            audioStartObservationTimeout: 0.01)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(streaming.startCallCount, 1)
        XCTAssertEqual(audio.forceResetCount, 0)

        let pcm = makeNonSilentPCMChunk(sampleCount: 160)
        XCTAssertTrue(audio.emitPCMChunk(pcm))
        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await audio.waitUntilStopStarts()
        await audio.releaseStop()
        await completeTask.value

        XCTAssertEqual(streaming.receivedAudioChunks, [pcm])
        XCTAssertEqual(injector.lastInjectedText, "preserved dictation")
        XCTAssertEqual(audio.forceResetCount, 0)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)

        await audio.releaseStartReturn()
    }

    func testCancellationCannotResetReadyCaptureUnderSharedStopOwner() async {
        let startReturnGate = SuspensionGate()
        let audio = StopGatedAudioProvider(startReturnGate: startReturnGate)
        let coordinator = RecordingCoordinator()
        let claimGate = SuspensionGate()
        let cancellationSelectedStop = expectation(
            description: "cancellation selected the shared stop")
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            captureStopDidClaim: {
                await claimGate.waitForRelease()
            },
            cancellationDidSelectCaptureStop: { selected in
                if selected { cancellationSelectedStop.fulfill() }
            },
            audioStartObservationTimeout: 60)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureIsLive = await waitUntil { audio.captureReadyCount == 1 }
        XCTAssertTrue(captureIsLive)

        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await claimGate.waitUntilEntered()
        await audio.waitUntilStopStarts()

        let cancellationFinished = AsyncCompletionProbe()
        let cancelTask = Task {
            await pipeline.cancel(sessionID: sessionID)
            await cancellationFinished.markCompleted()
        }
        await fulfillment(of: [cancellationSelectedStop], timeout: 1)
        let startWasCancelled = await waitUntil {
            audio.startCancellationCount == 1
        }

        XCTAssertTrue(startWasCancelled)
        XCTAssertEqual(audio.forceResetCount, 0)
        XCTAssertTrue(audio.isHardwareRunning)
        var cancellationCompletedEarly = await cancellationFinished.hasCompleted()
        XCTAssertFalse(cancellationCompletedEarly)

        await audio.releaseStop()
        cancellationCompletedEarly = await cancellationFinished.hasCompleted()
        XCTAssertFalse(cancellationCompletedEarly)
        await audio.releaseStartReturn()
        await cancelTask.value

        XCTAssertFalse(audio.isHardwareRunning)
        XCTAssertEqual(audio.forceResetCount, 0)
        XCTAssertEqual(audio.stopAttemptCount, 1)

        await claimGate.release()
        await completeTask.value
    }

    func testReleaseBoundaryDoesNotReadCaptureStatusBlockedByEngineStart() async {
        let audio = BlockingStartStatusAudioProvider()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        await audio.waitUntilStartEnters()

        let completionReturned = expectation(
            description: "release completes without reading the blocked status lock")
        let completionTask = Task {
            await pipeline.complete(sessionID: sessionID)
            completionReturned.fulfill()
        }
        let waiterResult = await XCTWaiter().fulfillment(
            of: [completionReturned], timeout: 0.25)

        await audio.releaseForCleanup()
        await completionTask.value

        XCTAssertEqual(
            waiterResult,
            .completed,
            "Release must force-reset an unacknowledged capture start immediately")
        XCTAssertEqual(
            audio.statusReadCount,
            0,
            "The release boundary must not block on AudioCaptureProvider.isRecording")
        XCTAssertGreaterThanOrEqual(audio.forceResetCount, 1)
        let state = await coordinator.state
        XCTAssertEqual(state, .dictationFailed)
        let canRetry = await pipeline.canRetryDictation(sessionID: sessionID)
        XCTAssertFalse(canRetry)
        await pipeline.dismissDictationFailure(sessionID: sessionID)
    }

    func testReleaseBeforeCaptureStartsRejectsPostReleaseAudioAndRetainsFailure() async {
        let startGate = SuspensionGate()
        let postReleasePCM = makeNonSilentPCMChunk()
        let audio = PostReleaseStartAudioProvider(
            startGate: startGate,
            postReleasePCM: postReleasePCM)
        let streaming = MockStreamingProvider(
            stubbedText: "This transcript came from post-release audio")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator)

        let sessionID = await pipeline.activate()
        XCTAssertNotNil(sessionID)
        await startGate.waitUntilEntered()

        let completion = Task {
            if let sessionID {
                await pipeline.complete(sessionID: sessionID)
            }
        }
        let releaseClaimed = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(releaseClaimed)

        // The hardware start returns only after the key-release boundary.
        // Exact reset may eliminate a separate cleanup stop; none of its late
        // PCM can be forwarded, finalized, or published as the dictation.
        await startGate.release()
        await completion.value

        let finalState = await coordinator.state
        let finalSessionID = await pipeline.currentSessionID

        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertEqual(audio.stopCallCount, 0)
        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(streaming.startCallCount, 0)
        XCTAssertEqual(streaming.sendCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertTrue(streaming.receivedAudioChunks.isEmpty)
        XCTAssertEqual(injector.injectionCount, 0)
        XCTAssertEqual(finalState, .dictationFailed)
        XCTAssertEqual(finalSessionID, sessionID)
    }

    func testReleaseBeforeDelayedPromotionRetainsPreviewPreRoll() async {
        let startGate = SuspensionGate()
        let preReleasePCM = makeNonSilentPCMChunk()
        let audio = PostReleaseStartAudioProvider(
            startGate: startGate,
            postReleasePCM: preReleasePCM,
            retainsPreviewPreRoll: true)
        let streaming = MockStreamingProvider(
            stubbedText: "Speech retained from preview pre-roll")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator)

        let pressHostTime = AudioCaptureReleaseFence.currentHostTime()
        let releaseBoundary = AudioCaptureReleaseBoundary(
            pressHostTime: pressHostTime)
        guard let sessionID = await pipeline.activate(
            releaseBoundary: releaseBoundary
        ) else {
            return XCTFail("Expected session admission")
        }
        await startGate.waitUntilEntered()

        let completion = Task {
            await pipeline.complete(
                sessionID: sessionID,
                releaseHostTime: pressHostTime + 1)
        }
        let releaseClaimed = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(releaseClaimed)

        await startGate.release()
        await completion.value

        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(streaming.startCallCount, 1)
        XCTAssertEqual(streaming.receivedAudioChunks, [preReleasePCM])
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
        let finalState = await coordinator.state
        let finalSessionID = await pipeline.currentSessionID
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalSessionID)
    }

    func testDuplicateCompletionCannotErasePreviewRecoveryOwnership() async {
        let startGate = SuspensionGate()
        let releaseOwnerGate = SuspensionGate()
        let preReleasePCM = makeNonSilentPCMChunk()
        let audio = PostReleaseStartAudioProvider(
            startGate: startGate,
            postReleasePCM: preReleasePCM,
            retainsPreviewPreRoll: true)
        let streaming = MockStreamingProvider(
            stubbedText: "Speech retained by the release owner")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            completionDidEstablishReleaseBoundary: {
                await releaseOwnerGate.waitForRelease()
            })
        let pressHostTime = AudioCaptureReleaseFence.currentHostTime()
        let releaseHostTime = pressHostTime + 1
        let releaseBoundary = AudioCaptureReleaseBoundary(
            pressHostTime: pressHostTime)

        guard let sessionID = await pipeline.activate(
            releaseBoundary: releaseBoundary
        ) else {
            return XCTFail("Expected session admission")
        }
        await startGate.waitUntilEntered()

        let releaseOwner = Task {
            await pipeline.complete(
                sessionID: sessionID,
                releaseHostTime: releaseHostTime)
        }
        await releaseOwnerGate.waitUntilEntered()

        let duplicate = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        let duplicateClaimedProcessing = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(duplicateClaimedProcessing)

        await releaseOwnerGate.release()
        await releaseOwner.value
        await startGate.release()
        await duplicate.value

        let finalState = await coordinator.state
        let finalSessionID = await pipeline.currentSessionID
        XCTAssertEqual(
            audio.releaseHostTimes,
            [releaseHostTime],
            "A duplicate completion must not erase the release owner's delayed stop")
        XCTAssertEqual(streaming.receivedAudioChunks, [preReleasePCM])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalSessionID)
    }

    func testReadinessDuringRecoveryQueryStillStopsAcceptedCapture() async {
        let audio = RecoveryQueryReadinessAudioProvider()
        let streaming = MockStreamingProvider(
            stubbedText: "Speech retained across preview promotion")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator)
        let pressHostTime = AudioCaptureReleaseFence.currentHostTime()
        let releaseBoundary = AudioCaptureReleaseBoundary(
            pressHostTime: pressHostTime)

        guard let sessionID = await pipeline.activate(
            releaseBoundary: releaseBoundary
        ) else {
            return XCTFail("Expected session admission")
        }
        await audio.waitUntilStartEnters()

        await pipeline.complete(
            sessionID: sessionID,
            releaseHostTime: pressHostTime + 1)

        let finalState = await coordinator.state
        let finalSessionID = await pipeline.currentSessionID
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalSessionID)
    }

    func testLatePreviewCaptureStopFailureSurfacesExplicitFailure() async {
        let startGate = SuspensionGate()
        let audio = PostReleaseStartAudioProvider(
            startGate: startGate,
            postReleasePCM: makeNonSilentPCMChunk(),
            retainsPreviewPreRoll: true,
            stopFails: true)
        let streaming = MockStreamingProvider(stubbedText: "must not inject")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator)
        let pressHostTime = AudioCaptureReleaseFence.currentHostTime()
        let releaseBoundary = AudioCaptureReleaseBoundary(
            pressHostTime: pressHostTime)

        guard let sessionID = await pipeline.activate(
            releaseBoundary: releaseBoundary
        ) else {
            return XCTFail("Expected session admission")
        }
        await startGate.waitUntilEntered()

        let completion = Task {
            await pipeline.complete(
                sessionID: sessionID,
                releaseHostTime: pressHostTime + 1)
        }
        let releaseClaimed = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(releaseClaimed)
        await startGate.release()
        await completion.value

        let finalState = await coordinator.state
        let finalSessionID = await pipeline.currentSessionID
        XCTAssertEqual(audio.stopAttemptCount, 1)
        XCTAssertEqual(injector.injectionCount, 0)
        XCTAssertEqual(finalState, .dictationFailed)
        XCTAssertEqual(finalSessionID, sessionID)
    }

    func testCancelledOldLimitCannotCompleteNewRecordingGeneration() async {
        let sleepGate = MultiRecordingLimitSleepGate()
        let (pipeline, audio, _, _, streaming, injector, coordinator) =
            makeStreamingPipeline(cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let firstArmed = await waitUntil {
            sleepGate.callCount == 1 && audio.startCallCount == 1
        }
        XCTAssertTrue(firstArmed)
        await pipeline.cancel()
        let stopCallCountAfterCancel = audio.stopCallCount

        await pipeline.activate()
        let secondArmed = await waitUntil {
            sleepGate.callCount == 2 && audio.startCallCount == 2
        }
        XCTAssertTrue(secondArmed)

        sleepGate.release(call: 0)
        let oldTimerReturned = await waitUntil {
            sleepGate.observedCancellation(for: 0) != nil
        }
        XCTAssertTrue(oldTimerReturned)
        XCTAssertEqual(sleepGate.observedCancellation(for: 0), true)
        let recordingState = await coordinator.state
        XCTAssertEqual(recordingState, .recording)
        XCTAssertEqual(audio.stopCallCount, stopCallCountAfterCancel)

        await pipeline.complete()
        sleepGate.release(call: 1)
        let currentTimerReturned = await waitUntil {
            sleepGate.observedCancellation(for: 1) != nil
        }
        XCTAssertTrue(currentTimerReturned)
        XCTAssertEqual(sleepGate.observedCancellation(for: 1), true)
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(audio.stopCallCount, stopCallCountAfterCancel + 1)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testCancelDrainsAutomaticCompletionDuringClaimHandoff() async {
        let sleepGate = RecordingLimitSleepGate()
        let claimGate = RecordingLimitClaimGate()
        let cancelCompletion = AsyncCompletionProbe()
        let streaming = MockStreamingProvider()
        let pipeline = DictationPipeline(
            audioProvider: makeStreamingAudioProvider(),
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator(),
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            },
            cloudRecordingLimitDidClaim: {
                await claimGate.pauseAfterClaim()
            })

        await pipeline.activate()
        let armed = await waitUntil { sleepGate.callCount == 1 }
        XCTAssertTrue(armed)
        sleepGate.release()
        await claimGate.waitUntilClaimed()

        let cancelTask = Task {
            await pipeline.cancel()
            await cancelCompletion.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > 0
        }
        XCTAssertTrue(cancellationEntered)
        await Task.yield()
        let completedBeforeRelease = await cancelCompletion.hasCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await claimGate.release()
        await cancelTask.value

        let observedCancellation = await claimGate.cancellationObserved()
        XCTAssertEqual(observedCancellation, true)
    }

    func testReactivationWaitsForClaimedAutomaticCompletion() async {
        let sleepGate = MultiRecordingLimitSleepGate()
        let claimGate = RecordingLimitClaimGate()
        let activationCompletion = AsyncCompletionProbe()
        let audio = makeStreamingAudioProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            },
            cloudRecordingLimitDidClaim: {
                await claimGate.pauseAfterClaim()
            })

        await pipeline.activate()
        let firstArmed = await waitUntil {
            sleepGate.callCount == 1 && audio.startCallCount == 1
        }
        XCTAssertTrue(firstArmed)
        sleepGate.release(call: 0)
        await claimGate.waitUntilClaimed()

        // The physical release finishes this recording while the automatic
        // completion owns, but has not yet entered, its complete() call.
        await pipeline.complete()
        XCTAssertEqual(injector.injectionCount, 1)
        let stateAfterManualCompletion = await coordinator.state
        XCTAssertEqual(stateAfterManualCompletion, .idle)

        let activationTask = Task {
            await pipeline.activate()
            await activationCompletion.markCompleted()
        }
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeClaimRetired =
            await activationCompletion.hasCompleted()
        XCTAssertFalse(completedBeforeClaimRetired)

        await claimGate.release()
        await activationTask.value
        let secondArmed = await waitUntil {
            sleepGate.callCount == 2 && audio.startCallCount == 2
        }
        XCTAssertTrue(secondArmed)
        let reactivatedState = await coordinator.state
        XCTAssertEqual(reactivatedState, .recording)

        await pipeline.complete()
        sleepGate.release(call: 1)
        XCTAssertEqual(injector.injectionCount, 2)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testCancelDrainsAutomaticCompletionBlockedInBatch() async {
        let sleepGate = MultiRecordingLimitSleepGate()
        let batch = CancellationInsensitiveBatchProvider(
            firstResult: "late result",
            retryResult: "next generation")
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        let audio = makeStreamingAudioProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let automaticCompletionArmed = await waitUntil {
            sleepGate.callCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(automaticCompletionArmed)
        sleepGate.release(call: 0)
        await batch.waitUntilFirstCallStarts()

        let cancellationFinished = AsyncCompletionProbe()
        let priorCancelAttemptCount = streaming.cancelAttemptCount
        let cancelTask = Task {
            await pipeline.cancel()
            await cancellationFinished.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > priorCancelAttemptCount
        }
        XCTAssertTrue(cancellationEntered)
        let cancellationCompletedEarly = await cancellationFinished.hasCompleted()
        XCTAssertFalse(cancellationCompletedEarly)

        await batch.releaseFirstCallIfStarted()
        await cancelTask.value
        let cancelledState = await coordinator.state
        XCTAssertEqual(cancelledState, .idle)
        XCTAssertEqual(injector.injectionCount, 0)
        XCTAssertEqual(audio.stopCallCount, 1)

        streaming.stubbedStartError = nil
        await pipeline.activate()
        let nextGenerationArmed = await waitUntil {
            sleepGate.callCount == 2 && streaming.startCallCount == 2
        }
        XCTAssertTrue(nextGenerationArmed)
        await pipeline.complete()
        sleepGate.release(call: 1)

        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Mock streaming dictation")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testRetireDrainsAutomaticCompletionBlockedInBatch() async {
        let sleepGate = RecordingLimitSleepGate()
        let batch = CancellationInsensitiveBatchProvider(
            firstResult: "late result",
            retryResult: "unused")
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        let audio = makeStreamingAudioProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let automaticCompletionArmed = await waitUntil {
            sleepGate.callCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(automaticCompletionArmed)
        sleepGate.release()
        await batch.waitUntilFirstCallStarts()

        let retirementFinished = AsyncCompletionProbe()
        let priorCancelAttemptCount = streaming.cancelAttemptCount
        let retireTask = Task {
            await pipeline.retire()
            await retirementFinished.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > priorCancelAttemptCount
        }
        XCTAssertTrue(cancellationEntered)
        let retirementCompletedEarly = await retirementFinished.hasCompleted()
        XCTAssertFalse(retirementCompletedEarly)

        await batch.releaseFirstCallIfStarted()
        await retireTask.value

        let retiredState = await coordinator.state
        XCTAssertEqual(retiredState, .idle)
        XCTAssertEqual(injector.injectionCount, 0)
        XCTAssertEqual(sleepGate.observedCancellation, false)
        await pipeline.activate()
        XCTAssertEqual(streaming.startCallCount, 1)
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func waitUntilState(
        _ expected: RecordingState,
        coordinator: RecordingCoordinator
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await coordinator.state == expected { return true }
            await Task.yield()
        }
        return await coordinator.state == expected
    }

    /// Emit PCM chunks in the background so the forwarding operation has data.
    private func emitChunksInBackground(
        _ audio: MockAudioProvider,
        count: Int = 2,
        sampleCount: Int = 1600,
        delayNanos: UInt64 = 20_000_000
    ) -> Task<Void, Never> {
        let chunks = (0..<count).map { _ in makeNonSilentPCMChunk(sampleCount: sampleCount) }
        return Task {
            for chunk in chunks {
                guard !Task.isCancelled else { break }
                audio.emitPCMChunk(chunk)
                try? await Task.sleep(nanoseconds: delayNanos)
            }
        }
    }

    // MARK: - Full streaming cycle

    func testStreamingFullCycleTransitionsToIdleAfterCompletion() async {
        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline()

        await pipeline.activate()
        var state = await coordinator.state
        XCTAssertEqual(state, .recording)

        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testStreamingFullCycleInjectsText() async {
        let streaming = MockStreamingProvider(stubbedText: "Hello streaming")
        let (pipeline, audio, _, _, _, injector, _) = makeStreamingPipeline(
            streamingProvider: streaming)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete(sessionID: sessionID)
        emitTask.cancel()

        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Hello streaming")
    }

    func testStreamingFullCycleStartsAndStopsAudioCapture() async {
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        // Audio setup now runs in a background task after activate() returns.
        // Wait briefly for the setup task to complete.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertTrue(audio.isRecording)

        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertFalse(audio.isRecording)
    }

    func testStreamingFullCycleCallsStartStreaming() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete(sessionID: sessionID)
        emitTask.cancel()

        XCTAssertEqual(streaming.startCallCount, 1)
    }

    func testStreamingFullCycleCallsFinishStreaming() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.finishCallCount, 1)
    }

    func testStreamingFullCycleForwardsAudioChunks() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()

        // Emit chunks and give the forwarding operation time to process.
        let emitTask = emitChunksInBackground(audio, count: 3)
        try? await Task.sleep(nanoseconds: 150_000_000)
        emitTask.cancel()

        await pipeline.complete()

        XCTAssertGreaterThan(
            streaming.sendCallCount, 0,
            "Audio chunks should be forwarded to the streaming provider")
        XCTAssertGreaterThan(
            streaming.totalAudioBytesReceived, 0,
            "Streaming provider should receive audio data")
    }

    func testCompleteDrainsQueuedAudioBeforeStreamingFinish() async {
        let firstChunk = makeNonSilentPCMChunk(sampleCount: 400)
        let finalChunk = makeNonSilentPCMChunk(sampleCount: 600)
        let sendGate = PipelineSendGate()
        let streaming = MockStreamingProvider(stubbedText: "Complete dictation")
        streaming.sendAudioHook = { data in
            await sendGate.send(data)
        }
        let dictation = MockBatchProvider(stubbedText: "Unexpected fallback")
        let (pipeline, audio, _, _, _, injector, _) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        guard didStart else {
            await pipeline.cancel()
            return
        }
        audio.emitPCMChunk(firstChunk)
        await sendGate.waitUntilFirstSendStarts()
        audio.emitPCMChunk(finalChunk)

        let completeTask = Task { await pipeline.complete() }
        let captureStopped = await waitUntil { audio.stopCallCount == 1 }
        XCTAssertTrue(captureStopped)
        XCTAssertEqual(streaming.finishCallCount, 0)

        await sendGate.releaseFirstSend()
        await completeTask.value

        let sentChunks = await sendGate.sentChunks
        XCTAssertEqual(sentChunks, [firstChunk, finalChunk])
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Complete dictation")
    }

    func testCancelClosesAndJoinsBlockedForwardingWithoutPublishing() async {
        let sendGate = PipelineSendGate()
        let streaming = MockStreamingProvider(stubbedText: "Untrusted partial text")
        streaming.sendAudioHook = { data in
            await sendGate.send(data)
        }
        streaming.cancelStreamingHook = {
            await sendGate.releaseFirstSend()
        }
        let dictation = MockBatchProvider(stubbedText: "Unexpected fallback")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        guard didStart else {
            await pipeline.cancel()
            return
        }
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        await sendGate.waitUntilFirstSendStarts()

        await pipeline.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertGreaterThanOrEqual(streaming.cancelCallCount, 1)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testExplicitCancelDiscardsRecoveryPublishedByCancelledBatch() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        let dictation = MockBatchProvider(stubbedText: "Late result")
        dictation.stubbedDelay = 60
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let emitTask = emitChunksInBackground(audio)
        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        let batchStarted = await waitUntil { dictation.dictateCallCount == 1 }
        XCTAssertTrue(batchStarted)

        await pipeline.cancel(sessionID: sessionID)
        await completeTask.value
        emitTask.cancel()

        let cancelledState = await coordinator.state
        XCTAssertEqual(cancelledState, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 0)

        dictation.stubbedDelay = 0
        await pipeline.retryDictation(sessionID: sessionID)

        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Explicit cancel must not leave hidden recovery audio")
        XCTAssertEqual(injector.injectionCount, 0)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testExplicitCancelRejectsLateBatchAuthenticationFailure() async {
        let audio = makeStreamingAudioProvider()
        let context = MockAppContextProvider()
        let dictation = CancellationInsensitiveAuthenticationFailureProvider()
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let sessionExpired = expectation(description: "late session expiry")
        sessionExpired.isInverted = true
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            backend: .cloud(
                realtime: streaming,
                fallback: dictation),
            textInjector: injector,
            coordinator: coordinator,
            onSessionExpired: { sessionExpired.fulfill() })

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        let completeTask = Task { await pipeline.complete() }
        await dictation.waitUntilCallStarts()

        let cancellationFinished = AsyncCompletionProbe()
        let priorCancelAttemptCount = streaming.cancelAttemptCount
        let cancelTask = Task {
            await pipeline.cancel()
            await cancellationFinished.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > priorCancelAttemptCount
        }
        XCTAssertTrue(cancellationEntered)
        let cancellationCompletedEarly = await cancellationFinished.hasCompleted()
        XCTAssertFalse(cancellationCompletedEarly)

        await dictation.releaseCallIfStarted()
        await cancelTask.value
        await completeTask.value
        emitTask.cancel()
        await fulfillment(of: [sessionExpired], timeout: 0.1)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testOwnerCancellationRejectsLateBatchResultAndPreservesCompleteWAV() async {
        let audio = makeStreamingAudioProvider()
        let context = MockAppContextProvider()
        let dictation = CancellationInsensitiveBatchProvider(
            firstResult: "Late plausible result",
            retryResult: "Recovered complete result")
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            backend: .cloud(
                realtime: streaming,
                fallback: dictation),
            textInjector: injector,
            coordinator: coordinator)
        let completeWAV = audio.stubbedBuffer.data

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let emitTask = emitChunksInBackground(audio)
        let completionFinished = AsyncCompletionProbe()
        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
            await completionFinished.markCompleted()
        }
        await dictation.waitUntilFirstCallStarts()

        let priorCancelAttemptCount = streaming.cancelAttemptCount
        completeTask.cancel()
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > priorCancelAttemptCount
        }
        XCTAssertTrue(cancellationEntered)
        let completionCompletedEarly = await completionFinished.hasCompleted()
        XCTAssertFalse(completionCompletedEarly)
        await dictation.releaseFirstCallIfStarted()
        await completeTask.value
        emitTask.cancel()

        let failedState = await coordinator.state
        let firstReceivedAudio = await dictation.receivedAudio
        XCTAssertEqual(failedState, .dictationFailed)
        XCTAssertEqual(firstReceivedAudio, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.retryDictation(sessionID: sessionID)

        let recoveredState = await coordinator.state
        let allReceivedAudio = await dictation.receivedAudio
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(allReceivedAudio, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered complete result")
    }

    func testOwnerCancellationPreservesLocalCaptureForExplicitRetry() async {
        let sourcePCM = makeNonSilentPCMChunk(sampleCount: 1_600)
        let sendGate = PipelineSendGate()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "recovered local result")
        streaming.sendAudioHook = { data in
            await sendGate.send(data)
        }
        streaming.cancelStreamingHook = {
            await sendGate.releaseFirstSend()
        }
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let recoveryCaptured = expectation(
            description: "pipeline retained exact local WAV")
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { _ in },
            pipelineDidCaptureRecovery: { _ in
                recoveryCaptured.fulfill()
            })

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        audio.emitPCMChunk(sourcePCM)
        await sendGate.waitUntilFirstSendStarts()

        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        let captureStopped = await waitUntil { audio.stopCallCount == 1 }
        XCTAssertTrue(captureStopped)
        await fulfillment(of: [recoveryCaptured], timeout: 1)

        let priorCancelAttemptCount = streaming.cancelAttemptCount
        completeTask.cancel()
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > priorCancelAttemptCount
        }
        XCTAssertTrue(cancellationEntered)
        await completeTask.value

        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)
        XCTAssertEqual(injector.injectionCount, 0)

        streaming.sendAudioHook = nil
        streaming.cancelStreamingHook = nil
        await pipeline.retryDictation(sessionID: sessionID)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "recovered local result")
    }

    func testStreamingReadsContext() async {
        let (pipeline, audio, context, _, _, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(context.readContextCallCount, 1)
    }

    func testStreamingPassesContextToStartStreaming() async {
        let ctx = AppContext(
            bundleID: "com.test.app",
            appName: "TestApp",
            windowTitle: "Test Window"
        )
        let contextProvider = MockAppContextProvider(context: ctx)
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline(
            contextProvider: contextProvider)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.receivedContexts.count, 1)
        let received = streaming.receivedContexts.first
        XCTAssertEqual(received?.bundleID, "com.test.app")
        XCTAssertEqual(received?.appName, "TestApp")
    }

    func testStreamingPassesContextToTextInjector() async {
        let ctx = AppContext(
            bundleID: "com.test.inject",
            appName: "InjectApp",
            windowTitle: "Inject Window"
        )
        let contextProvider = MockAppContextProvider(context: ctx)
        let (pipeline, audio, _, _, _, injector, _) = makeStreamingPipeline(
            contextProvider: contextProvider)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let injectedContext = injector.injections.first?.context
        XCTAssertEqual(injectedContext?.bundleID, "com.test.inject")
        XCTAssertEqual(injectedContext?.appName, "InjectApp")
    }

    // MARK: - State transitions

    func testStreamingStatePassesThroughAllPhases() async {
        let coordinator = RecordingCoordinator()
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(coordinator: coordinator)

        var collected: [RecordingState] = []
        let expectation = XCTestExpectation(description: "Collect all state transitions")

        let streamTask = Task {
            for await state in await coordinator.stateStream {
                collected.append(state)
                // idle, recording, processing, injecting, idle
                if collected.count >= 5 {
                    break
                }
            }
            expectation.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        await fulfillment(of: [expectation], timeout: 5.0)
        streamTask.cancel()

        XCTAssertEqual(collected, [.idle, .recording, .processing, .injecting, .idle])
    }

    // MARK: - Cancellation

    func testCancelDuringStreamingResetsToIdle() async {
        let (pipeline, _, _, _, streaming, _, coordinator) = makeStreamingPipeline()

        await pipeline.activate()
        // Audio setup now runs in a background task after activate() returns.
        // Wait briefly for the streaming session to start before cancelling.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        let state = await coordinator.state
        XCTAssertEqual(state, .recording)

        await pipeline.cancel()
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)

        XCTAssertEqual(
            streaming.cancelCallCount, 1,
            "Streaming session should be cancelled")
    }

    func testCancelDoesNotCallFinishStreaming() async {
        let (pipeline, _, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        await pipeline.cancel()

        XCTAssertEqual(
            streaming.finishCallCount, 0,
            "finishStreaming should not be called on cancel")
    }

    func testCycleWorksAfterStreamingCancel() async {
        let streaming = MockStreamingProvider(stubbedText: "After cancel")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming)

        // First cycle: cancel.
        await pipeline.activate()
        await pipeline.cancel()
        var state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Second cycle: complete.
        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(streaming.finishCallCount, 1)
    }

    // MARK: - Streaming errors

    func testStreamingStartFailureFallsToBatchMode() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("connection refused")

        let dictation = MockBatchProvider(stubbedText: "Batch fallback text")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // When streaming start fails, pipeline falls back to batch mode.
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be called as fallback when streaming start fails")
        XCTAssertEqual(injector.lastInjectedText, "Batch fallback text")
    }

    func testStreamingStartFailureDoesNotRejectSparseAudibleWAV() async {
        let audio = MockAudioProvider(stubbedBuffer: makeSparseAudibleBuffer())
        audio.enablePCMStream = true
        audio.stubbedPeakRMS = 0.1
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("connection refused")
        let dictation = MockBatchProvider(stubbedText: "Sparse setup recovery")
        let (pipeline, _, _, _, _, injector, coordinator) = makeStreamingPipeline(
            audioProvider: audio,
            batchProvider: dictation,
            streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [audio.stubbedBuffer.data])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Sparse setup recovery")
    }

    func testStreamingStartFailureAndEmptyBatchResetToIdle() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("connection refused")
        let dictation = MockBatchProvider(stubbedText: "")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        // Streaming failed to start, but the batch fallback ran and recognized
        // no speech. An empty transcript is a no-op, not a failure: idle, no
        // card, nothing retained. A retry has nothing to recover, so it is inert.
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.retryDictation()
        let afterRetry = await coordinator.state
        XCTAssertEqual(afterRetry, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testStreamingFinishFailureFallsToBatch() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("connection lost")

        let dictation = MockBatchProvider(stubbedText: "Batch recovery")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be called as fallback when streaming finish fails")
        XCTAssertEqual(dictation.lastReceivedAudio, audio.stubbedBuffer.data)
        XCTAssertEqual(injector.lastInjectedText, "Batch recovery")
    }

    func testStreamingEmptyResultUsesBatchFallback() async {
        // When streaming returns empty, the serial batch fallback is used.
        let streaming = MockStreamingProvider(stubbedText: "")
        let dictation = MockBatchProvider(stubbedText: "Batch result")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 1,
            "Batch result should be injected when streaming returns empty")
        XCTAssertEqual(dictation.lastReceivedAudio, audio.stubbedBuffer.data)
        XCTAssertEqual(injector.lastInjectedText, "Batch result")
    }

    func testBothEmptyResultsResetToIdle() async {
        let streaming = MockStreamingProvider(stubbedText: "")
        let dictation = MockBatchProvider(stubbedText: "")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        // Both paths recognized no speech: a no-op, not a failure. Idle, no
        // card, nothing retained; a retry has nothing to recover.
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.retryDictation()
        let afterRetry = await coordinator.state
        XCTAssertEqual(afterRetry, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testBothWhitespaceOnlyResultsResetToIdle() async {
        let streaming = MockStreamingProvider(stubbedText: "   \n  ")
        let dictation = MockBatchProvider(stubbedText: "  \t  ")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        // Whitespace-only counts as no speech: same silent no-op.
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)
    }

    // MARK: - Transcript buffer

    func testStreamingStoresTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingProvider(stubbedText: "Streamed text")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            streamingProvider: streaming, transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(stored, "Streamed text")
    }

    func testBothEmptyResultsDoNotStoreInBuffer() async {
        // When both streaming and batch return empty, nothing stored.
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingProvider(stubbedText: "")
        let dictation = MockBatchProvider(stubbedText: "")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertNil(stored, "Empty results from both paths should not be stored in buffer")
    }

    func testStreamingEmptyButBatchSuccessStoresInBuffer() async {
        // When streaming returns empty but batch returns text, store batch result.
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingProvider(stubbedText: "")
        let dictation = MockBatchProvider(stubbedText: "Batch text")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "Batch text", "Batch result should be stored when streaming is empty")
    }

    func testStreamingFailureWithBatchFallbackStoresInBuffer() async {
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("fail")
        let dictation = MockBatchProvider(stubbedText: "Batch recovered")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "Batch recovered",
            "Batch fallback result should be stored in buffer")
    }

    // MARK: - Injection failure in streaming mode

    func testStreamingInjectionFailureTransitionsToInjectionFailed() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider(stubbedText: "streamed text")

        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming, textInjector: injector, transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .injectionFailed,
            "Pipeline should transition to injectionFailed on injection error in streaming mode")
    }

    func testStreamingInjectionFailurePreservesTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider(stubbedText: "preserved streaming text")

        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            streamingProvider: streaming, textInjector: injector, transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "preserved streaming text",
            "Transcript should remain in buffer after injection failure in streaming mode")
    }

    func testFailedInjectionRetryIsOwnedByOriginalSession() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider(stubbedText: "retry this transcript")
        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming,
            textInjector: injector,
            transcriptBuffer: buffer)

        let sessionID = await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        if let sessionID {
            await pipeline.complete(sessionID: sessionID)
        }
        emitTask.cancel()
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .injectionFailed)

        injector.stubbedError = nil
        await pipeline.retryDictation()
        if let sessionID {
            await pipeline.retryBufferedInjection(sessionID: sessionID)
        }

        let finalState = await coordinator.state
        let buffered = await buffer.lastTranscript
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(buffered)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "retry this transcript")
    }

    func testStaleInjectionDismissCannotRevokeAcceptedBufferedRetry() async {
        let context = CancellationInsensitiveSecondContextProvider()
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider(stubbedText: "owned buffered transcript")
        let coordinator = RecordingCoordinator()
        let audio = makeStreamingAudioProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            transcriptBuffer: buffer,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            })

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete(sessionID: sessionID)
        emitTask.cancel()

        let failedState = await coordinator.state
        let retainedTranscript = await buffer.lastTranscript
        XCTAssertEqual(failedState, .injectionFailed)
        XCTAssertEqual(retainedTranscript, "owned buffered transcript")
        XCTAssertEqual(injector.injectionCount, 0)

        injector.stubbedError = nil
        let retryTask = Task {
            await pipeline.retryBufferedInjection(sessionID: sessionID)
        }
        await context.waitUntilSecondReadEnters()

        let claimedState = await coordinator.state
        XCTAssertEqual(claimedState, .injecting)
        await pipeline.dismissInjectionFailure(sessionID: sessionID)

        let stateAfterStaleDismiss = await coordinator.state
        let ownerAfterStaleDismiss = await pipeline.currentSessionID
        XCTAssertEqual(stateAfterStaleDismiss, .injecting)
        XCTAssertEqual(ownerAfterStaleDismiss, sessionID)
        XCTAssertEqual(injector.injectionCount, 0)

        await context.releaseSecondRead()
        await retryTask.value

        let finalState = await coordinator.state
        let finalOwner = await pipeline.currentSessionID
        let finalTranscript = await buffer.lastTranscript
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalOwner)
        XCTAssertNil(finalTranscript)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "owned buffered transcript")
    }

    func testStaleFailedInjectionRetryCannotConsumeOwningTranscript() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider(stubbedText: "owned transcript")
        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming,
            textInjector: injector,
            transcriptBuffer: buffer)

        let sessionID = await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        if let sessionID {
            await pipeline.complete(sessionID: sessionID)
        }
        emitTask.cancel()

        injector.stubbedError = nil
        await pipeline.retryBufferedInjection(sessionID: DictationSessionID())

        let state = await coordinator.state
        let buffered = await buffer.lastTranscript
        XCTAssertEqual(state, .injectionFailed)
        XCTAssertEqual(buffered, "owned transcript")
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testRecoveryInjectionFailureDiscardsAcceptedAudio() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("stream failed")
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.networkError("batch failed")
        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            textInjector: injector,
            transcriptBuffer: buffer)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete(sessionID: sessionID)
        emitTask.cancel()

        dictation.stubbedError = nil
        dictation.stubbedText = "accepted recovery text"
        await pipeline.retryDictation(sessionID: sessionID)

        let failedState = await coordinator.state
        let stored = await buffer.lastTranscript
        XCTAssertEqual(failedState, .injectionFailed)
        XCTAssertEqual(stored, "accepted recovery text")
        XCTAssertEqual(dictation.dictateCallCount, 2)

        await pipeline.retryDictation(sessionID: sessionID)

        XCTAssertEqual(
            dictation.dictateCallCount, 2,
            "Accepted text must replace the WAV as the recovery artifact")
        let retainedState = await coordinator.state
        XCTAssertEqual(retainedState, .injectionFailed)
        await pipeline.dismissInjectionFailure(sessionID: sessionID)
        let dismissedState = await coordinator.state
        XCTAssertEqual(dismissedState, .idle)
    }

    func testStreamingCycleWorksAfterInjectionFailureAndReset() async {
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let coordinator = RecordingCoordinator()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "first attempt")

        let (pipeline, _, _, _, _, _, _) = makeStreamingPipeline(
            audioProvider: audio, streamingProvider: streaming,
            textInjector: injector, coordinator: coordinator)

        // First cycle: injection fails.
        guard let firstSessionID = await pipeline.activate() else {
            return XCTFail("Expected first session admission")
        }
        let emitTask1 = emitChunksInBackground(audio)
        await pipeline.complete(sessionID: firstSessionID)
        emitTask1.cancel()

        var state = await coordinator.state
        XCTAssertEqual(state, .injectionFailed)

        // Reset (simulates user dismissing no-target HUD).
        await pipeline.dismissInjectionFailure(sessionID: firstSessionID)
        state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Second cycle: injection succeeds.
        injector.stubbedError = nil
        streaming.stubbedText = "second attempt"

        guard let secondSessionID = await pipeline.activate() else {
            return XCTFail("Expected replacement session admission")
        }
        let emitTask2 = emitChunksInBackground(audio)
        await pipeline.complete(sessionID: secondSessionID)
        emitTask2.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "second attempt")
    }

    // MARK: - Fallback to batch when no PCM stream

    func testFallbackToBatchWhenNoPCMStream() async {
        // Use a MockAudioProvider WITHOUT enablePCMStream (nil pcmAudioStream).
        let audio = MockAudioProvider()
        // enablePCMStream defaults to false, so pcmAudioStream is nil.

        let streaming = MockStreamingProvider(stubbedText: "Should not be used")
        let dictation = MockBatchProvider(stubbedText: "Batch text")

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator()
        )

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureStarted = await waitUntil { audio.startCallCount == 1 }
        XCTAssertTrue(captureStarted)
        guard captureStarted else {
            await pipeline.cancel(sessionID: sessionID)
            return
        }
        await pipeline.complete(sessionID: sessionID)

        XCTAssertEqual(
            streaming.startCallCount, 0,
            "Streaming should not be used when audio provider has no pcmAudioStream")
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be used as fallback")
    }

    // MARK: - Multiple consecutive streaming cycles

    func testMultipleConsecutiveStreamingCycles() async {
        let streaming = MockStreamingProvider()
        let audio = makeStreamingAudioProvider()
        let coordinator = RecordingCoordinator()
        let injector = MockTextInjector()

        let batch = makeSlowBatchProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator
        )

        // First cycle.
        streaming.stubbedText = "First"
        await pipeline.activate()
        let emitTask1 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask1.cancel()

        var state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "First")

        // Second cycle.
        streaming.stubbedText = "Second"
        await pipeline.activate()
        let emitTask2 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask2.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 2)
        XCTAssertEqual(injector.lastInjectedText, "Second")

        XCTAssertEqual(streaming.startCallCount, 2)
        XCTAssertEqual(streaming.finishCallCount, 2)
    }

    // MARK: - Rapid streaming activate/cancel cycles

    func testRapidStreamingActivateCancelCycles() async {
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator
        )

        for _ in 0..<5 {
            await pipeline.activate()
            await pipeline.cancel()
            let state = await coordinator.state
            XCTAssertEqual(state, .idle)
        }

        // One final full cycle to confirm nothing is broken.
        streaming.stubbedText = "After rapid cycles"
        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    // MARK: - Streaming send error during forwarding

    func testStreamingSendErrorRejectsPartialAndBatchesCompleteWAV() async {
        let streaming = MockStreamingProvider(stubbedText: "Plausible partial result")
        streaming.stubbedSendError = DictationError.networkError("send failed")
        let dictation = MockBatchProvider(stubbedText: "Complete batch recovery")

        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        let didSend = await waitUntil { streaming.sendCallCount == 1 }
        XCTAssertTrue(didSend)

        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertGreaterThanOrEqual(streaming.cancelCallCount, 1)
        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(dictation.lastReceivedAudio, completeWAV)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Complete batch recovery")
    }

    func testStreamingRecoveryDoesNotRejectSparseAudibleWAV() async {
        let completeBuffer = makeSparseAudibleBuffer()
        let audio = MockAudioProvider(stubbedBuffer: completeBuffer)
        audio.enablePCMStream = true
        audio.stubbedPeakRMS = 0.1
        let streaming = MockStreamingProvider(stubbedText: "")
        streaming.stubbedSendError = DictationError.networkError("send failed")
        let dictation = MockBatchProvider(stubbedText: "Brief complete recovery")
        let (pipeline, _, _, _, _, injector, coordinator) = makeStreamingPipeline(
            audioProvider: audio,
            batchProvider: dictation,
            streamingProvider: streaming)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        let didSend = await waitUntil { streaming.sendCallCount == 1 }
        XCTAssertTrue(didSend)

        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(dictation.receivedAudioData, [completeBuffer.data])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Brief complete recovery")
    }

    func testLocalSendErrorDoesNotFinalizeOrInjectPartialText() async {
        let streaming = MockStreamingProvider(stubbedText: "Incomplete local text")
        streaming.stubbedSendError = DictationError.networkError("send failed")
        let dictation = MockBatchProvider(stubbedText: "Unexpected cloud recovery")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            localMode: true)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        let didSend = await waitUntil { streaming.sendCallCount == 1 }
        XCTAssertTrue(didSend)

        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .dictationFailed)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertGreaterThanOrEqual(streaming.cancelCallCount, 1)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testLocalSendFailureRetryUsesExactPCMReplayAndInjectsOnce() async {
        let sourcePCM = makeNonSilentPCMChunk(sampleCount: 1_600)
        let audio = MockAudioProvider(
            stubbedBuffer: AudioBuffer(
                data: WAVEncoder.encode(
                    pcmData: sourcePCM,
                    sampleRate: 16_000,
                    channels: 1,
                    bitsPerSample: 16),
                duration: 0.1,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16))
        audio.enablePCMStream = true

        let streaming = MockStreamingProvider(stubbedText: "Complete local retry")
        streaming.stubbedSendError = DictationError.networkError("send failed")
        let (pipeline, _, _, dictation, _, injector, coordinator) =
            makeStreamingPipeline(
                audioProvider: audio,
                streamingProvider: streaming,
                localMode: true)

        let sessionID = await pipeline.activate()
        XCTAssertNotNil(sessionID)
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        audio.emitPCMChunk(sourcePCM)
        let didFailSend = await waitUntil { streaming.sendCallCount == 1 }
        XCTAssertTrue(didFailSend)

        await pipeline.complete()

        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)
        XCTAssertEqual(streaming.receivedAudioChunks, [sourcePCM])
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)

        streaming.stubbedSendError = nil
        if let sessionID {
            await pipeline.retryDictation(sessionID: sessionID)
        }

        XCTAssertEqual(streaming.replayCallCount, 1)
        XCTAssertEqual(streaming.replayedAudio, [sourcePCM])
        XCTAssertEqual(streaming.replaySessionIDs, [sessionID].compactMap { $0 })
        XCTAssertEqual(streaming.startCallCount, 1)
        XCTAssertEqual(streaming.receivedAudioChunks, [sourcePCM])
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Complete local retry")
        let finalState = await coordinator.state
        let finalSessionID = await pipeline.currentSessionID
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalSessionID)
    }

    func testLocalSetupFailureRetainsExactCaptureForRetry() async {
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "recovered local setup")
        streaming.stubbedStartError = DictationError.networkError("model setup failed")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let setupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(setupFinished)
        await pipeline.complete(sessionID: sessionID)

        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)
        XCTAssertEqual(injector.injectionCount, 0)

        streaming.stubbedStartError = nil
        await pipeline.retryDictation(sessionID: sessionID)

        XCTAssertEqual(streaming.startCallCount, 1)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(streaming.replayCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "recovered local setup")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testLocalEmptyResultResetsToIdleWithoutCard() async {
        let sourcePCM = makeNonSilentPCMChunk(sampleCount: 1_600)
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: " \n ")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        audio.emitPCMChunk(sourcePCM)
        await pipeline.complete(sessionID: sessionID)

        // No speech recognized locally is a silent no-op, not a failure: reset to
        // idle with no failure card, nothing injected, and nothing retained.
        // Retrying deterministic local recognition on the same audio would just
        // return empty again, so no recovery is offered.
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 0)
        let canRetry = await pipeline.canRetryDictation(sessionID: sessionID)
        XCTAssertFalse(canRetry)
    }

    // MARK: - Language parameter

    func testStreamingPassesNilLanguage() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.receivedLanguages.count, 1)
        XCTAssertNil(streaming.receivedLanguages.first ?? "not nil")
    }

    // MARK: - Atomic streaming result

    func testCloudPipelinePublishesOnlyOneFinalResult() async {
        let streaming = MockStreamingProvider(stubbedText: "Complete cloud result")
        let (pipeline, _, _, _, _, injector, _) = makeStreamingPipeline(
            streamingProvider: streaming)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.complete()

        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Complete cloud result")
    }

    // MARK: - Cancel always cancels streaming

    func testCancelAlwaysCancelsStreaming() async {
        let sendGate = PipelineSendGate()
        let streaming = MockStreamingProvider()
        streaming.sendAudioHook = { data in
            await sendGate.send(data)
        }
        streaming.cancelStreamingHook = {
            await sendGate.releaseFirstSend()
        }
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            streamingProvider: streaming)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let streamingStarted = await waitUntil {
            streaming.startCallCount == 1
        }
        XCTAssertTrue(streamingStarted)
        guard streamingStarted else {
            await pipeline.cancel(sessionID: sessionID)
            return
        }
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        await sendGate.waitUntilFirstSendStarts()

        let completeTask = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        let captureStopped = await waitUntil { audio.stopCallCount == 1 }
        XCTAssertTrue(captureStopped)

        await pipeline.cancel(sessionID: sessionID)
        await completeTask.value

        XCTAssertGreaterThanOrEqual(
            streaming.cancelCallCount, 1,
            "cancel() must call cancelStreaming() even after complete() cleared isStreamingSession")
    }

    // MARK: - Silence rejection

    func testSilentStreamingSessionRejectsWithoutInjecting() async {
        let audio = makeStreamingAudioProvider()
        // Set peak RMS below the silence threshold so the early gate fires.
        audio.stubbedPeakRMS = 0.001

        let (pipeline, _, _, _, _, injector, coordinator) =
            makeStreamingPipeline(audioProvider: audio)

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let emitTask = emitChunksInBackground(audio, count: 2)
        await pipeline.complete()
        emitTask.cancel()

        // Pipeline should return to idle without injecting text.
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "Silent audio should not produce any text injection")
    }

    // MARK: - Sequential fallback (streaming → batch)

    func testStreamingSuccessSkipsBatch() async {
        // When streaming succeeds, batch should NOT be called.
        let streaming = MockStreamingProvider(stubbedText: "Streaming result")
        let dictation = MockBatchProvider(stubbedText: "Batch result")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            dictation.dictateCallCount, 0,
            "Batch should not be called when streaming succeeds")
        XCTAssertEqual(injector.lastInjectedText, "Streaming result")
    }

    func testStreamingSuccessIsIdentifiedInDiagnostics() async {
        let streaming = MockStreamingProvider(stubbedText: "Streaming result")
        let dictation = MockBatchProvider(stubbedText: "Batch result")
        let diagnostics = MicDiagnosticStore()
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            micDiagnosticStore: diagnostics)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let text = await diagnostics.formattedDiagnostics()
        XCTAssertTrue(text.contains("result=ok_realtime"), text)
    }

    func testStreamingFailureFallsToBatchHTTP() async {
        // When streaming fails, batch HTTP should be called as fallback.
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider(stubbedText: "Batch fallback")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch should be called as fallback when streaming fails")
        XCTAssertEqual(injector.lastInjectedText, "Batch fallback")
    }

    func testStreamingFallbackSuccessIsIdentifiedInDiagnostics() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider(stubbedText: "Batch fallback")
        let diagnostics = MicDiagnosticStore()
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            micDiagnosticStore: diagnostics)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let text = await diagnostics.formattedDiagnostics()
        XCTAssertTrue(text.contains("result=ok_http_fallback"), text)
    }

    func testBothStreamingAndBatchFailPreservesCompleteWAVForRetry() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.networkError("http died")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .dictationFailed)
        XCTAssertEqual(dictation.lastReceivedAudio, completeWAV)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "No text should be injected when both paths fail")

        dictation.stubbedError = nil
        dictation.stubbedText = "Recovered complete dictation"
        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 2)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered complete dictation")
    }

    func testBatch401PreservesCompleteWAVAcrossCredentialRetry() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.authenticationFailed
        let callback = expectation(description: "session expired")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            onSessionExpired: { callback.fulfill() })
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()
        await fulfillment(of: [callback], timeout: 2)

        let expiredState = await coordinator.state
        XCTAssertEqual(expiredState, .sessionExpired)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        dictation.stubbedError = nil
        dictation.stubbedText = "Recovered after sign in"
        await pipeline.presentRecoveryAfterAuthentication()

        let readyState = await coordinator.state
        XCTAssertEqual(readyState, .dictationFailed)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered after sign in")
    }

    func testRetryAuthenticationFailureReopensSessionRecovery() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.networkError("http died")
        let secondExpiry = expectation(description: "replacement key rejected")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            onSessionExpired: { secondExpiry.fulfill() })
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        dictation.stubbedError = DictationError.authenticationFailed
        await pipeline.retryDictation()
        await fulfillment(of: [secondExpiry], timeout: 2)

        let state = await coordinator.state
        XCTAssertEqual(state, .sessionExpired)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testCancelledRetryCannotResetOrPublishIntoReplacementRecording() async {
        let batch = GatedRetryBatchProvider()
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("realtime failed")
        let audio = makeStreamingAudioProvider()
        let injector = MockTextInjector()
        let transcriptBuffer = TranscriptBuffer()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer)

        await pipeline.activate()
        let firstSetupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(firstSetupFinished)
        await pipeline.complete()
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)

        let retryTask = Task { await pipeline.retryDictation() }
        await batch.waitUntilRetryStarts()

        let priorCancelAttemptCount = streaming.cancelAttemptCount
        let cancelProbe = AsyncCompletionProbe()
        let cancelTask = Task {
            await pipeline.cancel()
            await cancelProbe.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > priorCancelAttemptCount
        }
        XCTAssertTrue(cancellationEntered)

        let activationProbe = AsyncCompletionProbe()
        let replacementTask = Task {
            let sessionID = await pipeline.activate()
            await activationProbe.markCompleted()
            return sessionID
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        let cancelCompletedEarly = await cancelProbe.hasCompleted()
        let activationCompletedEarly = await activationProbe.hasCompleted()
        XCTAssertFalse(
            cancelCompletedEarly,
            "Cancellation must drain the owned Retry request")
        XCTAssertFalse(
            activationCompletedEarly,
            "Replacement admission must wait for Retry teardown")
        XCTAssertEqual(audio.startCallCount, 1)

        await batch.releaseRetry()
        await retryTask.value
        await cancelTask.value
        let replacementSessionID = await replacementTask.value

        let replacementState = await coordinator.state
        let latestTranscript = await transcriptBuffer.lastTranscript
        XCTAssertNotNil(replacementSessionID)
        XCTAssertEqual(replacementState, .recording)
        XCTAssertNil(latestTranscript)
        XCTAssertEqual(injector.injectionCount, 0)

        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
    }

    func testCancelledLocalRetryDrainsBeforeReplacementProviderStart() async {
        let sourcePCM = makeNonSilentPCMChunk(sampleCount: 1_600)
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "stale retry")
        streaming.stubbedSendError = DictationError.networkError("initial send failed")
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: MockTextInjector(),
            coordinator: coordinator)

        guard let failedSessionID = await pipeline.activate() else {
            return XCTFail("Expected initial session admission")
        }
        let initialSetupFinished = await waitUntil {
            streaming.startCallCount == 1
        }
        XCTAssertTrue(initialSetupFinished)
        audio.emitPCMChunk(sourcePCM)
        let sendFailed = await waitUntil { streaming.sendCallCount == 1 }
        XCTAssertTrue(sendFailed)
        await pipeline.complete(sessionID: failedSessionID)
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)

        streaming.stubbedSendError = nil
        let retryReplayGate = SuspensionGate()
        streaming.replayCapturedAudioHook = {
            await retryReplayGate.waitForRelease()
        }
        let retryTask = Task {
            await pipeline.retryDictation(sessionID: failedSessionID)
        }
        await retryReplayGate.waitUntilEntered()
        XCTAssertEqual(streaming.replayCallCount, 1)

        let priorCancelAttemptCount = streaming.cancelAttemptCount
        let cancelProbe = AsyncCompletionProbe()
        let cancelTask = Task {
            await pipeline.cancel(sessionID: failedSessionID)
            await cancelProbe.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > priorCancelAttemptCount
        }
        XCTAssertTrue(cancellationEntered)

        let activationProbe = AsyncCompletionProbe()
        let replacementTask = Task {
            let sessionID = await pipeline.activate()
            await activationProbe.markCompleted()
            return sessionID
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        let cancelCompletedEarly = await cancelProbe.hasCompleted()
        let activationCompletedEarly = await activationProbe.hasCompleted()
        XCTAssertFalse(cancelCompletedEarly)
        XCTAssertFalse(activationCompletedEarly)
        XCTAssertEqual(
            streaming.startCallCount,
            1,
            "Replacement local setup must not overlap a stale Retry replay")

        await retryReplayGate.release()
        await retryTask.value
        await cancelTask.value
        let replacementSessionID = await replacementTask.value

        XCTAssertNotNil(replacementSessionID)
        let replacementStarted = await waitUntil {
            streaming.startCallCount == 2
        }
        XCTAssertTrue(replacementStarted)
        let replacementState = await coordinator.state
        XCTAssertEqual(replacementState, .recording)
        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
    }

    func testCancellationAfterRetryInjectionStartsWaitsBeforeReplacementActivation()
        async
    {
        let batch = GatedRetryBatchProvider()
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError(
            "realtime failed")
        let audio = makeStreamingAudioProvider()
        let injector = GatedTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator)

        _ = await pipeline.activate()
        let setupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(setupFinished)
        await pipeline.complete()
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)

        let retryTask = Task { await pipeline.retryDictation() }
        await batch.waitUntilRetryStarts()
        await batch.releaseRetry()
        await injector.waitUntilInjectionStarts()

        let priorCancelAttemptCount = streaming.cancelAttemptCount
        let cancelProbe = AsyncCompletionProbe()
        let cancelTask = Task {
            await pipeline.cancel()
            await cancelProbe.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelAttemptCount > priorCancelAttemptCount
        }
        XCTAssertTrue(cancellationEntered)

        let activationProbe = AsyncCompletionProbe()
        let replacementTask = Task {
            _ = await pipeline.activate()
            await activationProbe.markCompleted()
        }

        for _ in 0..<100 {
            await Task.yield()
        }
        let cancelCompletedEarly = await cancelProbe.hasCompleted()
        let activationCompletedEarly = await activationProbe.hasCompleted()
        let writesBeforeRelease = await injector.injectionCount
        XCTAssertFalse(cancelCompletedEarly)
        XCTAssertFalse(activationCompletedEarly)
        XCTAssertEqual(writesBeforeRelease, 0)

        await injector.releaseInjection()
        await retryTask.value
        await cancelTask.value
        await replacementTask.value

        let finalWriteCount = await injector.injectionCount
        let replacementState = await coordinator.state
        XCTAssertEqual(finalWriteCount, 1)
        XCTAssertEqual(replacementState, .recording)
        await pipeline.cancel()
    }

    func testRetirementDoesNotJoinCancellationInsensitiveRetryContextRead() async {
        let context = CancellationInsensitiveSecondContextProvider()
        let batch = MockBatchProvider()
        batch.stubbedError = DictationError.networkError("initial fallback failed")
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("realtime failed")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let audio = makeStreamingAudioProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            backend: .cloud(realtime: streaming, fallback: batch),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            contextObservationTimeout: 0.01)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let setupFinished = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(setupFinished)
        await pipeline.complete(sessionID: sessionID)
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)

        batch.stubbedError = nil
        batch.stubbedText = "accepted retry text"
        let retryTask = Task {
            await pipeline.retryDictation(sessionID: sessionID)
        }
        await context.waitUntilSecondReadEnters()

        let retirementReturned = expectation(
            description: "retirement ignores hung observational context read")
        let retireTask = Task {
            await pipeline.retire()
            retirementReturned.fulfill()
        }
        let waiterResult = await XCTWaiter().fulfillment(
            of: [retirementReturned], timeout: 0.75)

        await context.releaseSecondRead()
        await retryTask.value
        await retireTask.value

        XCTAssertEqual(waiterResult, .completed)
        XCTAssertEqual(injector.injectionCount, 0)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testRetirementDoesNotJoinCancellationInsensitiveBufferedRetryContextRead()
        async
    {
        let context = CancellationInsensitiveSecondContextProvider()
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider(stubbedText: "preserved retry text")
        let coordinator = RecordingCoordinator()
        let audio = makeStreamingAudioProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            transcriptBuffer: buffer,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            contextObservationTimeout: 0.01)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let setupFinished = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(setupFinished)
        await pipeline.complete(sessionID: sessionID)
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .injectionFailed)

        injector.stubbedError = nil
        let retryTask = Task {
            await pipeline.retryBufferedInjection(sessionID: sessionID)
        }
        await context.waitUntilSecondReadEnters()

        let retirementReturned = expectation(
            description: "retirement ignores hung buffered-retry context read")
        let retireTask = Task {
            await pipeline.retire()
            retirementReturned.fulfill()
        }
        let waiterResult = await XCTWaiter().fulfillment(
            of: [retirementReturned], timeout: 0.75)

        await context.releaseSecondRead()
        await retryTask.value
        await retireTask.value

        XCTAssertEqual(waiterResult, .completed)
        XCTAssertEqual(injector.injectionCount, 0)
        let preserved = await buffer.lastTranscript
        XCTAssertEqual(preserved, "preserved retry text")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testStaleDictationDismissCannotRevokeAcceptedRetryInjection() async {
        let batch = GatedRetryBatchProvider()
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError(
            "realtime failed")
        let audio = makeStreamingAudioProvider()
        let injector = GatedTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator)

        guard let failedSessionID = await pipeline.activate() else {
            return XCTFail("Expected initial session admission")
        }
        let setupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(setupFinished)
        await pipeline.complete(sessionID: failedSessionID)
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)

        let retryTask = Task {
            await pipeline.retryDictation(sessionID: failedSessionID)
        }
        await batch.waitUntilRetryStarts()
        await batch.releaseRetry()
        await injector.waitUntilInjectionStarts()

        // Retry has atomically claimed the failed session. A delayed Dismiss
        // action from the old failure UI must not revoke that ownership while
        // target publication is already in flight.
        await pipeline.dismissDictationFailure(sessionID: failedSessionID)

        let stateAfterStaleDismiss = await coordinator.state
        let ownerAfterStaleDismiss = await pipeline.currentSessionID
        XCTAssertEqual(stateAfterStaleDismiss, .injecting)
        XCTAssertEqual(ownerAfterStaleDismiss, failedSessionID)

        let replacementSessionID = await pipeline.activate()
        XCTAssertNil(
            replacementSessionID,
            "Replacement capture must wait for the accepted retry publication")

        await injector.releaseInjection()
        await retryTask.value

        let finalState = await coordinator.state
        let finalOwner = await pipeline.currentSessionID
        let injectionCount = await injector.injectionCount
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalOwner)
        XCTAssertEqual(injectionCount, 1)

        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
    }

    func testDuplicateAuthenticationRecoveryCannotRevokeAcceptedRetryInjection()
        async
    {
        let batch = GatedRetryBatchProvider(
            initialError: .authenticationFailed,
            retryResult: "recovered after authentication")
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError(
            "realtime failed")
        let audio = makeStreamingAudioProvider()
        let injector = GatedTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator)

        guard let expiredSessionID = await pipeline.activate() else {
            return XCTFail("Expected initial session admission")
        }
        let setupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(setupFinished)
        await pipeline.complete(sessionID: expiredSessionID)
        let expiredState = await coordinator.state
        XCTAssertEqual(expiredState, .sessionExpired)

        await pipeline.presentRecoveryAfterAuthentication()
        let retryReadyState = await coordinator.state
        XCTAssertEqual(retryReadyState, .dictationFailed)

        let retryTask = Task {
            await pipeline.retryDictation(sessionID: expiredSessionID)
        }
        await batch.waitUntilRetryStarts()
        await batch.releaseRetry()
        await injector.waitUntilInjectionStarts()

        // A duplicate completion from the authentication UI is stale once Retry
        // has claimed the session and crossed the publication boundary.
        await pipeline.presentRecoveryAfterAuthentication()

        let stateAfterDuplicateRecovery = await coordinator.state
        let ownerAfterDuplicateRecovery = await pipeline.currentSessionID
        XCTAssertEqual(stateAfterDuplicateRecovery, .injecting)
        XCTAssertEqual(ownerAfterDuplicateRecovery, expiredSessionID)

        let replacementSessionID = await pipeline.activate()
        XCTAssertNil(
            replacementSessionID,
            "Replacement capture must wait for the accepted retry publication")

        await injector.releaseInjection()
        await retryTask.value

        let finalState = await coordinator.state
        let finalOwner = await pipeline.currentSessionID
        let injectionCount = await injector.injectionCount
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalOwner)
        XCTAssertEqual(injectionCount, 1)

        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
    }

    func testFallbackAndRetryRetainActivationLanguage() async {
        let batch = MockBatchProvider(stubbedText: "recovered")
        batch.stubbedError = DictationError.networkError("fallback failed")
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("realtime failed")
        let (pipeline, audio, _, _, _, injector, coordinator) =
            makeStreamingPipeline(
                batchProvider: batch,
                streamingProvider: streaming)

        await pipeline.setLanguage("en")
        await pipeline.activate()
        let setupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(setupFinished)

        await pipeline.setLanguage("fr")
        await pipeline.complete()
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)

        batch.stubbedError = nil
        await pipeline.setLanguage("de")
        await pipeline.retryDictation()

        XCTAssertEqual(batch.receivedLanguages, ["en", "en"])
        XCTAssertEqual(injector.injectionCount, 1)
    }

    // MARK: - Audio setup failure during complete

    func testReleaseBeforeCaptureReadySurfacesNonRetryableFailure() async {
        // The release boundary wins even if a delayed audio start later fails.
        // The HUD must surface the missed capture instead of silently returning
        // idle or offering a Retry that has no accepted WAV to replay.
        let audio = makeStreamingAudioProvider()
        audio.stubbedStartDelay = 1.0
        audio.stubbedStartError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "BT negotiation failed"])

        let coordinator = RecordingCoordinator()
        let (pipeline, _, _, _, _, injector, _) = makeStreamingPipeline(
            audioProvider: audio, coordinator: coordinator)

        guard let sessionID = await pipeline.activate() else {
            XCTFail("Expected activation")
            return
        }
        let state1 = await coordinator.state
        XCTAssertEqual(state1, .recording)

        // complete() while audio setup is still sleeping for 1s.
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .dictationFailed,
            "A release before live capture must surface an explicit failure")
        let canRetry = await pipeline.canRetryDictation(sessionID: sessionID)
        XCTAssertFalse(canRetry)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "No text should be injected when audio setup fails")
    }
}

private actor GatedTextInjector: TextInjecting {
    private var injectionStarted = false
    private var injectionReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var injectionCount = 0

    func inject(text: String, into context: AppContext) async throws {
        injectionStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }

        if !injectionReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        injectionCount += 1
    }

    func waitUntilInjectionStarts() async {
        guard !injectionStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseInjection() {
        guard !injectionReleased else { return }
        injectionReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private actor PipelineSendGate {
    private var firstSendStarted = false
    private var firstSendReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sentChunks: [Data] = []

    func send(_ data: Data) async {
        sentChunks.append(data)
        guard sentChunks.count == 1 else { return }
        firstSendStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        guard !firstSendReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilFirstSendStarts() async {
        guard !firstSendStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstSend() {
        guard !firstSendReleased else { return }
        firstSendReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor CancellationInsensitiveBatchProvider: BatchDictationProviding {
    private let firstResult: String
    private let retryResult: String
    private var firstCallStarted = false
    private var firstCallReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var receivedAudio: [Data] = []

    init(firstResult: String, retryResult: String) {
        self.firstResult = firstResult
        self.retryResult = retryResult
    }

    func dictate(
        audio: Data, context: AppContext, language: String?
    ) async throws -> String {
        receivedAudio.append(audio)
        guard receivedAudio.count == 1 else { return retryResult }

        firstCallStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }

        if !firstCallReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return firstResult
    }

    func waitUntilFirstCallStarts() async {
        guard !firstCallStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstCallIfStarted() {
        guard firstCallStarted, !firstCallReleased else { return }
        firstCallReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private actor CancellationInsensitiveAuthenticationFailureProvider:
    BatchDictationProviding
{
    private var callStarted = false
    private var callReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func dictate(
        audio: Data, context: AppContext, language: String?
    ) async throws -> String {
        callStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }

        if !callReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        throw DictationError.authenticationFailed
    }

    func waitUntilCallStarts() async {
        guard !callStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseCallIfStarted() {
        guard callStarted, !callReleased else { return }
        callReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private actor GatedRetryBatchProvider: BatchDictationProviding {
    private let initialError: DictationError
    private let retryResult: String
    private var callCount = 0
    private var retryStarted = false
    private var retryReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        initialError: DictationError = .networkError("initial fallback failed"),
        retryResult: String = "stale retry result"
    ) {
        self.initialError = initialError
        self.retryResult = retryResult
    }

    func dictate(
        audio: Data, context: AppContext, language: String?
    ) async throws -> String {
        callCount += 1
        guard callCount > 1 else {
            throw initialError
        }

        retryStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }

        if !retryReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return retryResult
    }

    func waitUntilRetryStarts() async {
        guard !retryStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseRetry() {
        guard !retryReleased else { return }
        retryReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}
