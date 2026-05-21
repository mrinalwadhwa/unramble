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
// Run:
//   cd FreeFlowKit && xcodebuild test -scheme FreeFlowKit \
//        -destination 'platform=macOS' \
//        -only-testing:FreeFlowKitTests/PolishScenarioDumpMLX \
//        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FREEFLOW_MLX_TESTS'
//
// Output goes to /tmp/freeflow-mlx-eval.log (tail -f to watch live).

#if FREEFLOW_MLX_TESTS

/// Write evaluation output to a log file so it is visible even when
/// xcodebuild swallows test stdout.
private final class EvalLogger {
    let handle: FileHandle

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)!
    }

    func log(_ line: String) {
        handle.write(Data((line + "\n").utf8))
        handle.synchronizeFile()
    }

    deinit { try? handle.close() }
}

private func runMLXDump(
    name: String,
    modelID: String,
    adapterPath: String? = nil,
    scenarios: [PolishScenario]? = nil,
    logPath: String = "/tmp/freeflow-mlx-eval.log"
) async throws {
    let log = EvalLogger(path: logPath)
    let engine: MLXLLMEngine
    if let adapterPath {
        engine = MLXLLMEngine(
            name: name, modelID: modelID, adapterPath: adapterPath)
    } else {
        engine = MLXLLMEngine(name: name, modelID: modelID)
    }
    let client = MLXPolishClient(engine: engine, timeoutSeconds: 30)

    let evalScenarios = scenarios ?? allScenarios
    log.log("=== \(name) ===")
    log.log("")
    var matches = 0
    for s in evalScenarios {
        let casual = s.style == "casual"
        let substituted = PolishPipeline.substituteDictatedPunctuation(
            s.input, casual: casual, precedingText: s.precedingText)
        let stripped = PolishPipeline.stripKeepTags(
            substituted, casual: casual)
        do {
            let raw = try await client.complete(
                model: "",
                systemPrompt: s.systemPrompt(),
                userPrompt: stripped)
            let result = PolishPipeline.normalizeFormatting(
                raw.isEmpty ? stripped : raw)
            let isMatch = s.matches(result)
            if isMatch { matches += 1 }
            let tag = isMatch ? "MATCH" : "DIFF"
            log.log("[\(s.category)] \(tag)")
            log.log("  Input:    \(s.input)")
            log.log("  Output:   \(result)")
            if !isMatch {
                log.log("  Expected: \(s.accepted[0])")
            }
            log.log("")
        } catch {
            log.log("[\(s.category)] ERROR: \(error)")
            log.log("  Input: \(s.input)")
            log.log("")
        }
    }
    log.log("Score: \(matches)/\(evalScenarios.count)")
    log.log("")
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
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            logPath: "/tmp/freeflow-mlx-eval-base.log")
    }

    @Test("Qwen3 1.7B")
    func qwen17() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/freeflow-test-mlx-17")
        else { return }
        try await runMLXDump(
            name: "Qwen3 1.7B",
            modelID: "mlx-community/Qwen3-1.7B-4bit",
            logPath: "/tmp/freeflow-mlx-eval-17.log")
    }

    @Test("Gemma 3 1B")
    func gemma1() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/freeflow-test-mlx-gemma")
        else { return }
        try await runMLXDump(
            name: "Gemma 3 1B",
            modelID: "mlx-community/gemma-3-1b-it-qat-4bit",
            logPath: "/tmp/freeflow-mlx-eval-gemma.log")
    }

    @Test("Qwen3 0.6B Fine-tuned (training set)")
    func qwen06FinetunedTraining() async throws {
        let flagPath = "/tmp/freeflow-test-mlx-adapter-path"
        guard FileManager.default.fileExists(atPath: "/tmp/freeflow-test-mlx-training"),
              FileManager.default.fileExists(atPath: flagPath),
              let adapterPath = try? String(
                contentsOfFile: flagPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !adapterPath.isEmpty
        else { return }
        try await runMLXDump(
            name: "Qwen3 0.6B Fine-tuned (training)",
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            adapterPath: adapterPath,
            scenarios: allTrainingScenarios,
            logPath: "/tmp/freeflow-mlx-eval-training.log")
    }

    @Test("Qwen3 0.6B Fine-tuned")
    func qwen06Finetuned() async throws {
        let flagPath = "/tmp/freeflow-test-mlx-adapter-path"
        guard FileManager.default.fileExists(atPath: flagPath),
              let adapterPath = try? String(
                contentsOfFile: flagPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !adapterPath.isEmpty
        else { return }
        try await runMLXDump(
            name: "Qwen3 0.6B Fine-tuned",
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            adapterPath: adapterPath,
            logPath: "/tmp/freeflow-mlx-eval.log")
    }
}

#endif
