import Foundation

/// Owns one UI client's preview lease and every task derived from it.
///
/// Start reserves its generation synchronously on the main actor. A window
/// close can therefore invalidate a queued acquisition before that task runs,
/// and a cancellation-insensitive acquisition that returns late is released.
@MainActor
public final class MicrophonePreviewClient {
    public typealias Eligibility = @MainActor @Sendable () -> Bool
    public typealias AudioLevelHandler = @MainActor @Sendable (Float) -> Void
    public typealias AvailabilityHandler = @MainActor @Sendable (Bool) -> Void

    private let acquirePreview:
        @Sendable () async throws -> MicrophoneCaptureLease

    private var startTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var captureAvailabilityTask: Task<Void, Never>?
    private var lease: MicrophoneCaptureLease?
    private var requestGeneration: UInt64 = 0
    private var audioLevelHandler: AudioLevelHandler?
    private var availabilityHandler: AvailabilityHandler?

    public private(set) var isCaptureAvailable = false

    public init(coordinator: MicrophoneCaptureCoordinator) {
        self.acquirePreview = {
            try await coordinator.acquirePreview()
        }
    }

    init(
        acquirePreview:
            @escaping @Sendable () async throws -> MicrophoneCaptureLease
    ) {
        self.acquirePreview = acquirePreview
    }

    public func start(
        isEligible: @escaping Eligibility,
        onAudioLevel: @escaping AudioLevelHandler,
        onAvailability: @escaping AvailabilityHandler
    ) {
        guard isEligible() else { return }

        audioLevelHandler = onAudioLevel
        availabilityHandler = onAvailability
        guard lease == nil, startTask == nil else {
            onAvailability(isCaptureAvailable)
            return
        }

        requestGeneration &+= 1
        let generation = requestGeneration
        let acquirePreview = acquirePreview
        publishAvailability(false)

        startTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let lease = try await acquirePreview()
                guard let self else {
                    _ = try? await lease.release()
                    return
                }
                guard !Task.isCancelled,
                    generation == self.requestGeneration,
                    self.lease == nil,
                    isEligible()
                else {
                    _ = try? await lease.release()
                    return
                }

                self.startTask = nil
                self.lease = lease
                self.beginForwarding(lease: lease, generation: generation)
            } catch {
                guard let self,
                    generation == self.requestGeneration
                else { return }
                self.startTask = nil
                self.publishAvailability(false)
            }
        }
    }

    public func stop() {
        requestGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        captureAvailabilityTask?.cancel()
        captureAvailabilityTask = nil
        publishAvailability(false)
        audioLevelHandler = nil
        availabilityHandler = nil

        guard let lease else { return }
        self.lease = nil
        Task {
            _ = try? await lease.release()
        }
    }

    private func beginForwarding(
        lease: MicrophoneCaptureLease,
        generation: UInt64
    ) {
        let levelStream = lease.audioLevels
        audioLevelTask = Task { @MainActor [weak self] in
            for await level in levelStream {
                guard !Task.isCancelled,
                    let self,
                    generation == self.requestGeneration,
                    self.isCaptureAvailable
                else { continue }
                self.audioLevelHandler?(level)
            }
        }

        let availabilityStream = lease.captureAvailability
        captureAvailabilityTask = Task { @MainActor [weak self] in
            for await isAvailable in availabilityStream {
                guard !Task.isCancelled,
                    let self,
                    generation == self.requestGeneration
                else { continue }
                self.publishAvailability(isAvailable)
            }
            guard !Task.isCancelled,
                let self,
                generation == self.requestGeneration
            else { return }
            self.publishAvailability(false)
        }
    }

    private func publishAvailability(_ isAvailable: Bool) {
        isCaptureAvailable = isAvailable
        availabilityHandler?(isAvailable)
    }
}
