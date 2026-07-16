import Foundation

/// Immutable identity for one consumer of microphone capture.
public enum AudioCaptureOwner: Hashable, Sendable {
    case dictation(DictationSessionID)
    case preview(UUID)

    public static func preview(id: UUID = UUID()) -> Self {
        .preview(id)
    }
}

/// Per-owner capture behavior. This avoids mutating provider-wide feedback
/// state when a settings or onboarding preview starts metering.
public struct AudioCaptureConfiguration: Equatable, Sendable {
    public let retainsPCM: Bool
    public let playsSoundFeedback: Bool

    public init(retainsPCM: Bool, playsSoundFeedback: Bool) {
        self.retainsPCM = retainsPCM
        self.playsSoundFeedback = playsSoundFeedback
    }

    public static let dictation = AudioCaptureConfiguration(
        retainsPCM: true,
        playsSoundFeedback: true)
    public static let previewMetering = AudioCaptureConfiguration(
        retainsPCM: false,
        playsSoundFeedback: false)
}

/// Owner-fenced level and device measurements for a capture generation.
public struct AudioCaptureMetrics: Equatable, Sendable {
    public let peakRMS: Float
    public let ambientRMS: Float
    public let micProximity: MicProximity
    public let gainFactor: Float
    public let deviceName: String

    public init(
        peakRMS: Float,
        ambientRMS: Float,
        micProximity: MicProximity,
        gainFactor: Float,
        deviceName: String
    ) {
        self.peakRMS = peakRMS
        self.ambientRMS = ambientRMS
        self.micProximity = micProximity
        self.gainFactor = gainFactor
        self.deviceName = deviceName
    }
}

/// Independent capture demands. A coordinator can retain preview demand while
/// dictation temporarily becomes the preferred consumer of one physical tap.
public final class AudioCaptureDemandLedger: @unchecked Sendable {
    public struct Termination: Hashable, Sendable {
        fileprivate let owner: AudioCaptureOwner
        fileprivate let id: UUID
    }

    public struct ShutdownSnapshot: Equatable, Sendable {
        public let activeOwners: [AudioCaptureOwner]
        public let terminatingOwners: [AudioCaptureOwner]
    }

    private enum Phase {
        case active
        case terminating(UUID)
    }

    private struct Entry {
        let owner: AudioCaptureOwner
        var phase: Phase
    }

    private let lock = NSLock()
    private var insertionOrder: [Entry] = []
    private var isSealed = false

    public init() {}

    @discardableResult
    public func insert(_ owner: AudioCaptureOwner) -> Bool {
        lock.withLock {
            guard !isSealed,
                !insertionOrder.contains(where: { $0.owner == owner })
            else { return false }
            insertionOrder.append(Entry(owner: owner, phase: .active))
            return true
        }
    }

    @discardableResult
    public func remove(_ owner: AudioCaptureOwner) -> Bool {
        lock.withLock {
            guard let index = insertionOrder.firstIndex(where: {
                $0.owner == owner
            }), case .active = insertionOrder[index].phase
            else {
                return false
            }
            insertionOrder.remove(at: index)
            return true
        }
    }

    public func contains(_ owner: AudioCaptureOwner) -> Bool {
        lock.withLock {
            insertionOrder.contains(where: {
                guard $0.owner == owner, case .active = $0.phase else {
                    return false
                }
                return true
            })
        }
    }

    /// Claim the only terminal finalizer for one active demand.
    @discardableResult
    public func beginTermination(_ owner: AudioCaptureOwner) -> Termination? {
        lock.withLock {
            guard let index = insertionOrder.firstIndex(where: {
                $0.owner == owner
            }), case .active = insertionOrder[index].phase
            else { return nil }
            let id = UUID()
            insertionOrder[index].phase = .terminating(id)
            return Termination(owner: owner, id: id)
        }
    }

    /// Release only the exact terminal claim. A stale completion cannot erase a
    /// later demand even if a caller deliberately reuses an owner value.
    @discardableResult
    public func finishTermination(_ termination: Termination) -> Bool {
        lock.withLock {
            guard let index = insertionOrder.firstIndex(where: {
                guard $0.owner == termination.owner,
                    case .terminating(let id) = $0.phase
                else { return false }
                return id == termination.id
            }) else { return false }
            insertionOrder.remove(at: index)
            return true
        }
    }

    /// Permanently reject new demand and revoke active owners. Owners already
    /// terminating retain their claims until their exact finalizers drain.
    public func sealForShutdown() -> ShutdownSnapshot {
        lock.withLock {
            isSealed = true
            let activeOwners: [AudioCaptureOwner] = insertionOrder.compactMap { entry in
                guard case .active = entry.phase else { return nil }
                return entry.owner
            }
            let terminatingOwners: [AudioCaptureOwner] = insertionOrder.compactMap {
                entry in
                guard case .terminating = entry.phase else { return nil }
                return entry.owner
            }
            insertionOrder.removeAll { entry in
                if case .active = entry.phase { return true }
                return false
            }
            return ShutdownSnapshot(
                activeOwners: activeOwners,
                terminatingOwners: terminatingOwners)
        }
    }

    public var isShutdown: Bool {
        lock.withLock { isSealed }
    }

    /// Test/support reset for ledgers that are not used as permanent provider
    /// lifetime seals.
    @discardableResult
    public func removeAll() -> [AudioCaptureOwner] {
        lock.withLock {
            let owners = insertionOrder.map(\.owner)
            insertionOrder.removeAll(keepingCapacity: false)
            return owners
        }
    }

    /// Dictation has priority while active; otherwise the oldest retained
    /// preview remains the physical-capture candidate.
    public var preferredOwner: AudioCaptureOwner? {
        lock.withLock {
            insertionOrder.last(where: {
                guard case .active = $0.phase else { return false }
                if case .dictation = $0.owner { return true }
                return false
            })?.owner ?? insertionOrder.first(where: {
                if case .active = $0.phase { return true }
                return false
            })?.owner
        }
    }
}
