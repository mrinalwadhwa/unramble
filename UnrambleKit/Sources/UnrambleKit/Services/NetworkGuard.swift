import Foundation

/// Fail-closed network policy for deterministic test lanes.
///
/// A production app run links no test framework and sets no live-network gate,
/// so `isFailClosed` stays false and both OpenAI session builders reach the
/// network unchanged. Inside a test bundle the guard turns on unless the run
/// opts into live traffic with `UNRAMBLE_TEST_OPENAI`. Any code path that then
/// builds a live OpenAI connection fails fast with `NetworkGuardError.blocked`
/// instead of hanging on a real request or silently succeeding. A test that
/// needs a specific policy sets it directly with `setForcedFailClosed(_:)`.
enum NetworkGuard {

    private static let lock = NSLock()
    private static var forcedFailClosed: Bool?

    /// Force the policy on or off regardless of the environment. Reset to `nil`
    /// to restore the default, environment-driven behavior.
    static func setForcedFailClosed(_ value: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        forcedFailClosed = value
    }

    /// Whether live network access is currently blocked.
    static var isFailClosed: Bool {
        lock.lock()
        let forced = forcedFailClosed
        lock.unlock()
        if let forced {
            return forced
        }
        let environment = ProcessInfo.processInfo.environment
        if environment["UNRAMBLE_TEST_OPENAI"] == "1" {
            return false
        }
        // The production app links no test framework, so this stays false there.
        return NSClassFromString("XCTestCase") != nil
    }

    /// Throw when a live connection builder runs in a fail-closed lane. Use for a
    /// path that cannot route through a URLProtocol, such as a WebSocket task.
    static func assertLiveNetworkAllowed(_ context: String) throws {
        if isFailClosed {
            throw NetworkGuardError.blocked(context: context)
        }
    }

    /// Install the fail-closed URLProtocol on a configuration that is about to
    /// back a real URLSession, so a request through it fails immediately rather
    /// than reaching the network. A no-op when live network is allowed.
    static func apply(to configuration: URLSessionConfiguration) {
        guard isFailClosed else { return }
        var classes = configuration.protocolClasses ?? []
        classes.insert(FailClosedURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
    }
}

/// Error surfaced when a deterministic test lane attempts live network access.
enum NetworkGuardError: Error, Equatable, CustomStringConvertible {
    case blocked(context: String)

    var description: String {
        switch self {
        case .blocked(let context):
            return "Live network access is blocked in this test lane: \(context)"
        }
    }
}

/// URLProtocol that fails every request with `NetworkGuardError.blocked`. It is
/// installed only on sessions built while the guard is fail-closed.
final class FailClosedURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let target = request.url?.absoluteString ?? "an unknown URL"
        client?.urlProtocol(
            self, didFailWithError: NetworkGuardError.blocked(context: target))
    }

    override func stopLoading() {}
}
