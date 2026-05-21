import Foundation

/// A mock STT engine that returns configurable results for testing.
///
/// Track call counts and recorded arguments to verify provider
/// behavior without loading a real speech-to-text model.
public final class MockLocalSTTEngine: LocalSTTEngine, @unchecked Sendable {

    private let lock = NSLock()
    private var _transcribeCallCount: Int = 0
    private var _receivedAudio: [Data] = []
    private var _loadCallCount: Int = 0

    public let name = "MockSTT"

    /// Whether the engine reports itself as ready.
    public var stubbedIsReady: Bool = true

    /// The text returned by `transcribe(audio:)`.
    public var stubbedTranscription = "hello world"

    /// An optional error to throw from `transcribe(audio:)`.
    public var stubbedError: (any Error)?

    /// An optional error to throw from `load()`.
    public var stubbedLoadError: (any Error)?

    public var isReady: Bool {
        lock.withLock { stubbedIsReady }
    }

    /// Number of times `transcribe(audio:)` has been called.
    public var transcribeCallCount: Int {
        lock.withLock { _transcribeCallCount }
    }

    /// Audio data received in each `transcribe` call, in order.
    public var receivedAudio: [Data] {
        lock.withLock { _receivedAudio }
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

    public func transcribe(audio: Data) async throws -> String {
        let error: (any Error)? = lock.withLock {
            _transcribeCallCount += 1
            _receivedAudio.append(audio)
            return stubbedError
        }
        if let error { throw error }
        return lock.withLock { stubbedTranscription }
    }

    /// Remove all recorded calls and reset state.
    public func reset() {
        lock.withLock {
            _transcribeCallCount = 0
            _receivedAudio.removeAll()
            _loadCallCount = 0
            stubbedError = nil
            stubbedLoadError = nil
            stubbedIsReady = true
        }
    }
}
