import AppKit
import UnrambleKit

/// Check and request microphone and accessibility permissions on launch.
///
/// `PermissionController` runs permission checks when the app starts and
/// guides the user through granting access. Microphone permission triggers
/// the system prompt if not determined. Accessibility permission shows an
/// alert directing the user to System Settings.
@MainActor
final class PermissionController {

    private let permissionProvider: PermissionProviding
    private var permissionCheckTask: Task<Void, Never>?
    private var permissionCheckGeneration: UInt64 = 0
    private var pollingTask: Task<Void, Never>?

    /// Called when both permissions are granted and the app can proceed.
    var onPermissionsGranted: (() -> Void)?

    init(permissionProvider: PermissionProviding) {
        self.permissionProvider = permissionProvider
    }

    // MARK: - Permission checks

    /// Run permission checks and request access as needed.
    ///
    /// Call this from `applicationDidFinishLaunching`. If both permissions
    /// are already granted, `onPermissionsGranted` fires immediately.
    /// Otherwise the controller requests microphone access and shows
    /// guidance for accessibility.
    func checkPermissions() {
        permissionCheckGeneration &+= 1
        let generation = permissionCheckGeneration
        permissionCheckTask?.cancel()
        permissionCheckTask = Task { [weak self] in
            guard let self else { return }
            let micState = await ensureMicrophonePermission()
            guard !Task.isCancelled,
                generation == permissionCheckGeneration
            else { return }
            let axState = permissionProvider.checkAccessibility()

            if micState == .granted && axState == .granted {
                permissionCheckTask = nil
                onPermissionsGranted?()
                return
            }

            if micState == .denied {
                showMicrophoneDeniedAlert()
            }

            if axState != .granted {
                showAccessibilityAlert()
                startAccessibilityPolling()
            }
            if generation == permissionCheckGeneration {
                permissionCheckTask = nil
            }
        }
    }

    /// Stop any ongoing polling and clean up.
    func stop() {
        permissionCheckGeneration &+= 1
        permissionCheckTask?.cancel()
        permissionCheckTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Microphone

    /// Check microphone permission and request it if not determined.
    private func ensureMicrophonePermission() async -> PermissionState {
        let current = permissionProvider.checkMicrophone()
        switch current {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return await permissionProvider.requestMicrophone()
        }
    }

    /// Show an alert when microphone permission has been denied.
    private func showMicrophoneDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = """
            Unramble needs microphone access to capture speech for transcription. \
            Open System Settings > Privacy & Security > Microphone and enable \
            access for Unramble.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Accessibility

    /// Show an alert guiding the user to grant accessibility permission.
    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = """
            Unramble needs accessibility access to detect the global hotkey \
            and inject transcribed text into applications. Open System \
            Settings > Privacy & Security > Accessibility and enable \
            access for Unramble.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            permissionProvider.openAccessibilitySettings()
        }
    }

    /// Poll for accessibility permission every 2 seconds until granted.
    ///
    /// Once granted, fires `onPermissionsGranted` if microphone is also
    /// granted, then stops polling.
    private func startAccessibilityPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }

                guard let self else { break }
                let axState = self.permissionProvider.checkAccessibility()
                if axState == .granted {
                    let micState = self.permissionProvider.checkMicrophone()
                    if micState == .granted {
                        self.onPermissionsGranted?()
                    }
                    break
                }
            }
        }
    }

    deinit {
        permissionCheckTask?.cancel()
        pollingTask?.cancel()
    }
}
