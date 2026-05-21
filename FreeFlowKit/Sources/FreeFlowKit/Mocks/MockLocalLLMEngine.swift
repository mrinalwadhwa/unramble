import Foundation

/// A mock LLM engine that returns configurable results for testing.
///
/// Track call counts and recorded prompts to verify polish client
/// behavior without loading a real language model.
public final class MockLocalLLMEngine: LocalLLMEngine, @unchecked Sendable {

    private let lock = NSLock()
    private var _completeCallCount: Int = 0
    private var _receivedPrompts: [(system: String, user: String)] = []
    private var _loadCallCount: Int = 0

    public let name = "MockLLM"

    /// Whether the engine reports itself as ready.
    public var stubbedIsReady: Bool = true

    /// The text returned by `complete(systemPrompt:userPrompt:maxTokens:)`.
    public var stubbedCompletion = ""

    /// An optional error to throw from `complete(...)`.
    public var stubbedError: (any Error)?

    /// An optional error to throw from `load()`.
    public var stubbedLoadError: (any Error)?

    public var isReady: Bool {
        lock.withLock { stubbedIsReady }
    }

    /// Number of times `complete(...)` has been called.
    public var completeCallCount: Int {
        lock.withLock { _completeCallCount }
    }

    /// Prompts received in each `complete` call, in order.
    public var receivedPrompts: [(system: String, user: String)] {
        lock.withLock { _receivedPrompts }
    }

    /// Number of times `load()` has been called.
    public var loadCallCount: Int {
        lock.withLock { _loadCallCount }
    }

    public init() {}

    public func load() async throws {
        let error: (any Error)? = lock.withLock {
            _loadCallCount += 1
            return stubbedLoadError
        }
        if let error { throw error }
        lock.withLock { stubbedIsReady = true }
    }

    public func unload() async {
        lock.withLock { stubbedIsReady = false }
    }

    public func complete(
        systemPrompt: String, userPrompt: String, maxTokens: Int
    ) async throws -> String {
        let error: (any Error)? = lock.withLock {
            _completeCallCount += 1
            _receivedPrompts.append((systemPrompt, userPrompt))
            return stubbedError
        }
        if let error { throw error }
        return lock.withLock { stubbedCompletion }
    }

    /// Remove all recorded calls and reset state.
    public func reset() {
        lock.withLock {
            _completeCallCount = 0
            _receivedPrompts.removeAll()
            _loadCallCount = 0
            stubbedError = nil
            stubbedLoadError = nil
            stubbedIsReady = true
        }
    }
}
