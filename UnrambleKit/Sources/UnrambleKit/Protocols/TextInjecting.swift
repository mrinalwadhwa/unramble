import Foundation

/// Injects text into the active application at the current cursor position.
///
/// Different apps require different injection strategies (accessibility API,
/// pasteboard + Cmd+V, keystroke simulation). Implementations select the
/// appropriate strategy based on the app context.
public protocol TextInjecting: Sendable {

    /// Insert text into the application described by the given context.
    ///
    /// The implementation chooses an injection strategy based on the app's
    /// bundle ID and the type of focused element. If the preferred strategy
    /// fails, implementations should fall back to alternatives before throwing.
    ///
    /// - Parameters:
    ///   - text: The text to inject.
    ///   - context: The application context at the time of injection.
    /// - Throws: If all injection strategies fail for the target application.
    func inject(text: String, into context: AppContext) async throws
}
