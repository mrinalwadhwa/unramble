import Foundation
import Testing

@testable import UnrambleKit
import UnrambleKitTestSupport

@Suite("MLXPolishClient")
struct MLXPolishClientTests {

    // MARK: - Helpers

    private func makeClient(
        engine: MockLocalLLMEngine,
        timeoutSeconds: TimeInterval = 10
    ) -> MLXPolishClient {
        MLXPolishClient(engine: engine, timeoutSeconds: timeoutSeconds)
    }

    // MARK: - Basic completion

    @Test("Returns polished text from engine")
    func returnsPolishedText() async throws {
        let engine = MockLocalLLMEngine()
        engine.stubbedCompletion = "Hello, world."
        let client = makeClient(engine: engine)

        let result = try await client.complete(
            model: "ignored", systemPrompt: "system", userPrompt: "hello world")

        #expect(result == "Hello, world.")
        #expect(engine.completeCallCount == 1)
    }

    @Test("Trims whitespace from engine output")
    func trimsWhitespace() async throws {
        let engine = MockLocalLLMEngine()
        engine.stubbedCompletion = "  Hello, world.  \n"
        let client = makeClient(engine: engine)

        let result = try await client.complete(
            model: "ignored", systemPrompt: "system", userPrompt: "hello world")

        #expect(result == "Hello, world.")
    }

    // MARK: - Empty response

    @Test("Returns empty string when engine returns empty")
    func emptyEngineResponse() async throws {
        let engine = MockLocalLLMEngine()
        engine.stubbedCompletion = ""
        let client = makeClient(engine: engine)

        let result = try await client.complete(
            model: "ignored", systemPrompt: "system", userPrompt: "hello")

        #expect(result == "")
    }

    @Test("Returns empty string when engine returns only whitespace")
    func whitespaceOnlyResponse() async throws {
        let engine = MockLocalLLMEngine()
        engine.stubbedCompletion = "   \n  "
        let client = makeClient(engine: engine)

        let result = try await client.complete(
            model: "ignored", systemPrompt: "system", userPrompt: "hello")

        #expect(result == "")
    }

    // MARK: - Engine errors

    @Test("Auto-loads engine when not ready")
    func autoLoadsWhenNotReady() async throws {
        let engine = MockLocalLLMEngine()
        engine.stubbedIsReady = false
        engine.stubbedCompletion = "loaded result"
        let client = makeClient(engine: engine)

        let result = try await client.complete(
            model: "ignored", systemPrompt: "system", userPrompt: "hello")

        #expect(engine.loadCallCount == 1)
        #expect(engine.completeCallCount == 1)
        #expect(result == "loaded result")
    }

    @Test("Propagates load errors")
    func propagatesLoadErrors() async {
        let engine = MockLocalLLMEngine()
        engine.stubbedIsReady = false
        engine.stubbedLoadError = LocalModelError.modelNotFound("test")
        let client = makeClient(engine: engine)

        await #expect(throws: LocalModelError.self) {
            try await client.complete(
                model: "ignored", systemPrompt: "system", userPrompt: "hello")
        }
        #expect(engine.completeCallCount == 0)
    }

    @Test("Returns empty string when engine throws")
    func returnsEmptyOnEngineError() async throws {
        let engine = MockLocalLLMEngine()
        engine.stubbedError = LocalModelError.completionFailed("test error")
        let client = makeClient(engine: engine)

        let result = try await client.complete(
            model: "ignored", systemPrompt: "system", userPrompt: "hello")

        #expect(result == "")
    }

    // MARK: - Timeout

    @Test("Returns empty string on timeout")
    func returnsEmptyOnTimeout() async throws {
        let engine = MockLocalLLMEngine()
        engine.stubbedCompletion = "Hello, world."
        let client = makeClient(engine: engine, timeoutSeconds: 0.05)

        // Make the engine slow by injecting a delay via a custom stub.
        // We'll use a separate slow engine for this.
        let slowEngine = SlowMockLLMEngine(delay: 1.0)
        let slowClient = MLXPolishClient(engine: slowEngine, timeoutSeconds: 0.05)

        let result = try await slowClient.complete(
            model: "ignored", systemPrompt: "system", userPrompt: "hello")

        #expect(result == "")
    }

    // MARK: - Prompt passthrough

    @Test("Passes system and user prompts to engine")
    func passesPromptsThrough() async throws {
        let engine = MockLocalLLMEngine()
        engine.stubbedCompletion = "result"
        let client = makeClient(engine: engine)

        _ = try await client.complete(
            model: "ignored", systemPrompt: "Be concise", userPrompt: "fix this text")

        #expect(engine.receivedPrompts.count == 1)
        #expect(engine.receivedPrompts[0].system == "Be concise")
        // /no_think prefix suppresses Qwen3 chain-of-thought mode.
        #expect(engine.receivedPrompts[0].user == "/no_think\nfix this text")
    }
}

// MARK: - SlowMockLLMEngine

/// A mock LLM engine that introduces a delay to test timeout behavior.
private final class SlowMockLLMEngine: LocalLLMEngine, @unchecked Sendable {
    let name = "SlowMockLLM"
    var isReady: Bool { true }
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func load() async throws {}
    func unload() async {}

    func complete(
        systemPrompt: String, userPrompt: String, maxTokens: Int
    ) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return "Delayed result"
    }
}
