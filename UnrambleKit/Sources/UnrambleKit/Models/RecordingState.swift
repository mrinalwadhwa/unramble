import Foundation

/// Tracks the recording lifecycle from idle through injection.
public enum RecordingState: Sendable, Equatable {
    case idle
    case recording
    case processing
    case injecting
    case injectionFailed
    case sessionExpired
    case dictationFailed
}

/// Classifies a recoverable dictation failure for the HUD.
public enum RecordingFailure: Sendable, Equatable {
    /// OpenAI rejected the request because the API key reached its rate limit.
    case rateLimited
}

/// A coordinator state observation tagged with the session responsible for it.
/// For `.idle`, `sessionID` is the session that just ended; the initial idle
/// observation has no session.
public struct RecordingStateUpdate: Sendable, Equatable {
    public let state: RecordingState
    public let sessionID: DictationSessionID?
    public let failure: RecordingFailure?

    public init(
        state: RecordingState,
        sessionID: DictationSessionID?,
        failure: RecordingFailure? = nil
    ) {
        self.state = state
        self.sessionID = sessionID
        self.failure = state == .dictationFailed ? failure : nil
    }
}
