import Testing
import Foundation
@testable import FreeFlowKit

// MLX model dump tests. Must be run via xcodebuild (Metal shaders required).
// swift test will crash with "Failed to load the default metallib".
//
// Enable via file flags:
//   touch /tmp/freeflow-test-mlx       # Qwen3 0.6B
//   touch /tmp/freeflow-test-mlx-17    # Qwen3 1.7B
//   touch /tmp/freeflow-test-mlx-gemma # Gemma 3 1B
//
// Run: cd FreeFlowKit && xcodebuild test -scheme FreeFlowKit \
//        -destination 'platform=macOS' \
//        -only-testing:FreeFlowKitTests/PolishScenarioDumpMLX

// Disabled for swift test — MLX requires Metal shaders only available
// via xcodebuild. Enable this block when running via xcodebuild.
#if FREEFLOW_MLX_TESTS

private func runMLXDump(name: String, modelID: String) async throws {
    let engine = MLXLLMEngine(name: name, modelID: modelID)
    let client = MLXPolishClient(engine: engine, timeoutSeconds: 30)

    print("\n=== \(name) (systemPromptQwen + MLX) ===\n")
    var matches = 0
    for s in allScenarios {
        let substituted = PolishPipeline.substituteDictatedPunctuation(s.input)
        let stripped = PolishPipeline.stripKeepTags(substituted)
        do {
            // Send tag-stripped text to local model (matches
            // real provider behavior — local models don't
            // understand <keep> tags).
            let raw = try await client.complete(
                model: "",
                systemPrompt: PolishPipeline.systemPromptQwen,
                userPrompt: stripped)
            let result = PolishPipeline.normalizeFormatting(
                raw.isEmpty ? stripped : raw)
            let isMatch = s.matches(result)
            if isMatch { matches += 1 }
            let tag = isMatch ? "MATCH" : "DIFF"
            print("[\(s.category)] \(tag)")
            print("  Input:    \(s.input)")
            print("  Output:   \(result)")
            if !isMatch {
                print("  Expected: \(s.accepted[0])")
            }
            print()
        } catch {
            print("[\(s.category)] ERROR: \(error)")
            print("  Input: \(s.input)\n")
        }
    }
    print("Score: \(matches)/\(allScenarios.count)\n")
    await engine.unload()
}

@Suite("Polish Scenario Dump -- MLX Models")
struct PolishScenarioDumpMLX {
    @Test("Qwen3 0.6B")
    func qwen06() async throws {
        guard ProcessInfo.processInfo.environment["FREEFLOW_TEST_QWEN"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/freeflow-test-mlx")
        else { return }
        try await runMLXDump(
            name: "Qwen3 0.6B",
            modelID: "mlx-community/Qwen3-0.6B-4bit")
    }

    @Test("Qwen3 1.7B")
    func qwen17() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/freeflow-test-mlx-17")
        else { return }
        try await runMLXDump(
            name: "Qwen3 1.7B",
            modelID: "mlx-community/Qwen3-1.7B-4bit")
    }

    @Test("Gemma 3 1B")
    func gemma1() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/freeflow-test-mlx-gemma")
        else { return }
        try await runMLXDump(
            name: "Gemma 3 1B",
            modelID: "mlx-community/gemma-3-1b-it-qat-4bit")
    }

    @Test("Qwen3 0.6B Fine-tuned")
    func qwen06Finetuned() async throws {
        // Adapter path file contains the absolute path to the LoRA
        // adapter directory (adapter_config.json + adapters.safetensors).
        let flagPath = "/tmp/freeflow-test-mlx-adapter-path"
        guard FileManager.default.fileExists(atPath: flagPath),
              let adapterPath = try? String(
                contentsOfFile: flagPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !adapterPath.isEmpty
        else { return }
        let engine = MLXLLMEngine(
            name: "Qwen3 0.6B Fine-tuned",
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            adapterPath: adapterPath)
        let client = MLXPolishClient(engine: engine, timeoutSeconds: 30)

        print("\n=== Qwen3 0.6B Fine-tuned (systemPromptQwen + LoRA) ===\n")
        var matches = 0
        for s in allScenarios {
            let substituted = PolishPipeline.substituteDictatedPunctuation(s.input)
            let stripped = PolishPipeline.stripKeepTags(substituted)
            do {
                let raw = try await client.complete(
                    model: "",
                    systemPrompt: PolishPipeline.systemPromptQwen,
                    userPrompt: stripped)
                let result = PolishPipeline.normalizeFormatting(
                    raw.isEmpty ? stripped : raw)
                let isMatch = s.matches(result)
                if isMatch { matches += 1 }
                let tag = isMatch ? "MATCH" : "DIFF"
                print("[\(s.category)] \(tag)")
                print("  Input:    \(s.input)")
                print("  Output:   \(result)")
                if !isMatch {
                    print("  Expected: \(s.accepted[0])")
                }
                print()
            } catch {
                print("[\(s.category)] ERROR: \(error)")
                print("  Input: \(s.input)\n")
            }
        }
        print("Score: \(matches)/\(allScenarios.count)\n")
        await engine.unload()
    }
}

#endif
