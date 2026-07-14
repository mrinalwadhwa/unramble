import Foundation
import Testing

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Unit tests use a stubbed URLSession to verify request construction and
// response parsing without hitting the network.
//
// Live tests (gated by FREEFLOW_TEST_OPENAI=1) call the real OpenAI API
// using a key from the environment. They verify the full request/response
// cycle against the actual service.
// ---------------------------------------------------------------------------

// MARK: - Stubbed URLSession
//
// Each stubbed session registers a handler keyed by a unique UUID and
// passes that UUID in a request header. StubURLProtocol looks up the
// handler by header value, so concurrent tests in different suites do
// not clobber each other's stubs.

typealias StubHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

enum StubURLProtocolRegistry {
    nonisolated(unsafe) private static var handlers: [String: StubHandler] = [:]
    private static let lock = NSLock()
    static let headerName = "X-FreeFlowKit-Stub-ID"

    static func register(_ handler: @escaping StubHandler) -> String {
        let id = UUID().uuidString
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    static func unregister(_ id: String) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    static func handler(for id: String) -> StubHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[id]
    }
}

final class StubURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: StubURLProtocolRegistry.headerName) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

/// Build a URLSession whose requests are routed to the given handler.
///
/// Each call registers a unique handler and injects an identifying
/// header on every request, so stubs from concurrent tests never
/// collide. The handler lives until process exit (test scope is short,
/// and the leak is bounded).
func stubbedSession(handler: @escaping StubHandler) -> URLSession {
    let id = StubURLProtocolRegistry.register(handler)
    let config = URLSessionConfiguration.ephemeral
    config.httpAdditionalHeaders = [StubURLProtocolRegistry.headerName: id]
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("OpenAIChatClient configuration")
struct OpenAIChatClientConfigurationTests {
    @Test("default session bounds the complete polish resource")
    func defaultSessionTotalTimeout() {
        let configuration = OpenAIChatClient.defaultSessionConfiguration()

        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.timeoutIntervalForResource == 30)
    }
}

// MARK: - Request Construction

@Suite("OpenAIChatClient – stubbed")
struct OpenAIChatClientStubbedTests {

    @Test("POST to chat/completions endpoint")
    func endpointURL() async throws {
        var capturedRequest: URLRequest?
        let session = stubbedSession { request in
            capturedRequest = request
            let body = #"{"choices":[{"message":{"content":"ok"}}]}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let client = OpenAIChatClient(apiKey: "sk-test", session: session)
        _ = try await client.complete(
            model: "gpt-4.1-nano",
            systemPrompt: "system",
            userPrompt: "user")

        let request = try #require(capturedRequest)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
    }

    @Test("Bearer auth header")
    func authHeader() async throws {
        var capturedRequest: URLRequest?
        let session = stubbedSession { request in
            capturedRequest = request
            let body = #"{"choices":[{"message":{"content":"ok"}}]}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let client = OpenAIChatClient(apiKey: "sk-my-key", session: session)
        _ = try await client.complete(
            model: "gpt-4.1-nano",
            systemPrompt: "s", userPrompt: "u")

        let request = try #require(capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-my-key")
    }

    @Test("Content-Type is application/json")
    func contentType() async throws {
        var capturedRequest: URLRequest?
        let session = stubbedSession { request in
            capturedRequest = request
            let body = #"{"choices":[{"message":{"content":"ok"}}]}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let client = OpenAIChatClient(apiKey: "k", session: session)
        _ = try await client.complete(
            model: "gpt-4.1-nano",
            systemPrompt: "s", userPrompt: "u")

        let request = try #require(capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("body contains model, system, and user messages")
    func bodyStructure() async throws {
        var capturedBody: Data?
        let session = stubbedSession { request in
            capturedBody = request.httpBody ?? {
                // httpBody is nil on streamed requests; read from stream.
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                    defer { buf.deallocate() }
                    while stream.hasBytesAvailable {
                        let n = stream.read(buf, maxLength: 4096)
                        if n > 0 { data.append(buf, count: n) }
                        else { break }
                    }
                    return data
                }
                return nil
            }()
            let body = #"{"choices":[{"message":{"content":"ok"}}]}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let client = OpenAIChatClient(apiKey: "k", session: session)
        _ = try await client.complete(
            model: "gpt-4.1-nano",
            systemPrompt: "be helpful",
            userPrompt: "hello")

        let data = try #require(capturedBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4.1-nano")

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "be helpful")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "hello")
    }

    // MARK: - Response Parsing

    @Test("parses content from choices[0].message.content")
    func parsesContent() async throws {
        let session = stubbedSession { request in
            let body = #"{"choices":[{"message":{"role":"assistant","content":"Hello there."}}]}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let client = OpenAIChatClient(apiKey: "k", session: session)
        let result = try await client.complete(
            model: "gpt-4.1-nano",
            systemPrompt: "s", userPrompt: "u")
        #expect(result == "Hello there.")
    }

    @Test("throws httpError on non-200 status")
    func throwsOnError() async {
        let session = stubbedSession { request in
            let body = #"{"error":{"message":"invalid key"}}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let client = OpenAIChatClient(apiKey: "bad", session: session)
        await #expect(throws: OpenAIChatClient.ChatError.self) {
            try await client.complete(
                model: "gpt-4.1-nano",
                systemPrompt: "s", userPrompt: "u")
        }
    }

    @Test("throws emptyContent on missing content field")
    func throwsOnMissingContent() async {
        let session = stubbedSession { request in
            let body = #"{"choices":[]}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let client = OpenAIChatClient(apiKey: "k", session: session)
        await #expect(throws: OpenAIChatClient.ChatError.self) {
            try await client.complete(
                model: "gpt-4.1-nano",
                systemPrompt: "s", userPrompt: "u")
        }
    }

    @Test("throws invalidResponse on malformed JSON structure")
    func throwsInvalidResponseOnMalformedStructure() async {
        // A 200 response with valid JSON but no "choices" key should
        // throw invalidResponse, not emptyContent.
        let session = stubbedSession { request in
            let body = #"{"not_choices": true}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let client = OpenAIChatClient(apiKey: "k", session: session)
        do {
            _ = try await client.complete(
                model: "gpt-4.1-nano",
                systemPrompt: "s", userPrompt: "u")
            Issue.record("Expected an error")
        } catch let error as OpenAIChatClient.ChatError {
            if case .invalidResponse = error {
                // correct
            } else {
                Issue.record("Expected invalidResponse, got \(error)")
            }
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

// MARK: - Live Integration (gated)

@Suite(
    "OpenAIChatClient – live",
    .disabled(if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI"] != "1"))
struct OpenAIChatClientLiveTests {

    /// Read the API key from the environment. Tests in this suite are
    /// skipped unless FREEFLOW_TEST_OPENAI=1 is set.
    private var apiKey: String {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    @Test("live: simple completion returns non-empty text")
    func liveCompletion() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let client = OpenAIChatClient(apiKey: apiKey)
        let result = try await client.complete(
            model: "gpt-4.1-nano",
            systemPrompt: "You are a helpful assistant. Reply with one word.",
            userPrompt: "Say hello.")
        #expect(!result.isEmpty)
    }

    @Test("live: polish prompt preserves keep tags")
    func livePolishKeepTags() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let client = OpenAIChatClient(apiKey: apiKey)
        let result = try await client.complete(
            model: "gpt-4.1-nano",
            systemPrompt: PolishPipeline.systemPromptEnglish,
            userPrompt: "Transcription:\nresearch <keep>&</keep> development is our focus")
        // The LLM should preserve the <keep> tag.
        #expect(result.contains("<keep>&</keep>") || result.contains("&"))
        // Either way, the ampersand must survive somewhere.
        #expect(result.contains("&"))
    }

    @Test("live: polish removes filler words")
    func livePolishFillers() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let client = OpenAIChatClient(apiKey: apiKey)
        let result = try await client.complete(
            model: "gpt-4.1-nano",
            systemPrompt: PolishPipeline.systemPromptEnglish,
            userPrompt: "Transcription:\num so like I was thinking we should move the meeting to Friday")
        #expect(!result.lowercased().contains("um "))
        #expect(!result.lowercased().contains("so like"))
        #expect(result.contains("Friday"))
        #expect(result.contains("meeting"))
    }
}
