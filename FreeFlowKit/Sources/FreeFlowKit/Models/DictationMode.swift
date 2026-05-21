import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether dictation uses cloud APIs or on-device processing.
///
/// Cloud mode sends audio to OpenAI for transcription and polishing.
/// Local mode keeps all data on-device using Parakeet STT and a
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
    /// True when Apple Intelligence is available (macOS 26+), or when
    /// running on Apple Silicon (macOS 14+) where open-source models
    /// can be used.
    public static var isLocalAvailable: Bool {
        if isAppleIntelligenceAvailable { return true }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Whether Apple Intelligence is available for the local backend.
    ///
    /// When true, the local path uses SpeechAnalyzer + Foundation
    /// Models. When false, it falls back to Parakeet + MLX.
    public static var isAppleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }
}
