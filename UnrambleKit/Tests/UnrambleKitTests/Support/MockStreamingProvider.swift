import Foundation

@testable import UnrambleKit

/// A mock streaming dictation provider that records calls for testing.
///
/// Mirror the pattern of `MockDictationProvider`: configurable stubbed
/// results, error stubbing, argument recording, and call counting.
/// Used in tests to exercise the streaming pipeline path without
/// making real WebSocket connections.
public final class MockStreamingProvider: LocalAudioReplayProviding, @unchecked Sendable
{

    private let lock = NSLock()

    private var _startCallCount: Int = 0
    private var _sendCallCount: Int = 0
    private var _finishCallCount: Int = 0
    private var _cancelCallCount: Int = 0
    private var _cancelAttemptCount: Int = 0
    private var _replayCallCount: Int = 0
    private var _receivedContexts: [AppContext] = []
    private var _receivedLanguages: [String?] = []
    private var _receivedAudioChunks: [Data] = []
    private var _replayedAudio: [Data] = []
    private var _replaySessionIDs: [DictationSessionID] = []
    private var _replaySilenceThresholds: [Float] = []
    private var _activeSessionID: DictationSessionID?

    /// The text returned by `finishStreaming()`.
    public var stubbedText: String

    /// An optional error to throw from `startStreaming()`.
    /// When non-nil, `startStreaming()` throws this error.
    public var stubbedStartError: (any Error)?

    /// Optional test hook invoked after a streaming start is recorded.
    public var startStreamingHook: (@Sendable () async throws -> Void)?

    /// An optional error to throw from `sendAudio()`.
    /// When non-nil, `sendAudio()` throws this error.
    public var stubbedSendError: (any Error)?

    /// Optional test hook invoked for each recorded audio chunk.
    public var sendAudioHook: (@Sendable (Data) async throws -> Void)?

    /// Optional test hook invoked after a captured-audio replay is recorded.
    public var replayCapturedAudioHook: (@Sendable () async throws -> Void)?

    /// An optional error to throw from `replayCapturedAudio()`.
    public var stubbedReplayError: (any Error)?

    /// Optional test hook invoked when the streaming session is cancelled.
    public var cancelStreamingHook: (@Sendable () async -> Void)?

    /// An optional error to throw from `finishStreaming()`.
    /// When non-nil, `finishStreaming()` throws this error instead of
    /// returning `stubbedText`.
    public var stubbedFinishError: (any Error)?

    /// Pipeline watchdog for `finishStreaming()`.
    public var finishStreamingWatchdog: TimeInterval = 30

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

    /// Number of cancellation requests, including stale session IDs that were
    /// correctly rejected before mutating the active mock session.
    public var cancelAttemptCount: Int {
        lock.withLock { _cancelAttemptCount }
    }

    /// Number of retained local captures replayed through the recovery API.
    public var replayCallCount: Int {
        lock.withLock { _replayCallCount }
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

    /// Exact PCM payloads received through captured-audio recovery.
    public var replayedAudio: [Data] {
        lock.withLock { _replayedAudio }
    }

    public var replaySessionIDs: [DictationSessionID] {
        lock.withLock { _replaySessionIDs }
    }

    public var replaySilenceThresholds: [Float] {
        lock.withLock { _replaySilenceThresholds }
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

    public func startStreaming(
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity: MicProximity
    ) async throws {
        let (claimed, error, hook): (
            Bool, (any Error)?, (@Sendable () async throws -> Void)?
        ) = lock.withLock {
            guard _activeSessionID == nil else {
                return (false, nil, nil)
            }
            _startCallCount += 1
            _receivedContexts.append(context)
            _receivedLanguages.append(language)
            _activeSessionID = sessionID
            return (true, stubbedStartError, startStreamingHook)
        }
        guard claimed else { throw CancellationError() }
        do {
            if let error { throw error }
            try await hook?()
            let stillOwned = lock.withLock { _activeSessionID == sessionID }
            guard stillOwned else { throw CancellationError() }
        } catch {
            lock.withLock {
                if _activeSessionID == sessionID { _activeSessionID = nil }
            }
            throw error
        }
    }

    public func sendAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID
    ) async throws {
        let (accepted, error, hook): (
            Bool, (any Error)?, (@Sendable (Data) async throws -> Void)?
        ) = lock.withLock {
            guard _activeSessionID == sessionID else {
                return (false, nil, nil)
            }
            _sendCallCount += 1
            _receivedAudioChunks.append(pcmData)
            return (true, stubbedSendError, sendAudioHook)
        }
        guard accepted else { throw CancellationError() }
        if let error { throw error }
        try await hook?(pcmData)
    }

    public func finishStreaming(
        sessionID: DictationSessionID
    ) async throws -> String {
        let (accepted, error, text): (Bool, (any Error)?, String) = lock.withLock {
            guard _activeSessionID == sessionID else {
                return (false, nil, "")
            }
            _finishCallCount += 1
            _activeSessionID = nil
            return (true, stubbedFinishError, stubbedText)
        }
        guard accepted else { throw CancellationError() }
        if let error { throw error }
        return text
    }

    public func cancelActiveStreaming() async {
        guard let sessionID = lock.withLock({ _activeSessionID }) else { return }
        await cancelStreaming(sessionID: sessionID)
    }

    public func cancelStreaming(sessionID: DictationSessionID) async {
        let hook: (@Sendable () async -> Void)? = lock.withLock {
            _cancelAttemptCount += 1
            guard _activeSessionID == sessionID else { return nil }
            _activeSessionID = nil
            _cancelCallCount += 1
            return cancelStreamingHook
        }
        await hook?()
    }

    public func replayCapturedAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity: MicProximity,
        silenceThreshold: Float
    ) async throws -> String {
        let (claimed, error, hook, text): (
            Bool, (any Error)?, (@Sendable () async throws -> Void)?, String
        ) = lock.withLock {
            guard _activeSessionID == nil else {
                return (false, nil, nil, "")
            }
            _replayCallCount += 1
            _replayedAudio.append(pcmData)
            _replaySessionIDs.append(sessionID)
            _replaySilenceThresholds.append(silenceThreshold)
            _activeSessionID = sessionID
            return (
                true, stubbedReplayError, replayCapturedAudioHook, stubbedText)
        }
        guard claimed else { throw CancellationError() }
        do {
            if let error { throw error }
            try await hook?()
            try Task.checkCancellation()
            let stillOwned = lock.withLock { () -> Bool in
                guard _activeSessionID == sessionID else { return false }
                _activeSessionID = nil
                return true
            }
            guard stillOwned else { throw CancellationError() }
            return text
        } catch {
            lock.withLock {
                if _activeSessionID == sessionID { _activeSessionID = nil }
            }
            throw error
        }
    }

    /// Remove all recorded calls and reset counters.
    public func reset() {
        lock.withLock {
            _startCallCount = 0
            _sendCallCount = 0
            _finishCallCount = 0
            _cancelCallCount = 0
            _cancelAttemptCount = 0
            _replayCallCount = 0
            _receivedContexts.removeAll()
            _receivedLanguages.removeAll()
            _receivedAudioChunks.removeAll()
            _replayedAudio.removeAll()
            _replaySessionIDs.removeAll()
            _replaySilenceThresholds.removeAll()
            _activeSessionID = nil
            startStreamingHook = nil
            sendAudioHook = nil
            replayCapturedAudioHook = nil
            cancelStreamingHook = nil
        }
    }
}
