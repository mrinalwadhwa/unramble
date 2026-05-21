import Foundation

/// Errors from local model engines (STT and LLM).
public enum LocalModelError: Error, Sendable, CustomStringConvertible {

    /// The engine was called before loading the model.
    case modelNotLoaded

    /// The model failed to load.
    case modelLoadFailed(String)

    /// Speech-to-text transcription failed.
    case transcriptionFailed(String)

    /// LLM text completion failed.
    case completionFailed(String)

    /// The model files were not found at the expected path.
    case modelNotFound(String)

    public var description: String {
        switch self {
        case .modelNotLoaded:
            return "Model not loaded"
        case .modelLoadFailed(let reason):
            return "Model load failed: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .completionFailed(let reason):
            return "Completion failed: \(reason)"
        case .modelNotFound(let path):
            return "Model not found: \(path)"
        }
    }
}
