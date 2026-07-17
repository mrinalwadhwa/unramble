import Foundation

/// Checks and requests system permissions required by the app.
///
/// Microphone permission is needed for audio capture.
/// Accessibility permission is needed for global hotkeys, reading text fields,
/// and injecting text into applications.
public protocol PermissionProviding: Sendable {

    /// Current state of microphone permission.
    func checkMicrophone() -> PermissionState

    /// Request microphone permission from the user. Returns the resulting state.
    func requestMicrophone() async -> PermissionState

    /// Current state of accessibility permission (AXIsProcessTrusted).
    func checkAccessibility() -> PermissionState

    /// Open System Settings to the Accessibility pane so the user can grant permission.
    func openAccessibilitySettings()
}
