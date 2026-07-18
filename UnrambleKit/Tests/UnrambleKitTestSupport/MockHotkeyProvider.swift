import Foundation

@testable import UnrambleKit

/// A mock hotkey provider that simulates key events for testing.
///
/// Instead of registering a real CGEventTap, this mock stores the callback
/// and exposes `simulatePress()` / `simulateRelease()` so tests can drive
/// the hotkey flow programmatically.
public final class MockHotkeyProvider: HotkeyProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var callback: (@Sendable (HotkeyEvent) -> Void)?
    private var _isRegistered = false

    public init() {}

    // MARK: - HotkeyProviding

    public func register(callback: @escaping @Sendable (HotkeyEvent) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        self.callback = callback
        _isRegistered = true
    }

    public func unregister() {
        lock.lock()
        defer { lock.unlock() }
        callback = nil
        _isRegistered = false
    }

    // MARK: - Test Helpers

    /// Whether a hotkey listener is currently registered.
    public var isRegistered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRegistered
    }

    /// Simulate a hotkey press event, delivering `.pressed` to the registered callback.
    public func simulatePress() {
        lock.lock()
        let cb = callback
        lock.unlock()
        cb?(.pressed)
    }

    /// Simulate a hotkey release event, delivering `.released` to the registered callback.
    public func simulateRelease() {
        lock.lock()
        let cb = callback
        lock.unlock()
        cb?(.released)
    }
}
