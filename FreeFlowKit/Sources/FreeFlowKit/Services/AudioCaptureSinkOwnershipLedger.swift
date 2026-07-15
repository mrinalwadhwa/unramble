import Foundation

/// Generational ownership for provider state shared by tap callbacks and stop.
/// A delayed stop may clean up only the sinks allocated by its own capture.
final class AudioCaptureSinkOwnershipLedger<Token: Equatable & Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var owner: Token?

    var hasOwner: Bool {
        lock.withLock { owner != nil }
    }

    @discardableResult
    func begin(_ token: Token) -> Bool {
        lock.withLock {
            guard owner == nil else { return false }
            owner = token
            return true
        }
    }

    func owns(_ token: Token) -> Bool {
        lock.withLock { owner == token }
    }

    @discardableResult
    func finish(_ token: Token) -> Bool {
        lock.withLock {
            guard owner == token else { return false }
            owner = nil
            return true
        }
    }

    func reset() {
        lock.withLock { owner = nil }
    }
}
