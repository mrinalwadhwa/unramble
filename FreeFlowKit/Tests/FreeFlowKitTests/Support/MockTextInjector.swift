import Foundation

@testable import FreeFlowKit

/// A mock text injector that records injection calls for testing.
///
/// Used in tests to exercise the full pipeline without requiring
/// accessibility permissions or a real target app.
public final class MockTextInjector: TextInjecting, @unchecked Sendable {

    private let lock = NSLock()
    private var _injections: [(text: String, context: AppContext)] = []

    /// If set, `inject(text:into:)` throws this error instead of recording
    /// the injection. Use to simulate injection failures in tests.
    public var stubbedError: (any Error)?

    public init() {}

    /// All injections that have been performed, in order.
    public var injections: [(text: String, context: AppContext)] {
        lock.withLock { _injections }
    }

    /// The most recent injected text, or nil if no injections have occurred.
    public var lastInjectedText: String? {
        lock.withLock { _injections.last?.text }
    }

    /// The number of injections performed.
    public var injectionCount: Int {
        lock.withLock { _injections.count }
    }

    public func inject(text: String, into context: AppContext) async throws {
        if let error = stubbedError {
            throw error
        }
        lock.withLock {
            _injections.append((text: text, context: context))
        }
    }

    /// Remove all recorded injections.
    public func reset() {
        lock.withLock { _injections.removeAll() }
    }
}
