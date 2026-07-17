import Foundation

/// Reads the state of the active application, focused window, and focused text field.
///
/// Real implementations use AXUIElement and NSWorkspace to read app state.
/// A mock implementation returns stub AppContext values for testing.
public protocol AppContextProviding: Sendable {

    /// Read the current app context within a latency budget.
    ///
    /// Implementations should complete within 200ms. If any individual field
    /// read times out, skip it and return partial context rather than failing.
    func readContext() async -> AppContext
}
