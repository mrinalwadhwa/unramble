import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether dictation uses cloud APIs or on-device processing.
///
/// Cloud mode sends audio to OpenAI for transcription and polishing.
/// Local mode keeps all data on-device using the best available
/// backend:
/// - macOS 26+ with Apple Intelligence: SpeechAnalyzer + Foundation
///   Models (existing path).
/// - macOS 14+ on Apple Silicon: Parakeet STT + MLX LLM polish
///   (open-source models).
///
/// Persisted in UserDefaults. Defaults to cloud.
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
