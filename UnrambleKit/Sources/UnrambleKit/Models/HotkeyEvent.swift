import Foundation

/// Events emitted by the global hotkey listener.
public enum HotkeyEvent: Sendable, Equatable {
    case pressed
    case released
}
