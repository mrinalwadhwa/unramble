import Foundation

/// Resolve a complete audio recording into final text.
///
/// Providers receive the full WAV after recording ends and return text ready
/// for injection. The production cloud implementation is an exact-recording
/// recovery path used when Realtime delivery fails.
public protocol BatchDictationProviding: Sendable {

    /// Resolve a complete audio recording.
    ///
    /// - Parameters:
    ///   - audio: A complete WAV file (RIFF header + PCM data).
    ///   - context: Application context at the time of dictation.
    /// - Returns: The final text ready for injection.
    func dictate(audio: Data, context: AppContext) async throws -> String
}
