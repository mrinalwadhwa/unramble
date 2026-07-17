import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

#if canImport(Cocoa)
    import Cocoa
#endif

/// Check and request microphone and accessibility permissions.
///
/// Microphone permission uses `AVCaptureDevice` authorization.
/// Accessibility permission uses `AXIsProcessTrusted` and can open
/// System Settings to the Privacy pane when the user needs to grant access.
public final class MicrophonePermissionProvider: PermissionProviding, @unchecked Sendable {

    public init() {}

    // MARK: - Microphone

    public func checkMicrophone() -> PermissionState {
        #if canImport(AVFoundation)
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .granted
            case .denied, .restricted:
                return .denied
            case .notDetermined:
                return .notDetermined
            @unknown default:
                return .notDetermined
            }
        #else
            return .denied
        #endif
    }

    public func requestMicrophone() async -> PermissionState {
        #if canImport(AVFoundation)
            let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            switch currentStatus {
            case .authorized:
                return .granted
            case .denied, .restricted:
                return .denied
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                return granted ? .granted : .denied
            @unknown default:
                return .notDetermined
            }
        #else
            return .denied
        #endif
    }

    // MARK: - Accessibility

    public func checkAccessibility() -> PermissionState {
        #if canImport(ApplicationServices)
            let trusted = AXIsProcessTrusted()
            return trusted ? .granted : .denied
        #else
            return .denied
        #endif
    }

    public func openAccessibilitySettings() {
        #if canImport(Cocoa)
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            if let url {
                NSWorkspace.shared.open(url)
            }
        #endif
    }
}
