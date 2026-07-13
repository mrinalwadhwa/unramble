import Foundation
import Testing

@testable import FreeFlowKit

/// Integration tests that call real local models.
///
/// Gated behind `FREEFLOW_TEST_LOCAL_MODELS=1`. The MLX LLM test
/// requires `FREEFLOW_QWEN_MODEL_PATH` to point to a local model.
/// The Parakeet test requires model files in the app's models directory.
@Suite("Local model integration", .enabled(if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_LOCAL_MODELS"] != nil))
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
            systemPrompt: PolishPipeline.systemPromptLocal,
            userPrompt: "um so i was thinking we should uh meet on thursday")

        print("[MLXPolishClient] Result: \(result)")
        #expect(!result.isEmpty)

        await engine.unload()
    }

    // MARK: - Parakeet STT Engine

    @Test("ParakeetEngine loads and transcribes audio",
          .enabled(if: LocalModelManager().isDownloaded("parakeet-tdt-0.6b-v3")))
    func parakeetEngineTranscription() async throws {
        let manager = LocalModelManager()
        let engine = ParakeetEngine(modelManager: manager)

        #expect(!engine.isReady)
        try await engine.load()
        #expect(engine.isReady)

        // Generate a short silent WAV (1 second of silence).
        let silentPCM = Data(repeating: 0, count: 32000)  // 1s at 16kHz 16-bit mono
        let wav = WAVEncoder.encode(
            pcmData: silentPCM, sampleRate: 16000,
            channels: 1, bitsPerSample: 16)

        let result = try await engine.transcribe(audio: wav)
        print("[ParakeetEngine] Result for silence: '\(result)'")
        // Silence should produce empty or near-empty transcription.

        await engine.unload()
        #expect(!engine.isReady)
    }
}
