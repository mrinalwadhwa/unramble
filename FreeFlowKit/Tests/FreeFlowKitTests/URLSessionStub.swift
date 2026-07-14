import Foundation

typealias StubHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

enum StubURLProtocolRegistry {
    nonisolated(unsafe) private static var handlers: [String: StubHandler] = [:]
    private static let lock = NSLock()
    static let headerName = "X-FreeFlowKit-Stub-ID"

    static func register(_ handler: @escaping StubHandler) -> String {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        return id
    }

    static func handler(for id: String) -> StubHandler? {
        lock.withLock { handlers[id] }
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: StubURLProtocolRegistry.headerName) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: StubURLProtocolRegistry.headerName) ?? ""
        guard let handler = StubURLProtocolRegistry.handler(for: id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func stubbedSession(handler: @escaping StubHandler) -> URLSession {
    let id = StubURLProtocolRegistry.register(handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpAdditionalHeaders = [StubURLProtocolRegistry.headerName: id]
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}
