import Foundation

/// A mock streaming dictation provider that records calls for testing.
///
/// Mirror the pattern of `MockDictationProvider`: configurable stubbed
/// results, error stubbing, argument recording, and call counting.
/// Used in tests to exercise the streaming pipeline path without
/// making real WebSocket connections.
public final class MockStreamingProvider: StreamingDictationProviding, @unchecked Sendable
{

    private let lock = NSLock()

    private var _startCallCount: Int = 0
    private var _sendCallCount: Int = 0
    private var _finishCallCount: Int = 0
    private var _cancelCallCount: Int = 0
    private var _receivedContexts: [AppContext] = []
    private var _receivedLanguages: [String?] = []
    private var _receivedAudioChunks: [Data] = []

    /// The text returned by `finishStreaming()`.
    public var stubbedText: String

    /// An optional error to throw from `startStreaming()`.
    /// When non-nil, `startStreaming()` throws this error.
    public var stubbedStartError: (any Error)?

    /// An optional error to throw from `sendAudio()`.
    /// When non-nil, `sendAudio()` throws this error.
    public var stubbedSendError: (any Error)?

    /// An optional error to throw from `finishStreaming()`.
    /// When non-nil, `finishStreaming()` throws this error instead of
    /// returning `stubbedText`.
    public var stubbedFinishError: (any Error)?

    /// The value returned by `uncommittedAudioDuration`. Defaults to 0.
    public var stubbedUncommittedAudioDuration: TimeInterval = 0

    /// Number of times `startStreaming()` has been called.
    public var startCallCount: Int {
        lock.withLock { _startCallCount }
    }

    /// Number of times `sendAudio()` has been called.
    public var sendCallCount: Int {
        lock.withLock { _sendCallCount }
    }

    /// Number of times `finishStreaming()` has been called.
    public var finishCallCount: Int {
        lock.withLock { _finishCallCount }
    }

    /// Number of times `cancelStreaming()` has been called.
    public var cancelCallCount: Int {
        lock.withLock { _cancelCallCount }
    }

    /// Contexts received in each `startStreaming()` call, in order.
    public var receivedContexts: [AppContext] {
        lock.withLock { _receivedContexts }
    }

    /// Languages received in each `startStreaming()` call, in order.
    public var receivedLanguages: [String?] {
        lock.withLock { _receivedLanguages }
    }

    /// All audio chunks received via `sendAudio()`, in order.
    public var receivedAudioChunks: [Data] {
        lock.withLock { _receivedAudioChunks }
    }

    /// The most recent context received, or nil if never called.
    public var lastReceivedContext: AppContext? {
        lock.withLock { _receivedContexts.last }
    }

    /// Total bytes of audio received across all `sendAudio()` calls.
    public var totalAudioBytesReceived: Int {
        lock.withLock { _receivedAudioChunks.reduce(0) { $0 + $1.count } }
    }

    public init(stubbedText: String = "Mock streaming dictation") {
        self.stubbedText = stubbedText
    }

    // MARK: - StreamingDictationProviding

    public var uncommittedAudioDuration: TimeInterval {
        lock.withLock { stubbedUncommittedAudioDuration }
    }

    public func startStreaming(context: AppContext, language: String?, micProximity: MicProximity)
        async throws
    {
        let error: (any Error)? = lock.withLock {
            _startCallCount += 1
            _receivedContexts.append(context)
            _receivedLanguages.append(language)
            return stubbedStartError
        }

        if let error { throw error }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        let error: (any Error)? = lock.withLock {
            _sendCallCount += 1
            _receivedAudioChunks.append(pcmData)
            return stubbedSendError
        }

        if let error { throw error }
    }

    public func finishStreaming() async throws -> String {
        let (error, text): ((any Error)?, String) = lock.withLock {
            _finishCallCount += 1
            return (stubbedFinishError, stubbedText)
        }

        if let error { throw error }
        return text
    }

    public func cancelStreaming() async {
        lock.withLock {
            _cancelCallCount += 1
        }
    }

    // MARK: - Chunk handler recording

    private var _chunkHandler: (@Sendable (String) async -> Void)?

    /// The chunk handler set by the pipeline. The mock records it but
    /// does not invoke it automatically — call `emitChunk(_:)` from
    /// the test to simulate a committed chunk.
    public var hasChunkHandler: Bool {
        lock.withLock { _chunkHandler != nil }
    }

    public func setChunkHandler(_ handler: (@Sendable (String) async -> Void)?) {
        lock.withLock { _chunkHandler = handler }
    }

    /// Simulate the provider delivering an intermediate chunk.
    public func emitChunk(_ text: String) async {
        let handler = lock.withLock { _chunkHandler }
        await handler?(text)
    }

    /// Remove all recorded calls and reset counters.
    public func reset() {
        lock.withLock {
            _startCallCount = 0
            _sendCallCount = 0
            _finishCallCount = 0
            _cancelCallCount = 0
            _receivedContexts.removeAll()
            _receivedLanguages.removeAll()
            _receivedAudioChunks.removeAll()
            _chunkHandler = nil
        }
    }
}
