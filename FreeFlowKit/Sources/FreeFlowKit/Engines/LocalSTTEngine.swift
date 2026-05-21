import Foundation

/// Transcribe audio locally using an on-device speech-to-text model.
///
/// Implementations wrap a specific ML runtime (ONNX Runtime, Core ML,
/// etc.) and expose a simple batch transcription interface. The engine
/// must be loaded before use; callers check `isReady` or call `load()`
/// to ensure the model is in memory.
public protocol LocalSTTEngine: Sendable {

    /// Display name for diagnostics (e.g. "Parakeet TDT 0.6B").
    var name: String { get }

    /// Whether the engine is loaded and ready to transcribe.
    var isReady: Bool { get }

    /// Load the model into memory.
    ///
    /// No-op if already loaded. Throws on failure (missing files,
    /// unsupported hardware, etc.).
    func load() async throws

    /// Unload the model and release memory.
    func unload() async

    /// Transcribe complete WAV audio (16 kHz, 16-bit mono).
    ///
    /// - Parameter audio: A complete WAV file (RIFF header + PCM data).
    /// - Returns: The raw transcript text.
    func transcribe(audio: Data) async throws -> String
}
