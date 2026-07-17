import Foundation

/// Strategy for injecting text into the active application.
///
/// Different apps respond to different injection methods. The strategy
/// is selected per-app based on bundle ID, with a sensible default.
public enum InjectionStrategy: Sendable, Equatable, Hashable {
    /// Set the value directly via the Accessibility API (AXUIElement setValue).
    /// Most reliable for native macOS text fields.
    case accessibility

    /// Copy text to the pasteboard and simulate Cmd+V.
    /// Works broadly across apps including terminals and web views.
    /// The previous clipboard content is saved and restored.
    case pasteboard

    /// Simulate individual keystrokes via CGEvent.
    /// Slowest option, but works for apps that ignore both accessibility
    /// and paste events.
    case keystroke
}
