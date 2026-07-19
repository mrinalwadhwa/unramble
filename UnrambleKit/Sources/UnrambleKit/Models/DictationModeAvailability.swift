import Foundation

/// Pure policy for choosing a dictation mode and deciding whether a requested
/// mode can run. The availability inputs are passed in rather than read from
/// singletons, so the decisions stay testable on any host.
public enum DictationModeAvailability {

    /// Resolve the effective mode at launch. Fall back to cloud when the stored
    /// mode is local but on-device processing is unavailable; otherwise keep the
    /// stored mode.
    public static func resolveEffectiveMode(
        stored: DictationMode,
        isLocalAvailable: Bool
    ) -> DictationMode {
        if stored == .local, !isLocalAvailable {
            return .cloud
        }
        return stored
    }

    /// Whether a requested mode can run: local needs on-device availability,
    /// cloud needs a configured API key.
    public static func isAvailable(
        for mode: DictationMode,
        isLocalAvailable: Bool,
        isConfigured: Bool
    ) -> Bool {
        switch mode {
        case .local:
            return isLocalAvailable
        case .cloud:
            return isConfigured
        }
    }
}
