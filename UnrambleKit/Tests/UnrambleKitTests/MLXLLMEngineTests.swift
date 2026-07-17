import Foundation
import Testing

@testable import UnrambleKit

@Suite("MLX LLM engine")
struct MLXLLMEngineTests {

    @Test("Missing local model directory fails with its path")
    func missingModelDirectory() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let engine = MLXLLMEngine(
            name: "Missing model", modelDirectory: directory)

        do {
            try await engine.load()
            Issue.record("Expected the missing model directory to fail")
        } catch let LocalModelError.modelNotFound(path) {
            #expect(path == directory.path)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Remote model URL is rejected")
    func remoteModelURL() async {
        let remoteURL = URL(
            string: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit")!
        let engine = MLXLLMEngine(
            name: "Remote model", modelDirectory: remoteURL)

        do {
            try await engine.load()
            Issue.record("Expected the remote model URL to fail")
        } catch let LocalModelError.modelLoadFailed(reason) {
            #expect(reason.contains("local file URL"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
