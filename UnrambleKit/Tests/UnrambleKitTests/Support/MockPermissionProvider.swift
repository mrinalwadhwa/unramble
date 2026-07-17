import Foundation

@testable import UnrambleKit

/// A configurable mock to test code that depends on system permissions.
///
/// All permission states default to `.granted` so tests that don't care about
/// permissions can ignore this entirely. Tests that exercise permission-denied
/// paths can set the relevant state before use.
public final class MockPermissionProvider: PermissionProviding, @unchecked Sendable {

    private let lock = NSLock()

    private var _microphoneState: PermissionState
    private var _accessibilityState: PermissionState
    private var _openedAccessibilitySettings = false

    public init(
        microphoneState: PermissionState = .granted,
        accessibilityState: PermissionState = .granted
    ) {
        self._microphoneState = microphoneState
        self._accessibilityState = accessibilityState
    }

    // MARK: - Configuration

    public var microphoneState: PermissionState {
        get { lock.withLock { _microphoneState } }
        set { lock.withLock { _microphoneState = newValue } }
    }

    public var accessibilityState: PermissionState {
        get { lock.withLock { _accessibilityState } }
        set { lock.withLock { _accessibilityState = newValue } }
    }

    /// Whether `openAccessibilitySettings()` was called.
    public var didOpenAccessibilitySettings: Bool {
        lock.withLock { _openedAccessibilitySettings }
    }

    // MARK: - PermissionProviding

    public func checkMicrophone() -> PermissionState {
        microphoneState
    }

    public func requestMicrophone() async -> PermissionState {
        // Simulate the system prompt: if not determined, grant; otherwise keep current state.
        if microphoneState == .notDetermined {
            microphoneState = .granted
        }
        return microphoneState
    }

    public func checkAccessibility() -> PermissionState {
        accessibilityState
    }

    public func openAccessibilitySettings() {
        lock.withLock { _openedAccessibilitySettings = true }
    }
}
