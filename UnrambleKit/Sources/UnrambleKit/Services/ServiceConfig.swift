import Foundation

/// Resolve the OpenAI API key used by dictation providers.
///
/// The key is stored in the Keychain by the onboarding flow. In debug
/// builds, `OPENAI_API_KEY` in the process environment overrides the
/// Keychain value so local development does not trigger Keychain
/// password prompts on every build.
public final class ServiceConfig: @unchecked Sendable {

    /// Shared instance used by service providers when no explicit
    /// config is injected.
    public static let shared = ServiceConfig()

    private let keychain: KeychainService

    public init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
    }

    /// Current OpenAI API key, or nil when none is configured.
    public var openAIAPIKey: String? {
        #if DEBUG
            if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
                !key.isEmpty
            {
                return key
            }
        #endif
        return keychain.openAIAPIKey()
    }

    /// Whether an OpenAI API key is available.
    public var isConfigured: Bool {
        if let key = openAIAPIKey, !key.isEmpty { return true }
        return false
    }
}
