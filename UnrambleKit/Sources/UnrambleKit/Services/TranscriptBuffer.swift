import Foundation

/// Hold the most recent transcript for no-target recovery and re-paste.
///
/// The pipeline writes to the buffer after dictation completes. Consumers:
/// - No-target recovery: inject the buffered transcript via a special shortcut.
/// - Menu bar "Paste last transcript" item.
///
/// Does not touch the system clipboard. Text injection uses the same
/// `TextInjecting` pathway as normal injection.
public actor TranscriptBuffer {

    public struct InjectionConsumption: Sendable {
        public let transcript: String
        public let sessionID: DictationSessionID?
        fileprivate let revision: UInt64
    }

    private var _lastTranscript: String?
    private var _sessionID: DictationSessionID?
    private var _timestamp: Date?
    private var revision: UInt64 = 0

    public init() {}

    /// The most recent transcript, or nil if none has been stored.
    public var lastTranscript: String? {
        _lastTranscript
    }

    /// Return the transcript only when it belongs to the exact dictation.
    public func transcript(for sessionID: DictationSessionID) -> String? {
        guard _sessionID == sessionID else { return nil }
        return _lastTranscript
    }

    /// When the most recent transcript was stored, or nil if empty.
    public var timestamp: Date? {
        _timestamp
    }

    /// Whether a transcript is available to paste.
    public var hasTranscript: Bool {
        _lastTranscript != nil
    }

    /// Store a new transcript, replacing any previous value. Pipeline stores
    /// carry their dictation identity; manual callers may leave it unscoped.
    public func store(
        _ transcript: String,
        sessionID: DictationSessionID? = nil
    ) {
        revision &+= 1
        _lastTranscript = transcript
        _sessionID = sessionID
        _timestamp = Date()
    }

    /// Retrieve and clear the stored transcript.
    ///
    /// Returns the transcript if one was stored, or nil if the buffer is empty.
    /// The buffer is cleared after retrieval so the same transcript is not
    /// injected twice by accident.
    public func consume() -> String? {
        let transcript = _lastTranscript
        revision &+= 1
        _lastTranscript = nil
        _sessionID = nil
        _timestamp = nil
        return transcript
    }

    /// Lease the current transcript to an injection attempt. Supplying a
    /// session ID refuses an entry owned by another dictation. A failed attempt
    /// may restore it only while no newer buffer mutation has occurred.
    public func consumeForInjection(
        sessionID: DictationSessionID? = nil
    ) -> InjectionConsumption? {
        guard let transcript = _lastTranscript,
            sessionID == nil || _sessionID == sessionID
        else { return nil }
        let consumption = InjectionConsumption(
            transcript: transcript,
            sessionID: _sessionID,
            revision: revision)
        _lastTranscript = nil
        _sessionID = nil
        _timestamp = nil
        return consumption
    }

    /// Restore a failed injection without overwriting a newer transcript.
    @discardableResult
    public func restoreAfterFailedInjection(
        _ consumption: InjectionConsumption
    ) -> Bool {
        guard _lastTranscript == nil, revision == consumption.revision else {
            return false
        }
        revision &+= 1
        _lastTranscript = consumption.transcript
        _sessionID = consumption.sessionID
        _timestamp = Date()
        return true
    }

    /// Clear the buffer without retrieving the transcript.
    public func clear() {
        revision &+= 1
        _lastTranscript = nil
        _sessionID = nil
        _timestamp = nil
    }
}
