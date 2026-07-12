import CryptoKit
import Foundation
import Testing

@testable import FreeFlowKit

// Replay pre-generated TTS audio through the on-device pipeline to
// establish a baseline: Nemotron STT -> stock Qwen3 polish (no adapter).
//
// For each WAV in .scratch/e2e/audio/, transcribe with Nemotron and
// polish with an unmodified Qwen3 0.6B. Log the real STT output and the
// polished result so the eval set is built from genuine model output
// rather than hypothetical inputs.
//
// Needs Metal for Qwen3, so it must run via xcodebuild (swift test
// crashes with "Failed to load the default metallib").
//
// Enable: touch /tmp/freeflow-test-nemotron-baseline
// Run:
//   cd FreeFlowKit && xcodebuild test -scheme FreeFlowKit \
//        -destination 'platform=macOS' \
//        -only-testing:FreeFlowKitTests/NemotronBaseline \
//        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FREEFLOW_MLX_TESTS'
//
// Output (tail -f to watch live):
//   /tmp/freeflow-nemotron-baseline.log    — human-readable dump
//   /tmp/freeflow-nemotron-baseline.jsonl  — one JSON record per file

#if FREEFLOW_MLX_TESTS

/// Append lines to a log file so output survives xcodebuild swallowing
/// test stdout.
private final class BaselineLogger {
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

@Suite("Nemotron Baseline")
struct NemotronBaseline {

    /// A single audio fixture with its parsed category and hash.
    private struct Fixture {
        let url: URL
        let category: String
        let hash: String
    }

    @Test("Replay TTS audio through Nemotron + stock Qwen3")
    func replay() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/freeflow-test-nemotron-baseline")
        else { return }

        guard let audioDir = findAudioDir() else {
            Issue.record("Audio fixtures not found under .scratch/e2e/audio")
            return
        }

        let fixtures = loadFixtures(audioDir)
        guard !fixtures.isEmpty else {
            Issue.record("No WAV fixtures in \(audioDir.path)")
            return
        }

        // Recover the intended text for each fixture by matching the
        // filename hash against the current scenario set. Best-effort:
        // scenarios that changed since the audio was generated will not
        // match and show as "(unknown)".
        let intendedByKey = intendedTextLookup()

        // Nemotron STT.
        let modelManager = LocalModelManager()
        let nemotron = NemotronEngine(modelManager: modelManager)
        try await nemotron.load()

        // Stock Qwen3 0.6B — no adapter.
        let engine = MLXLLMEngine(
            name: "Qwen3 0.6B", modelID: "mlx-community/Qwen3-0.6B-4bit")
        let client = MLXPolishClient(engine: engine, timeoutSeconds: 30)

        let log = BaselineLogger(path: "/tmp/freeflow-nemotron-baseline.log")
        let jsonl = BaselineLogger(path: "/tmp/freeflow-nemotron-baseline.jsonl")

        log.log("=== Nemotron STT -> stock Qwen3 (no adapter) ===")
        log.log("\(fixtures.count) files from \(audioDir.path)")
        log.log("")

        var categoryCounts: [String: Int] = [:]
        var index = 0
        for fixture in fixtures {
            index += 1
            categoryCounts[fixture.category, default: 0] += 1

            let wav = try Data(contentsOf: fixture.url)
            guard wav.count > 44 else { continue }

            let sttStart = CFAbsoluteTimeGetCurrent()
            let stt = (try? await nemotron.transcribe(audio: wav)) ?? ""
            let sttTime = CFAbsoluteTimeGetCurrent() - sttStart

            let polished: String
            if stt.isEmpty {
                polished = ""
            } else {
                let raw = await PolishPipeline.polish(stt, chatClient: client)
                polished = PolishPipeline.stripTrailingFiller(raw)
            }

            let intended = intendedByKey["\(fixture.category)-\(fixture.hash)"]
                ?? "(unknown)"

            log.log("[\(fixture.category)] \(fixture.url.lastPathComponent)")
            log.log("  Intended: \(intended)")
            log.log("  STT:      \(stt)")
            log.log("  Polished: \(polished)")
            log.log(String(format: "            (stt=%.2fs)", sttTime))
            log.log("")

            jsonl.log(jsonLine([
                "n": index,
                "category": fixture.category,
                "file": fixture.url.lastPathComponent,
                "intended": intended,
                "stt": stt,
                "polished": polished,
            ]))
        }

        log.log("=== \(fixtures.count) files across "
            + "\(categoryCounts.count) categories ===")
        for cat in categoryCounts.keys.sorted() {
            log.log("  \(cat): \(categoryCounts[cat]!)")
        }

        await nemotron.unload()
        await engine.unload()
    }

    // MARK: - Helpers

    /// Walk up from this source file to find `.scratch/e2e/audio`.
    private func findAudioDir() -> URL? {
        var dir = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(".scratch/e2e/audio")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// List WAV fixtures, parsing `{category}-{8 hex}.wav` filenames.
    /// Categories may contain hyphens, so split on the final hyphen.
    private func loadFixtures(_ dir: URL) -> [Fixture] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: dir.path)) ?? []
        var fixtures: [Fixture] = []
        for name in names.sorted() where name.hasSuffix(".wav") {
            let stem = String(name.dropLast(4))
            guard let dash = stem.lastIndex(of: "-") else { continue }
            let hash = String(stem[stem.index(after: dash)...])
            let category = String(stem[..<dash])
            guard hash.count == 8,
                hash.allSatisfy({ $0.isHexDigit })
            else { continue }
            fixtures.append(Fixture(
                url: dir.appendingPathComponent(name),
                category: category, hash: hash))
        }
        return fixtures
    }

    /// Map `{category}-{md5 prefix}` to the scenario input, matching how
    /// the audio filenames were generated (first 4 bytes of MD5(input)).
    private func intendedTextLookup() -> [String: String] {
        var lookup: [String: String] = [:]
        for scenario in allScenarios {
            let data = scenario.input.data(using: .utf8) ?? Data()
            let digest = Insecure.MD5.hash(data: data)
            let hash = digest.prefix(4).map {
                String(format: "%02x", $0)
            }.joined()
            lookup["\(scenario.category)-\(hash)"] = scenario.input
        }
        return lookup
    }

    /// Serialize a record to a single JSON line.
    private func jsonLine(_ record: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

#endif
