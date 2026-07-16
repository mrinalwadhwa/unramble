import Foundation

/// Lifecycle for an on-device speech-to-text model.
///
/// Implementations wrap a specific ML runtime (ONNX Runtime, Core ML,
/// The engine must be loaded before a streaming recognizer creates a session.
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

}

extension LocalSTTEngine {
    public func unload() async {}
}

/// One stateful, incremental local speech-recognition session.
///
/// A session has one owner. Calls must be serialized in recording order.
public protocol LocalRecognitionSession: AnyObject {

    /// Accept normalized 16 kHz mono samples in recording order.
    func feed(_ samples: [Float]) throws

    /// Return the transcript produced by complete chunks so far.
    ///
    /// Each non-empty result must preserve the previous result as an exact
    /// prefix. Nemotron satisfies this by appending decoded tokens. Supporting
    /// a recognizer that revises earlier tokens requires a revision-aware unit
    /// ledger in `LocalStreamingProvider` before it can conform here.
    func transcript() -> String

    /// Flush buffered samples and return the complete transcript.
    func finish() throws -> String
}

/// A local recognizer that creates independent incremental sessions.
public protocol LocalStreamingRecognizer: LocalSTTEngine {
    func makeRecognitionSession() throws -> any LocalRecognitionSession
}
