import Foundation

@testable import FreeFlowKit

/// A mock implementation of `AppContextProviding` that returns a configurable stub context.
///
/// Used in tests to exercise the pipeline without real accessibility API calls
/// and to verify context-dependent behavior.
public final class MockAppContextProvider: AppContextProviding, @unchecked Sendable {

    private let lock = NSLock()

    /// The context that will be returned by `readContext()`.
    /// Change this between calls to simulate different app states.
    public var stubbedContext: AppContext {
        get { lock.withLock { _stubbedContext } }
        set { lock.withLock { _stubbedContext = newValue } }
    }
    private var _stubbedContext: AppContext

    /// Number of times `readContext()` has been called.
    public var readContextCallCount: Int {
        lock.withLock { _readContextCallCount }
    }
    private var _readContextCallCount: Int = 0

    public init(context: AppContext = .stub) {
        self._stubbedContext = context
    }

    public func readContext() async -> AppContext {
        lock.withLock {
            _readContextCallCount += 1
            return _stubbedContext
        }
    }
}

extension AppContext {

    /// A stub context representing a generic text editor for use in tests and mocks.
    public static let stub = AppContext(
        bundleID: "com.apple.TextEdit",
        appName: "TextEdit",
        windowTitle: "Untitled",
        browserURL: nil,
        focusedFieldContent: "Some existing text in the field.",
        selectedText: nil,
        cursorPosition: 31
    )
}
