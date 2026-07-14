import Foundation

/// Stream audio for real-time transcription and receive polished text.
///
/// Unlike `DictationProviding`, which sends a complete WAV file after
/// recording ends, a streaming provider accepts audio chunks during
/// recording. The server transcribes audio in real time so the result
/// is available almost immediately after the last chunk is sent.
///
/// Lifecycle:
///   1. Optionally `setChunkHandler(_:)` when the provider supports publishing
///      intermediate text.
///   2. `startStreaming(context:language:)` — open a connection.
///   3. `sendAudio(_:)` — call repeatedly with PCM chunks.
///   4. `finishStreaming()` — signal end of audio and receive the provider's
///      final unpublished text.
///   5. `cancelStreaming()` — abort without waiting for a result.
///
/// A provider may commit or transcribe backend audio incrementally without
/// publishing partial text. Providers that support rolling publication invoke
/// the optional chunk handler for text they will omit from the final result.
/// Providers without rolling publication ignore the handler and return one
/// complete result from `finishStreaming()`.
///
/// Implementations must be safe to call from any isolation context.
/// A single streaming session is active at a time; calling
/// `startStreaming` while a session is open is a programming error.
public protocol StreamingDictationProviding: Sendable {

    /// Duration (in seconds) of audio sent since the last successful backend
    /// commit. This does not prove that earlier committed audio reached final
    /// text delivery.
    var uncommittedAudioDuration: TimeInterval { get }

    /// Register a handler to receive intermediate published text for the next
    /// session. Call before `startStreaming`. Passing `nil` clears the handler.
    ///
    /// A provider that supports rolling publication invokes the handler from
    /// an unspecified executor with polished text that it will not return from
    /// `finishStreaming`. Other providers use the default no-op implementation.
    func setChunkHandler(_ handler: (@Sendable (String) async -> Void)?)

    /// Open a streaming transcription session.
    ///
    /// - Parameters:
    ///   - context: Application context at the time of dictation.
    ///   - language: Optional ISO-639-1 language hint (e.g. "en").
    ///   - micProximity: Whether the mic is near-field (headset) or
    ///     far-field (built-in laptop mic). The server uses this to
    ///     configure noise reduction on the transcription backend.
    /// - Throws: If the connection cannot be established.
    func startStreaming(context: AppContext, language: String?, micProximity: MicProximity)
        async throws

    /// Send a chunk of raw PCM audio to the server.
    ///
    /// Audio must be 16-bit signed little-endian PCM at 16 kHz, mono.
    /// Each provider converts that source format to any backend-specific
    /// representation. Chunks can be any size; smaller chunks reduce latency.
    ///
    /// - Parameter pcmData: Raw PCM bytes (no WAV header).
    /// - Throws: If the session is not open or the send fails.
    func sendAudio(_ pcmData: Data) async throws

    /// Signal the end of audio and receive the final unpublished transcript.
    ///
    /// Block until the provider finishes transcription and cleanup, then return
    /// the polished text ready for injection. This may be one unpublished tail
    /// after rolling publication or one complete atomic result.
    ///
    /// - Returns: The cleaned-up transcript, or an empty string if
    ///   no speech was detected.
    /// - Throws: On network errors or if the session is not open.
    func finishStreaming() async throws -> String

    /// Abort the current streaming session without waiting for results.
    ///
    /// Safe to call if no session is open (no-op in that case).
    func cancelStreaming() async
}

/// Default implementations so conforming types only need to implement
/// the methods they support. `setChunkHandler` is a no-op by default,
/// so providers that do not support rolling chunks are transparent to
/// callers that try to set a handler.
extension StreamingDictationProviding {

    public var uncommittedAudioDuration: TimeInterval { 0 }

    public func setChunkHandler(_ handler: (@Sendable (String) async -> Void)?) {}
}
