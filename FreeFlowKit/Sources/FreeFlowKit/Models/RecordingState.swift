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

/// A coordinator state observation tagged with the session responsible for it.
/// For `.idle`, `sessionID` is the session that just ended; the initial idle
/// observation has no session.
public struct RecordingStateUpdate: Sendable, Equatable {
    public let state: RecordingState
    public let sessionID: DictationSessionID?

    public init(
        state: RecordingState,
        sessionID: DictationSessionID?
    ) {
        self.state = state
        self.sessionID = sessionID
    }
}
