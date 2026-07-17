import Foundation

/// The state of a system permission (microphone, accessibility, screen recording).
public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
}
