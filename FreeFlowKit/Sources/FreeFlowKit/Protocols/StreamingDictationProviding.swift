import Foundation

/// Stream audio for real-time transcription and receive polished text.
///
/// Unlike `BatchDictationProviding`, which sends a complete WAV file after
/// recording ends, a streaming provider accepts audio chunks during
/// recording. The server transcribes audio in real time so the result
/// is available almost immediately after the last chunk is sent.
///
/// Lifecycle:
///   1. `startStreaming(sessionID:context:language:micProximity:)` opens a
///      connection owned by a fresh dictation session ID.
///   2. `sendAudio(_:sessionID:)` sends each PCM chunk for that session.
///   3. `finishStreaming(sessionID:)` closes the session and returns one
///      complete result for injection.
///   4. `cancelStreaming(sessionID:)` aborts a known session, while
///      `cancelActiveStreaming()` aborts whichever session is currently active.
///
/// Implementations must be safe to call from any isolation context.
/// A single streaming session is active at a time; calling
/// `startStreaming` while a session is open is a programming error.
public protocol StreamingDictationProviding: Sendable {

    /// Pipeline watchdog for `finishStreaming(sessionID:)`, in seconds.
    ///
    /// The provider should include enough time for its own semantic timeout
    /// and teardown. When this deadline expires, the pipeline closes the
    /// provider, joins finalization, and recovers from the complete WAV.
    var finishStreamingWatchdog: TimeInterval { get }

    /// Stable upper bound for `finishStreamingWatchdog`, in seconds.
    ///
    /// The outer pipeline snapshots this value before provider-owned audio
    /// forwarding has necessarily drained. Providers whose finish watchdog
    /// grows with submitted audio must override this property with a bound that
    /// covers the largest supported session and does not change during it.
    var maximumFinishStreamingWatchdog: TimeInterval { get }

    /// Open a streaming transcription session.
    ///
    /// - Parameters:
    ///   - context: Application context at the time of dictation.
    ///   - language: Optional ISO-639-1 language hint (e.g. "en").
    ///   - micProximity: Whether the mic is near-field (headset) or
    ///     far-field (built-in laptop mic). The server uses this to
    ///     configure noise reduction on the transcription backend.
    /// - Throws: If the connection cannot be established.
    func startStreaming(
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity: MicProximity
    ) async throws

    /// Send a chunk of raw PCM audio to the server.
    ///
    /// Audio must be 16-bit signed little-endian PCM at 16 kHz, mono.
    /// Each provider converts that source format to any backend-specific
    /// representation. Chunks can be any size; smaller chunks reduce latency.
    ///
    /// - Parameter pcmData: Raw PCM bytes (no WAV header).
    /// - Throws: If the session is not open or the send fails.
    func sendAudio(_ pcmData: Data, sessionID: DictationSessionID) async throws

    /// Signal the end of audio and receive the complete transcript.
    ///
    /// Block until the provider finishes transcription and cleanup, then return
    /// the polished text ready for one atomic injection.
    ///
    /// - Returns: The cleaned-up transcript, or an empty string if
    ///   no speech was detected.
    /// - Throws: On network errors or if the session is not open.
    func finishStreaming(sessionID: DictationSessionID) async throws -> String

    /// Abort the current streaming session without waiting for results.
    ///
    /// Safe to call if no session is open (no-op in that case).
    func cancelActiveStreaming() async

    /// Abort the identified session without affecting a newer active session.
    /// Stale IDs are rejected as no-ops.
    func cancelStreaming(sessionID: DictationSessionID) async
}

/// Reprocess an exact retained local capture through the same bounded unit
/// policy used during live dictation.
///
/// Recovery owns a fresh provider session identified by `sessionID`. The
/// implementation must consume every PCM byte once, in order, and return one
/// complete result. Cancellation is performed through the
/// session-scoped `cancelStreaming` requirement inherited from
/// `StreamingDictationProviding`.
public protocol LocalAudioReplayProviding: StreamingDictationProviding {

    func replayCapturedAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity: MicProximity,
        silenceThreshold: Float
    ) async throws -> String
}

/// Shared defaults for provider policy.
extension StreamingDictationProviding {

    public var finishStreamingWatchdog: TimeInterval { 30 }
    public var maximumFinishStreamingWatchdog: TimeInterval {
        finishStreamingWatchdog
    }
}
