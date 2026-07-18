import Foundation
import Testing

@testable import UnrambleKit

// The tests toggle the process-global fail-closed policy, so they must not run
// concurrently with one another.
@Suite("NetworkGuard fail-closed policy", .serialized)
struct NetworkGuardTests {

    @Test("WebSocket transport builder throws when fail closed")
    func webSocketBlockedWhenFailClosed() {
        NetworkGuard.setForcedFailClosed(true)
        defer { NetworkGuard.setForcedFailClosed(nil) }

        #expect(throws: NetworkGuardError.self) {
            _ = try OpenAIStreamingProvider.buildTransport(
                apiKey: "sk-test", model: "gpt-4o-realtime")
        }
    }

    @Test("WebSocket transport builder succeeds when network is allowed")
    func webSocketAllowedWhenNotFailClosed() throws {
        NetworkGuard.setForcedFailClosed(false)
        defer { NetworkGuard.setForcedFailClosed(nil) }

        // Building the task does not open a connection, so it must not throw.
        _ = try OpenAIStreamingProvider.buildTransport(
            apiKey: "sk-test", model: "gpt-4o-realtime")
    }

    @Test("apply installs the fail-closed protocol when blocked")
    func applyInstallsProtocolWhenBlocked() {
        NetworkGuard.setForcedFailClosed(true)
        defer { NetworkGuard.setForcedFailClosed(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        NetworkGuard.apply(to: configuration)

        let installed = configuration.protocolClasses?.contains {
            $0 == FailClosedURLProtocol.self
        }
        #expect(installed == true)
    }

    @Test("apply leaves the configuration untouched when allowed")
    func applyInertWhenAllowed() {
        NetworkGuard.setForcedFailClosed(false)
        defer { NetworkGuard.setForcedFailClosed(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        let before = configuration.protocolClasses?.count ?? 0
        NetworkGuard.apply(to: configuration)
        #expect((configuration.protocolClasses?.count ?? 0) == before)
    }

    @Test("a fail-closed session rejects a request instead of reaching the network")
    func failClosedSessionRejectsRequest() async {
        NetworkGuard.setForcedFailClosed(true)
        defer { NetworkGuard.setForcedFailClosed(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        NetworkGuard.apply(to: configuration)
        let session = URLSession(configuration: configuration)

        do {
            _ = try await session.data(
                from: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
            Issue.record("The fail-closed guard should reject the request")
        } catch {
            // The URLProtocol short-circuits before any socket opens. Whatever
            // error surfaces, the request must not have reached the network.
            let networkFailure = (error as? URLError)?.code
            #expect(
                networkFailure != .timedOut && networkFailure != .cannotConnectToHost,
                "Expected a fail-closed rejection, not a live network failure: \(error)")
        }
    }
}
