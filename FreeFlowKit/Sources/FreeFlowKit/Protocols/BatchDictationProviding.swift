import Foundation

/// Transcribe a complete audio recording into polished text.
///
/// Batch providers receive the full WAV after recording ends, send
/// it to a transcription service, polish the result, and return
/// final text. Used as a fallback when streaming fails, or as the
/// primary path when no streaming provider is available.
public protocol BatchDictationProviding: Sendable {

    /// Transcribe and polish a complete audio recording.
    ///
    /// - Parameters:
    ///   - audio: A complete WAV file (RIFF header + PCM data).
    ///   - context: Application context at the time of dictation.
    /// - Returns: The final text ready for injection.
    func dictate(audio: Data, context: AppContext) async throws -> String
}
