import Foundation

/// A mock dictation provider that returns configurable results for testing.
///
/// Track call counts and recorded arguments to verify pipeline behavior
/// without making real network calls to the dictation service.
public final class MockBatchProvider: BatchDictationProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var _dictateCallCount: Int = 0
    private var _receivedAudioData: [Data] = []
    private var _receivedContexts: [AppContext] = []

    /// The text returned by `dictate(audio:context:)`.
    public var stubbedText: String

    /// An optional error to throw instead of returning text.
    /// When non-nil, `dictate(audio:context:)` throws this error.
    public var stubbedError: (any Error)?

    /// Optional delay (in seconds) before returning from `dictate()`.
    /// Simulates slow network or a hanging batch request. Respects
    /// task cancellation during the sleep.
    public var stubbedDelay: TimeInterval = 0

    /// Number of times `dictate(audio:context:)` has been called.
    public var dictateCallCount: Int {
        lock.withLock { _dictateCallCount }
    }

    /// Audio data received in each call, in order.
    public var receivedAudioData: [Data] {
        lock.withLock { _receivedAudioData }
    }

    /// Contexts received in each call, in order.
    public var receivedContexts: [AppContext] {
        lock.withLock { _receivedContexts }
    }

    /// The most recent audio data received, or nil if never called.
    public var lastReceivedAudio: Data? {
        lock.withLock { _receivedAudioData.last }
    }

    /// The most recent context received, or nil if never called.
    public var lastReceivedContext: AppContext? {
        lock.withLock { _receivedContexts.last }
    }

    public init(stubbedText: String = "Mock dictation") {
        self.stubbedText = stubbedText
    }

    public func dictate(audio: Data, context: AppContext) async throws -> String {
        lock.withLock {
            _dictateCallCount += 1
            _receivedAudioData.append(audio)
            _receivedContexts.append(context)
        }

        if stubbedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(stubbedDelay * 1_000_000_000))
            try Task.checkCancellation()
        }

        if let error = stubbedError {
            throw error
        }

        return stubbedText
    }

    /// Remove all recorded calls.
    public func reset() {
        lock.withLock {
            _dictateCallCount = 0
            _receivedAudioData.removeAll()
            _receivedContexts.removeAll()
        }
    }
}
