import Foundation
import Testing

@testable import FreeFlowKit

// Replay saved WAV files through the real on-device pipeline — Nemotron
// STT then Qwen polish (with the fine-tuned adapter when present) — so a
// captured dictation can be re-run deterministically instead of
// re-dictated. Needs Metal for Qwen, so run via xcodebuild:
//
//   touch /tmp/freeflow-test-replay
//   cd FreeFlowKit && xcodebuild test -scheme FreeFlowKit \
//        -destination 'platform=macOS' \
//        -only-testing:FreeFlowKitTests/PipelineReplay \
//        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FREEFLOW_MLX_TESTS'
//
// Replays every .wav under .scratch/nemotron-eval/samples/. Output:
//   /tmp/freeflow-replay.log   — raw STT and polished text per file

#if FREEFLOW_MLX_TESTS

@Suite("Pipeline replay")
struct PipelineReplay {

    @Test("Replay saved WAVs through Nemotron + Qwen polish")
    func replay() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/freeflow-test-replay")
        else { return }

        guard let dir = samplesDir() else {
            Issue.record("samples dir not found under .scratch")
            return
        }
        let wavs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))
            ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        guard !wavs.isEmpty else {
            Issue.record("no WAVs under \(dir.path)")
            return
        }

        let modelManager = LocalModelManager()
        let nemotron = NemotronEngine(modelManager: modelManager)
        try await nemotron.load()

        // Qwen with the fine-tuned adapter if it is installed, matching
        // the production polish; otherwise stock Qwen.
        let adapterDir = modelManager.modelPath(
            for: "qwen3-0.6b-4bit-polish-adapter")
        let hasAdapter = FileManager.default.fileExists(
            atPath: adapterDir.appendingPathComponent(
                "adapters.safetensors").path)
        let engine = MLXLLMEngine(
            name: "Qwen3 0.6B Polish",
            modelDirectory: try LocalModelTestSupport.directory(),
            adapterDirectory: hasAdapter ? adapterDir : nil)
        let client = MLXPolishClient(engine: engine, timeoutSeconds: 30)

        let log = ReplayLog(path: "/tmp/freeflow-replay.log")
        log.log("=== replay (\(wavs.count) files, adapter=\(hasAdapter)) ===\n")

        for name in wavs {
            let wav = try Data(
                contentsOf: dir.appendingPathComponent(name))
            guard wav.count > 44 else { continue }

            let raw = try await nemotron.transcribe(audio: wav)
            let polished = PolishPipeline.stripTrailingFiller(
                await PolishPipeline.polish(raw, chatClient: client))

            log.log("[\(name)]")
            log.log("  raw  (\(raw.split(separator: " ").count)w): \(raw)")
            log.log("  poli (\(polished.split(separator: " ").count)w): \(polished)")
            log.log("")

            if name == "rambly-styling.wav" {
                #expect(
                    polished.lowercased().contains("colors"),
                    "dropped 'colors': \(polished)")
                #expect(
                    polished.lowercased().contains("purpose of the document"),
                    "dropped closing clause: \(polished)")
            }
        }

        await nemotron.unload()
        await engine.unload()
    }

    private func samplesDir() -> URL? {
        var dir = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(
                ".scratch/nemotron-eval/samples")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

private final class ReplayLog {
    let handle: FileHandle
    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)!
    }
    func log(_ line: String) {
        handle.write(Data((line + "\n").utf8))
        try? handle.synchronize()
    }
    deinit { try? handle.close() }
}

#endif
