import Foundation
import Security

/// Store and retrieve the OpenAI API key from the macOS Keychain.
///
/// The key is stored as a generic password under the service name
/// `unramble.computer` with account `openai-api-key`, accessible when the
/// device is unlocked.
public final class KeychainService: @unchecked Sendable {

    private let service: String

    private enum Account {
        static let openAIAPIKey = "openai-api-key"
    }

    public init(service: String = "unramble.computer") {
        self.service = service
    }

    // MARK: - OpenAI API key

    /// Save the OpenAI API key to the Keychain, overwriting any existing value.
    @discardableResult
    public func saveOpenAIAPIKey(_ key: String) -> Bool {
        save(value: key, account: Account.openAIAPIKey)
    }

    /// Retrieve the stored OpenAI API key, or nil if none exists.
    public func openAIAPIKey() -> String? {
        load(account: Account.openAIAPIKey)
    }

    /// Delete the stored OpenAI API key.
    @discardableResult
    public func deleteOpenAIAPIKey() -> Bool {
        delete(account: Account.openAIAPIKey)
    }

    // MARK: - Private helpers

    private func save(value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Try to add first. If the item already exists, update in place.
        // This avoids a delete-then-add gap where a crash could lose the key.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }

        if addStatus == errSecDuplicateItem {
            let matchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(
                matchQuery as CFDictionary,
                updateAttributes as CFDictionary)
            return updateStatus == errSecSuccess
        }

        return false
    }

    private func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    @discardableResult
    private func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
