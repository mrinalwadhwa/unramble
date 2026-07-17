import Foundation
import Testing

@testable import UnrambleKit

/// Integration tests that call real local models.
///
/// Gated behind `UNRAMBLE_TEST_LOCAL_MODELS=1`. The MLX LLM test
/// requires `UNRAMBLE_QWEN_MODEL_PATH` to point to a local model.
@Suite("Local model integration", .enabled(if: ProcessInfo.processInfo.environment["UNRAMBLE_TEST_LOCAL_MODELS"] != nil))
struct LocalModelIntegrationTests {

    // MARK: - MLX LLM Engine

    @Test("MLXLLMEngine loads and completes a prompt")
    func mlxLLMEngineCompletion() async throws {
        let engine = MLXLLMEngine(
            name: "Qwen3 0.6B",
            modelDirectory: try LocalModelTestSupport.directory())

        #expect(!engine.isReady)
        try await engine.load()
        #expect(engine.isReady)

        let result = try await engine.complete(
            systemPrompt: "You clean up dictated text. Return only the cleaned text.",
            userPrompt: "hello world how are you doing today",
            maxTokens: 50)

        print("[MLXLLMEngine] Result: \(result)")
        #expect(!result.isEmpty)

        await engine.unload()
        #expect(!engine.isReady)
    }

    // MARK: - MLX Polish Client

    @Test("MLXPolishClient polishes text via real engine")
    func mlxPolishClientIntegration() async throws {
        let engine = MLXLLMEngine(
            name: "Qwen3 0.6B",
            modelDirectory: try LocalModelTestSupport.directory())
        try await engine.load()

        let client = MLXPolishClient(engine: engine, timeoutSeconds: 30)
        let result = try await client.complete(
            model: "ignored",
            systemPrompt: PolishPipeline.systemPromptQwen,
            userPrompt: "um so i was thinking we should uh meet on thursday")

        print("[MLXPolishClient] Result: \(result)")
        #expect(!result.isEmpty)

        await engine.unload()
    }
}
