import Foundation

/// Transcribe audio locally using an on-device speech-to-text model.
///
/// Implementations wrap a specific ML runtime (ONNX Runtime, Core ML,
/// etc.) and expose a simple batch transcription interface. The engine
/// must be loaded before use; callers check `isReady` or call `load()`
/// to ensure the model is in memory.
public protocol LocalSTTEngine: Sendable {

    /// Display name for diagnostics (e.g. "Nemotron Speech 0.6B").
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

/// One stateful, incremental local speech-recognition session.
///
/// A session has one owner. Calls must be serialized in recording order.
public protocol LocalRecognitionSession: AnyObject {

    /// Accept normalized 16 kHz mono samples in recording order.
    func feed(_ samples: [Float]) throws

    /// Return the transcript produced by complete chunks so far.
    func transcript() -> String

    /// Flush buffered samples and return the complete transcript.
    func finish() throws -> String
}

/// A local recognizer that creates independent incremental sessions.
public protocol LocalStreamingRecognizer: Sendable {

    var name: String { get }
    var isReady: Bool { get }

    func load() async throws
    func makeRecognitionSession() throws -> any LocalRecognitionSession
}
