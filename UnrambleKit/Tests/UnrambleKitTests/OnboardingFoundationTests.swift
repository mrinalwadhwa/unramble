import Foundation
import Testing

@testable import UnrambleKit

// MARK: - KeychainService tests

@Suite(
    "KeychainService",
    .enabled(if: ProcessInfo.processInfo.environment["UNRAMBLE_TEST_KEYCHAIN"] == "1"))
struct KeychainServiceTests {

    /// Use a unique service name per test run to avoid cross-contamination
    /// with the real app's Keychain entries.
    private func makeKeychain() -> KeychainService {
        let id = UUID().uuidString.prefix(8)
        return KeychainService(service: "unramble.computer.test.\(id)")
    }

    @Test("Save and retrieve OpenAI API key")
    func saveAndRetrieveKey() {
        let keychain = makeKeychain()
        defer { keychain.deleteOpenAIAPIKey() }

        #expect(keychain.openAIAPIKey() == nil)

        let saved = keychain.saveOpenAIAPIKey("sk-abc123")
        #expect(saved)

        #expect(keychain.openAIAPIKey() == "sk-abc123")
    }

    @Test("Overwrite existing key")
    func overwriteKey() {
        let keychain = makeKeychain()
        defer { keychain.deleteOpenAIAPIKey() }

        keychain.saveOpenAIAPIKey("sk-old")
        keychain.saveOpenAIAPIKey("sk-new")

        #expect(keychain.openAIAPIKey() == "sk-new")
    }

    @Test("Delete key")
    func deleteKey() {
        let keychain = makeKeychain()

        keychain.saveOpenAIAPIKey("sk-delete-me")
        #expect(keychain.openAIAPIKey() != nil)

        let deleted = keychain.deleteOpenAIAPIKey()
        #expect(deleted)
        #expect(keychain.openAIAPIKey() == nil)
    }

    @Test("Delete non-existent item succeeds")
    func deleteNonExistent() {
        let keychain = makeKeychain()

        // Deleting something that was never stored should not fail.
        let deleted = keychain.deleteOpenAIAPIKey()
        #expect(deleted)
    }

    @Test("Empty string is stored and retrieved")
    func emptyString() {
        let keychain = makeKeychain()
        defer { keychain.deleteOpenAIAPIKey() }

        keychain.saveOpenAIAPIKey("")
        #expect(keychain.openAIAPIKey() == "")
    }

    @Test("Long key value round-trips")
    func longKey() {
        let keychain = makeKeychain()
        defer { keychain.deleteOpenAIAPIKey() }

        let longKey = String(repeating: "a", count: 4096)
        keychain.saveOpenAIAPIKey(longKey)
        #expect(keychain.openAIAPIKey() == longKey)
    }

    @Test("Two KeychainService instances with same service share data")
    func sharedService() {
        let serviceName = "unramble.computer.test.shared.\(UUID().uuidString.prefix(8))"
        let keychain1 = KeychainService(service: serviceName)
        let keychain2 = KeychainService(service: serviceName)
        defer { keychain1.deleteOpenAIAPIKey() }

        keychain1.saveOpenAIAPIKey("sk-shared")
        #expect(keychain2.openAIAPIKey() == "sk-shared")
    }

    @Test("Two KeychainService instances with different services are isolated")
    func isolatedServices() {
        let keychain1 = makeKeychain()
        let keychain2 = makeKeychain()
        defer {
            keychain1.deleteOpenAIAPIKey()
            keychain2.deleteOpenAIAPIKey()
        }

        keychain1.saveOpenAIAPIKey("sk-one")
        keychain2.saveOpenAIAPIKey("sk-two")

        #expect(keychain1.openAIAPIKey() == "sk-one")
        #expect(keychain2.openAIAPIKey() == "sk-two")
    }
}

// MARK: - ServiceConfig tests

@Suite(
    "ServiceConfig",
    .enabled(if: ProcessInfo.processInfo.environment["UNRAMBLE_TEST_KEYCHAIN"] == "1"))
struct ServiceConfigTests {

    private func makeKeychain() -> KeychainService {
        let id = UUID().uuidString.prefix(8)
        return KeychainService(service: "unramble.computer.test.\(id)")
    }

    @Test("openAIAPIKey returns Keychain value when present")
    func keyFromKeychain() {
        let keychain = makeKeychain()
        defer { keychain.deleteOpenAIAPIKey() }

        keychain.saveOpenAIAPIKey("sk-keychain")
        let config = ServiceConfig(keychain: keychain)

        // In DEBUG builds the env var takes precedence; skip that case.
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil {
            #expect(config.openAIAPIKey == "sk-keychain")
        }
    }

    @Test("isConfigured is true when key is present")
    func isConfiguredWithKey() {
        let keychain = makeKeychain()
        defer { keychain.deleteOpenAIAPIKey() }

        keychain.saveOpenAIAPIKey("sk-ok")
        let config = ServiceConfig(keychain: keychain)

        #expect(config.isConfigured)
    }

    @Test("isConfigured is false when no key and no env var")
    func isConfiguredWithoutKey() {
        let keychain = makeKeychain()
        let config = ServiceConfig(keychain: keychain)

        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil {
            #expect(!config.isConfigured)
        }
    }
}
