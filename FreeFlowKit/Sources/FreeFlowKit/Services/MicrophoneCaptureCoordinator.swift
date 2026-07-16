import Foundation

/// The owner-scoped capture surface needed by microphone preview clients.
public protocol MicrophoneCaptureBackend: Sendable {
    func startCapture(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration
    ) async throws

    func stopCapture(owner: AudioCaptureOwner) async throws -> AudioBuffer
    func audioLevelStream(
        owner: AudioCaptureOwner
    ) async -> AsyncStream<Float>?
    func forceReset(owner: AudioCaptureOwner) async -> Bool
}

/// Adapts the app's capture provider without exposing it to preview clients.
public struct AudioProvidingMicrophoneCaptureBackend:
    MicrophoneCaptureBackend,
    Sendable
{
    private let audioProvider: any AudioProviding

    public init(audioProvider: any AudioProviding) {
        self.audioProvider = audioProvider
    }

    public func startCapture(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration
    ) async throws {
        try await audioProvider.startRecording(
            owner: owner,
            configuration: configuration,
            releaseBoundary: nil,
            onCaptureReady: {})
    }

    public func stopCapture(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        try await audioProvider.stopRecording(owner: owner)
    }

    public func audioLevelStream(
        owner: AudioCaptureOwner
    ) async -> AsyncStream<Float>? {
        audioProvider.audioLevelStream(owner: owner)
    }

    public func forceReset(owner: AudioCaptureOwner) async -> Bool {
        audioProvider.forceReset(owner: owner)
    }
}

public enum MicrophoneCaptureCoordinatorError: Error, Equatable, Sendable {
    case coordinatorShutdown
    case deviceSelectionSuperseded
    case deviceSelectionUnavailable
}

/// One exact demand for the shared microphone preview capture.
///
/// Copies remain safe: only the first release of the opaque demand token can
/// mutate coordinator state.
public struct MicrophoneCaptureLease: Sendable {
    public let audioLevels: AsyncStream<Float>
    public let captureAvailability: AsyncStream<Bool>

    private let releaseAction: @Sendable () async throws -> Bool

    init(
        audioLevels: AsyncStream<Float>,
        captureAvailability: AsyncStream<Bool>,
        releaseAction: @escaping @Sendable () async throws -> Bool
    ) {
        self.audioLevels = audioLevels
        self.captureAvailability = captureAvailability
        self.releaseAction = releaseAction
    }

    /// Releases only this lease. Repeated or stale releases return `false`.
    @discardableResult
    public func release() async throws -> Bool {
        try await releaseAction()
    }
}

/// Multiplexes preview demand onto one quiet, meter-only capture owner.
///
/// Dictation keeps its own owner-scoped provider demand. The capture provider
/// promotes that demand on its existing physical tap while this coordinator
/// retains the preview owner and every preview client's level stream.
public actor MicrophoneCaptureCoordinator {
    public typealias DeviceSelection =
        @Sendable (UInt32?) async throws -> Void
    public typealias DeviceSelectionTransaction =
        @Sendable (
            @escaping @Sendable () async throws -> Void
        ) async throws -> Void

    private enum PreviewRecoveryContext: Equatable, Sendable {
        /// The selected device is stable. Owner-scoped capture can restart
        /// alongside dictation because the provider supports both demands.
        case stream(deviceGeneration: UInt64)

        /// A device-change transaction failed after preview was stopped. Every
        /// later restart must reacquire dictation quiescence until superseded.
        case deviceSelection(generation: UInt64)

        var deviceGeneration: UInt64 {
            switch self {
            case .stream(let generation), .deviceSelection(let generation):
                generation
            }
        }
    }

    private struct LeaseRecord {
        let levelContinuation: AsyncStream<Float>.Continuation
        let availabilityContinuation: AsyncStream<Bool>.Continuation
    }

    private let backend: any MicrophoneCaptureBackend
    private let selectDeviceOperation: DeviceSelection?
    private let withDeviceSelectionTransaction: DeviceSelectionTransaction
    private let previewRecoveryDelay:
        @Sendable (_ nanoseconds: UInt64) async throws -> Void

    private var leases: [UUID: LeaseRecord] = [:]
    private var operationTail: Task<Void, Never>?
    private var operationCancellations: [UUID: @Sendable () -> Void] = [:]
    private var levelForwardingTask: Task<Void, Never>?
    private var previewRecoveryTask: Task<Void, Never>?
    private var previewRecoveryGeneration: UUID?
    private var previewRecoveryContext: PreviewRecoveryContext?
    private var previewRecoveryAttempt = 0
    private var captureGeneration: UUID?
    private var deviceRequestGeneration: UInt64 = 0
    private var isShutdown = false

    private(set) var activeOwner: AudioCaptureOwner?
    private(set) var latestAudioLevel: Float?
    private(set) var requestedDeviceID: UInt32?
    private(set) var selectedDeviceID: UInt32?

    public init(
        backend: any MicrophoneCaptureBackend,
        withDeviceSelectionTransaction: @escaping DeviceSelectionTransaction = {
            operation in
            try await operation()
        },
        selectDevice: DeviceSelection? = nil,
        previewRecoveryDelay: (
            @Sendable (_ nanoseconds: UInt64) async throws -> Void
        )? = nil
    ) {
        self.backend = backend
        self.withDeviceSelectionTransaction = withDeviceSelectionTransaction
        selectDeviceOperation = selectDevice
        self.previewRecoveryDelay = previewRecoveryDelay ?? { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    /// Production adapter. The transaction must seal new dictation admission,
    /// drain an existing dictation, and remain held until preview is restarted.
    public init(
        audioProvider: any AudioProviding,
        audioDeviceProvider: any AudioDeviceProviding,
        withDeviceSelectionTransaction: @escaping DeviceSelectionTransaction
    ) {
        backend = AudioProvidingMicrophoneCaptureBackend(
            audioProvider: audioProvider)
        self.withDeviceSelectionTransaction = withDeviceSelectionTransaction
        previewRecoveryDelay = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        selectDeviceOperation = { id in
            if let id {
                try await audioDeviceProvider.selectDevice(id: id)
            } else {
                audioDeviceProvider.clearSelection()
            }
        }
    }

    /// Acquires an independent newest-value meter stream. All preview leases
    /// share the current physical preview demand. Physical restarts rotate to a
    /// fresh provider owner without invalidating these logical leases.
    public func acquirePreview() async throws -> MicrophoneCaptureLease {
        guard !isShutdown else {
            throw MicrophoneCaptureCoordinatorError.coordinatorShutdown
        }
        let leaseID = UUID()
        let deviceGeneration = deviceRequestGeneration
        let lease = try await serialized { [self] in
            try await installPreviewLease(
                id: leaseID,
                deviceGeneration: deviceGeneration)
        }

        guard !Task.isCancelled else {
            let cleanupDeviceGeneration = deviceRequestGeneration
            _ = try? await serialized { [self] in
                try await removePreviewLease(
                    id: leaseID,
                    deviceGeneration: cleanupDeviceGeneration)
            }
            throw CancellationError()
        }
        return lease
    }

    /// Applies device changes after dictation drains. Concurrent requests are
    /// coalesced by generation; only the latest request restarts preview.
    public func selectDevice(id: UInt32?) async throws {
        guard !isShutdown else {
            throw MicrophoneCaptureCoordinatorError.coordinatorShutdown
        }
        deviceRequestGeneration &+= 1
        let generation = deviceRequestGeneration
        requestedDeviceID = id

        try await serialized { [self] in
            try await applyDeviceSelection(id: id, generation: generation)
        }
        try Task.checkCancellation()
    }

    /// Releases all preview demand and drains the shared backend owner.
    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        deviceRequestGeneration &+= 1
        let generation = deviceRequestGeneration
        let cancellations = Array(operationCancellations.values)
        cancellations.forEach { $0() }
        _ = try? await serialized { [self] in
            try await performShutdown(deviceGeneration: generation)
        }
    }

    private func performShutdown(deviceGeneration: UInt64) async throws {
        let records = Array(leases.values)
        leases.removeAll()
        records.forEach {
            $0.levelContinuation.finish()
            $0.availabilityContinuation.finish()
        }
        try await reconcilePreviewDemand(
            fallbackDeviceGeneration: deviceGeneration)
    }

    private func installPreviewLease(
        id: UUID,
        deviceGeneration: UInt64
    ) async throws -> MicrophoneCaptureLease {
        guard !isShutdown else {
            throw MicrophoneCaptureCoordinatorError.coordinatorShutdown
        }
        let levelPair = AsyncStream<Float>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let availabilityPair = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        leases[id] = LeaseRecord(
            levelContinuation: levelPair.continuation,
            availabilityContinuation: availabilityPair.continuation)

        do {
            try await reconcilePreviewDemand(
                fallbackDeviceGeneration: deviceGeneration)
            availabilityPair.continuation.yield(activeOwner != nil)
        } catch {
            if let record = leases.removeValue(forKey: id) {
                record.levelContinuation.finish()
                record.availabilityContinuation.finish()
            }
            if !previewDemandNeedsRecovery {
                cancelPreviewRecovery(resetAttempt: true)
            }
            throw error
        }

        return MicrophoneCaptureLease(
            audioLevels: levelPair.stream,
            captureAvailability: availabilityPair.stream,
            releaseAction: { [weak self] in
                guard let self else { return false }
                return try await self.releaseLease(id: id)
            })
    }

    private func releaseLease(id: UUID) async throws -> Bool {
        let deviceGeneration = deviceRequestGeneration
        return try await serialized { [self] in
            try await removePreviewLease(
                id: id,
                deviceGeneration: deviceGeneration)
        }
    }

    private func removePreviewLease(
        id: UUID,
        deviceGeneration: UInt64
    ) async throws -> Bool {
        guard leases[id] != nil else { return false }

        if let record = leases.removeValue(forKey: id) {
            record.levelContinuation.finish()
            record.availabilityContinuation.finish()
        }
        try await reconcilePreviewDemand(
            fallbackDeviceGeneration: deviceGeneration)
        return true
    }

    private func applyDeviceSelection(
        id: UInt32?,
        generation: UInt64
    ) async throws {
        guard let selectDeviceOperation else {
            throw MicrophoneCaptureCoordinatorError.deviceSelectionUnavailable
        }
        try ensureLatestDeviceRequest(generation)

        do {
            try await withDeviceSelectionTransaction { [self] in
                do {
                    try await performDeviceSelection(
                        id: id,
                        generation: generation,
                        selectDevice: selectDeviceOperation)
                } catch {
                    // Selection and preview restart are one capture
                    // transaction. Restore this logical preview demand before
                    // reopening dictation admission, while preserving the
                    // original selection error for the caller.
                    if await generation == deviceRequestGeneration {
                        try? await reconcilePreviewDemand(
                            recoveryContext: .deviceSelection(
                                generation: generation),
                            fallbackDeviceGeneration: generation,
                            insideDeviceSelectionTransaction: true)
                    }
                    throw error
                }
            }
        } catch {
            // A transaction wrapper may reject before invoking its operation.
            // This can follow a superseded request that already stopped the
            // preview, so reacquire the barrier instead of restoring outside it.
            if previewDemandNeedsRecovery,
                generation == deviceRequestGeneration
            {
                try? await withDeviceSelectionTransaction { [self] in
                    try await ensureLatestDeviceRequest(generation)
                    try await reconcilePreviewDemand(
                        recoveryContext: .deviceSelection(
                            generation: generation),
                        fallbackDeviceGeneration: generation,
                        insideDeviceSelectionTransaction: true)
                }
            }
            if previewDemandNeedsRecovery,
                generation == deviceRequestGeneration
            {
                schedulePreviewRecovery(
                    context: .deviceSelection(generation: generation))
            }
            throw error
        }
    }

    private func performDeviceSelection(
        id: UInt32?,
        generation: UInt64,
        selectDevice: DeviceSelection
    ) async throws {
        try ensureLatestDeviceRequest(generation)
        if activeOwner != nil {
            try await stopPreviewCapture()
        }
        try ensureLatestDeviceRequest(generation)

        try await selectDevice(id)
        try ensureLatestDeviceRequest(generation)
        selectedDeviceID = id
        try await reconcilePreviewDemand(
            recoveryContext: .deviceSelection(generation: generation),
            fallbackDeviceGeneration: generation,
            insideDeviceSelectionTransaction: true)
        if previewDemandNeedsRecovery {
            schedulePreviewRecovery(
                context: .deviceSelection(generation: generation))
        }
        try ensureLatestDeviceRequest(generation)
    }

    private func ensureLatestDeviceRequest(_ generation: UInt64) throws {
        guard generation == deviceRequestGeneration else {
            throw MicrophoneCaptureCoordinatorError.deviceSelectionSuperseded
        }
    }

    private func reconcilePreviewDemand(
        recoveryContext requestedRecoveryContext: PreviewRecoveryContext? = nil,
        fallbackDeviceGeneration: UInt64,
        insideDeviceSelectionTransaction: Bool = false
    ) async throws {
        let wantsPreview = !leases.isEmpty && !isShutdown
        if wantsPreview, activeOwner == nil {
            let recoveryContext =
                requestedRecoveryContext ?? previewRecoveryContext
                ?? .stream(deviceGeneration: fallbackDeviceGeneration)
            cancelPreviewRecovery(resetAttempt: false)
            do {
                if insideDeviceSelectionTransaction {
                    try ensureLatestDeviceRequest(
                        recoveryContext.deviceGeneration)
                    try await startPreviewCapture(
                        deviceGeneration: recoveryContext.deviceGeneration)
                } else {
                    try await recoverPreviewDemand(context: recoveryContext)
                }
            } catch {
                if previewDemandNeedsRecovery {
                    schedulePreviewRecovery(context: recoveryContext)
                }
                throw error
            }
            if previewDemandNeedsRecovery {
                schedulePreviewRecovery(context: recoveryContext)
            }
        } else if !wantsPreview, activeOwner != nil {
            cancelPreviewRecovery(resetAttempt: true)
            try await stopPreviewCapture()
        } else if !wantsPreview {
            cancelPreviewRecovery(resetAttempt: true)
        }
    }

    private var previewDemandNeedsRecovery: Bool {
        !leases.isEmpty && !isShutdown && activeOwner == nil
    }

    private func startPreviewCapture(
        deviceGeneration: UInt64
    ) async throws {
        guard deviceGeneration == deviceRequestGeneration else { return }
        let owner = AudioCaptureOwner.preview()
        do {
            try await backend.startCapture(
                owner: owner,
                configuration: .previewMetering)
        } catch {
            _ = await backend.forceReset(owner: owner)
            throw error
        }
        guard deviceGeneration == deviceRequestGeneration else {
            _ = await backend.forceReset(owner: owner)
            return
        }

        let stream = await backend.audioLevelStream(owner: owner)
        guard deviceGeneration == deviceRequestGeneration else {
            _ = await backend.forceReset(owner: owner)
            return
        }
        guard let stream else {
            _ = await backend.forceReset(owner: owner)
            return
        }

        let generation = UUID()
        captureGeneration = generation
        activeOwner = owner
        latestAudioLevel = nil
        startLevelForwarding(
            stream: stream,
            owner: owner,
            generation: generation,
            deviceGeneration: deviceGeneration)
        publishCaptureAvailability(true)
    }

    private func stopPreviewCapture() async throws {
        guard let owner = activeOwner else { return }

        activeOwner = nil
        captureGeneration = nil
        publishCaptureAvailability(false)
        levelForwardingTask?.cancel()
        levelForwardingTask = nil

        do {
            _ = try await backend.stopCapture(owner: owner)
        } catch {
            _ = await backend.forceReset(owner: owner)
            throw error
        }
    }

    private func startLevelForwarding(
        stream: AsyncStream<Float>,
        owner: AudioCaptureOwner,
        generation: UUID,
        deviceGeneration: UInt64
    ) {
        levelForwardingTask?.cancel()
        levelForwardingTask = Task.detached { [weak self] in
            for await level in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.publish(
                    level,
                    owner: owner,
                    generation: generation)
            }
            guard !Task.isCancelled, let self else { return }
            await self.levelStreamFinished(
                owner: owner,
                generation: generation,
                deviceGeneration: deviceGeneration)
        }
    }

    private func levelStreamFinished(
        owner: AudioCaptureOwner,
        generation: UUID,
        deviceGeneration: UInt64
    ) async {
        _ = try? await serialized { [self] in
            await discardUnavailablePreviewCapture(
                owner: owner,
                generation: generation,
                deviceGeneration: deviceGeneration)
        }
    }

    private func discardUnavailablePreviewCapture(
        owner: AudioCaptureOwner,
        generation: UUID,
        deviceGeneration: UInt64
    ) async {
        guard activeOwner == owner, captureGeneration == generation else {
            return
        }

        activeOwner = nil
        captureGeneration = nil
        publishCaptureAvailability(false)
        levelForwardingTask = nil
        latestAudioLevel = nil
        _ = await backend.forceReset(owner: owner)
        schedulePreviewRecovery(
            context: .stream(deviceGeneration: deviceGeneration))
    }

    private func schedulePreviewRecovery(context: PreviewRecoveryContext) {
        guard previewDemandNeedsRecovery else { return }
        if previewRecoveryTask != nil {
            guard case .deviceSelection = context,
                case .stream? = previewRecoveryContext
            else { return }
            cancelPreviewRecovery(resetAttempt: false)
        }

        previewRecoveryAttempt = min(previewRecoveryAttempt + 1, 8)
        let exponent = min(previewRecoveryAttempt - 1, 6)
        let delayNanoseconds = UInt64(10_000_000) << UInt64(exponent)
        let generation = UUID()
        previewRecoveryGeneration = generation
        previewRecoveryContext = context
        let delay = previewRecoveryDelay
        previewRecoveryTask = Task { [weak self] in
            do {
                try await delay(delayNanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.runScheduledPreviewRecovery(generation: generation)
        }
    }

    private func runScheduledPreviewRecovery(generation: UUID) async {
        guard previewRecoveryGeneration == generation,
            let context = previewRecoveryContext
        else { return }
        previewRecoveryGeneration = nil
        previewRecoveryTask = nil
        previewRecoveryContext = nil
        guard previewDemandNeedsRecovery else { return }

        do {
            try await serialized { [self] in
                try await recoverPreviewDemand(context: context)
            }
        } catch {
            schedulePreviewRecovery(context: context)
        }
    }

    private func recoverPreviewDemand(
        context: PreviewRecoveryContext
    ) async throws {
        guard previewDemandNeedsRecovery else { return }
        switch context {
        case .stream(let generation):
            try await startPreviewCapture(deviceGeneration: generation)
            if previewDemandNeedsRecovery {
                schedulePreviewRecovery(context: context)
            }
        case .deviceSelection(let generation):
            guard generation == deviceRequestGeneration else {
                schedulePreviewRecovery(
                    context: .deviceSelection(
                        generation: deviceRequestGeneration))
                return
            }
            try await withDeviceSelectionTransaction { [self] in
                try await ensureLatestDeviceRequest(generation)
                guard await previewDemandNeedsRecovery else { return }
                try await startPreviewCapture(deviceGeneration: generation)
            }
            if previewDemandNeedsRecovery {
                schedulePreviewRecovery(context: context)
            }
        }
    }

    private func cancelPreviewRecovery(resetAttempt: Bool) {
        previewRecoveryTask?.cancel()
        previewRecoveryTask = nil
        previewRecoveryGeneration = nil
        previewRecoveryContext = nil
        if resetAttempt {
            previewRecoveryAttempt = 0
        }
    }

    private func publish(
        _ level: Float,
        owner: AudioCaptureOwner,
        generation: UUID
    ) {
        guard activeOwner == owner, captureGeneration == generation else {
            return
        }
        previewRecoveryAttempt = 0
        latestAudioLevel = level
        for record in leases.values {
            record.levelContinuation.yield(level)
        }
    }

    private func publishCaptureAvailability(_ isAvailable: Bool) {
        for record in leases.values {
            record.availabilityContinuation.yield(isAvailable)
        }
    }

    private func serialized<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let operationID = UUID()
        let predecessor = operationTail
        let task = Task<Value, Error> {
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        operationCancellations[operationID] = { task.cancel() }
        operationTail = Task {
            _ = await task.result
        }
        do {
            // Caller cancellation must not split an admitted capture operation
            // from its exact cleanup. Shutdown cancels registered operations
            // explicitly; ordinary callers drain, then perform owner cleanup.
            let value = try await task.value
            operationCancellations[operationID] = nil
            return value
        } catch {
            operationCancellations[operationID] = nil
            throw error
        }
    }
}
