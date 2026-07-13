import Foundation

/// Whether dictation uses cloud APIs or on-device processing.
///
/// Cloud mode sends audio to OpenAI for transcription and polishing.
/// Local mode keeps all data on-device using a Core ML STT engine and a
/// fine-tuned Qwen3 0.6B model for polish on Apple Silicon.
/// Currently English-only; non-English languages require cloud mode.
///
/// Persisted in UserDefaults. Defaults to cloud on first launch;
/// onboarding recommends on-device for English on Apple Silicon.
public enum DictationMode: String, CaseIterable, Sendable {
    case cloud
    case local

    /// Human-readable name for display in settings.
    public var displayName: String {
        switch self {
        case .cloud: return "Cloud"
        case .local: return "On-Device"
        }
    }

    /// Whether on-device mode is available on this system.
    ///
    /// Requires Apple Silicon (macOS 14+) for MLX model inference.
    public static var isLocalAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
