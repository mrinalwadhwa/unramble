import Foundation

/// Per-session timing and decision breakdown for a Realtime dictation. Every
/// timestamp is populated as the session progresses; `formatSessionSummary`
/// prints every field that was set. The struct is pure data and the formatting
/// and failure classification are pure functions, so a session summary
/// unit-tests without a live connection.
struct SessionTiming {
    var id: Int
    var startedAt: Date
    var setupKind: SetupKind = .pending
    var setupCompletedAt: Date?
    var audioBytesSent: Int = 0
    var audioChunksSent: Int = 0
    var commitSentAt: Date?
    var firstDeltaAt: Date?
    var transcriptCompletedAt: Date?
    var polishKind: PolishKind = .pending
    var endedAt: Date?
    var failure: FailureKind?

    enum SetupKind: String {
        case pending
        case freshConnection = "fresh"
        case adoptedBackup = "backup"
        case adoptedStaleBackup = "stale-backup"
    }

    enum PolishKind: String {
        case pending
        case skip = "skip"
        case realtimeOK = "realtime-ok"
    }

    enum FailureKind: String {
        case cancelled
        case emptyAudio = "empty-audio"
        case audioTooLarge = "audio-too-large"
        case authentication
        case rateLimited = "rate-limited"
        case request
        case invalidResponse = "invalid-response"
        case network
        case unknown
    }

    /// Format a session summary line. Pure function so the behavior is
    /// unit-testable without having to run a live session.
    static func formatSessionSummary(_ t: SessionTiming) -> String {
        func fmt(_ seconds: TimeInterval) -> String {
            String(format: "%.3f", seconds)
        }

        var parts: [String] = ["[RealtimeSession] id=\(t.id)"]
        parts.append("setup=\(t.setupKind.rawValue)")

        if let setupCompleted = t.setupCompletedAt {
            parts.append("setup_wait=\(fmt(setupCompleted.timeIntervalSince(t.startedAt)))")
        }
        if t.audioBytesSent > 0 {
            parts.append("bytes=\(t.audioBytesSent)")
            parts.append("chunks=\(t.audioChunksSent)")
        }
        if let commitSent = t.commitSentAt {
            if let firstDelta = t.firstDeltaAt {
                parts.append("first_delta=\(fmt(firstDelta.timeIntervalSince(commitSent)))")
            }
            if let completed = t.transcriptCompletedAt {
                parts.append("transcript=\(fmt(completed.timeIntervalSince(commitSent)))")
            }
        }
        if t.polishKind != .pending {
            parts.append("polish=\(t.polishKind.rawValue)")
        }
        if let end = t.endedAt {
            parts.append("total=\(fmt(end.timeIntervalSince(t.startedAt)))")
        }
        if let failure = t.failure {
            parts.append("failure=\(failure.rawValue)")
        }

        return parts.joined(separator: " ")
    }

    static func failureKind(for error: Error) -> FailureKind {
        if error is CancellationError {
            return .cancelled
        }
        guard let dictationError = error as? DictationError else {
            return error is URLError ? .network : .unknown
        }
        switch dictationError {
        case .emptyAudio:
            return .emptyAudio
        case .audioTooLarge:
            return .audioTooLarge
        case .authenticationFailed:
            return .authentication
        case .rateLimited:
            return .rateLimited
        case .requestFailed:
            return .request
        case .invalidResponse:
            return .invalidResponse
        case .networkError:
            return .network
        }
    }
}
