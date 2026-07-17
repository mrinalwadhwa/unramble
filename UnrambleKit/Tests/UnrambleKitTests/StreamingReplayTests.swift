import Foundation
import Testing

@testable import UnrambleKit

// Replay a saved WAV through the REAL on-device streaming path — Nemotron
// incremental STT, pause/size units, per-unit Qwen polish accumulated
// internally — and reconstruct the text that would land in the editor from
// the single injection at release, using AppTextInjector's spacing rules.
// This reproduces offline what a live dictation produces, which batch replay
// (PipelineReplayTests) does not: batch polishes the whole transcript at once.
//
// Needs Metal for Qwen, so run via xcodebuild:
//
//   touch /tmp/unramble-test-streaming-replay
//   cd UnrambleKit && xcodebuild test -scheme UnrambleKit \
//        -destination 'platform=macOS' \
//        -only-testing:UnrambleKitTests/StreamingReplay \
//        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) UNRAMBLE_MLX_TESTS'
//
// Inputs (flag files — xcodebuild does not forward shell env to xctest):
//   /tmp/unramble-replay-dir      contents: directory of sample WAVs (required;
//                                 the recordings are not in the repository)
//   /tmp/unramble-replay-only     contents: a WAV basename to replay alone
//   /tmp/unramble-replay-step-ms  contents: audio fed per cycle (default 3000)
//
// Output: /tmp/unramble-streaming-replay.log — the reconstructed editor text
// and an independent whole-file raw STT baseline.

#if UNRAMBLE_MLX_TESTS

@Suite("Streaming replay")
struct StreamingReplay {

    @Test("Replay saved WAVs through the streaming path")
    func replay() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/unramble-test-streaming-replay")
        else { return }

        let readFlag = { (path: String) -> String? in
            guard let s = try? String(contentsOfFile: path, encoding: .utf8)
            else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        // Sample recordings are not in the repository; the caller supplies the
        // directory that holds them. There is no default path.
        guard let dirPath = readFlag("/tmp/unramble-replay-dir") else {
            Issue.record(
                "set /tmp/unramble-replay-dir to a directory of sample WAVs")
            return
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)

        let only = readFlag("/tmp/unramble-replay-only")
        let stepMS = max(
            1, Int(readFlag("/tmp/unramble-replay-step-ms") ?? "") ?? 3000)
        let repeats = max(1, Int(
            readFlag("/tmp/unramble-replay-repeat") ?? "") ?? 1)
        // Optional unit-size override, to A/B test the guard-trigger rate.
        let policy = Double(readFlag("/tmp/unramble-replay-maxunit-sec") ?? "")
            .map { LocalUnitPolicy(maximumUnitSeconds: $0) } ?? LocalUnitPolicy()

        var wavs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))
            ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        if let only { wavs = wavs.filter { $0 == only } }
        guard !wavs.isEmpty else {
            Issue.record("no matching WAVs under \(dir.path)")
            return
        }

        guard let modelsDir = modelsDir() else {
            Issue.record("model pack not found under UnrambleApp/Resources")
            return
        }
        let modelManager = LocalModelManager(modelsDirectory: modelsDir)
        let nemotron = NemotronEngine(modelManager: modelManager)
        try await nemotron.load()

        // Qwen with the fine-tuned adapter if installed, matching production.
        let adapterDir = modelManager.modelPath(
            for: "qwen3-0.6b-4bit-polish-adapter")
        let hasAdapter = FileManager.default.fileExists(
            atPath: adapterDir.appendingPathComponent(
                "adapters.safetensors").path)
        let engine = MLXLLMEngine(
            name: "Qwen3 0.6B Polish",
            modelDirectory: modelManager.modelPath(for: "qwen3-0.6b-4bit"),
            adapterDirectory: hasAdapter ? adapterDir : nil)
        let client = MLXPolishClient(engine: engine, timeoutSeconds: 30)

        let log = ReplayLog(path: "/tmp/unramble-streaming-replay.log")
        log.log("=== streaming replay (\(wavs.count) files, adapter=\(hasAdapter), step=\(stepMS)ms) ===\n")

        for name in wavs {
            let wav = try Data(contentsOf: dir.appendingPathComponent(name))
            guard wav.count > 44 else { continue }
            let pcm = wav.subdata(in: WAVEncoder.headerSize..<wav.count)
            let rawTranscript = try LocalRecognitionFixtureSupport.recognize(
                wavData: wav, using: nemotron)

            // The recognizer is deterministic, so the raw STT is fixed; polish
            // is not, so repeat to measure its run-to-run error rate. Each run
            // uses a fresh provider. Production injects the whole result once at
            // release, so the editor is reconstructed from that single result.
            for run in 0..<repeats {
                let provider = LocalStreamingProvider(
                    sttEngine: nemotron, polishChatClient: client,
                    cycleInterval: Double(stepMS) / 1000,
                    unitPolicy: policy)
                let result = try await provider.replayForTesting(pcm)

                var editor = ""
                Self.appendChunk(result, to: &editor)
                let editorText = editor.trimmingCharacters(in: .whitespaces)

                // One machine-parseable record per run for offline scoring.
                let record = "{\"wav\":\"\(name)\",\"run\":\(run)"
                    + ",\"paras\":\(paragraphCount(editorText))"
                    + ",\"stt\":\"\(jsonEscape(rawTranscript))\""
                    + ",\"out\":\"\(jsonEscape(editorText))\"}"
                log.log("[[RUN]] \(record)")
            }
        }

        await nemotron.unload()
        await engine.unload()
    }

    // MARK: - Editor reconstruction (mirrors AppTextInjector spacing)

    /// Append `raw` text to `editor` the way DictationPipeline injects the
    /// final result through AppTextInjector.inject: trim only horizontal
    /// whitespace, append a trailing space unless it ends with a break, and
    /// add a leading space unless it starts with a break or punctuation or
    /// the previous character already suppresses it.
    static func appendChunk(_ raw: String, to editor: inout String) {
        let horizontal = CharacterSet(charactersIn: " \t")
        let toInject = raw.trimmingCharacters(in: horizontal)
        guard !toInject.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty else { return }

        var chunk = toInject
        if !(chunk.hasSuffix(" ") || chunk.hasSuffix("\n")) { chunk += " " }

        var lead = ""
        if let before = editor.last {
            let noSpaceAfter: Set<Character> = [
                " ", "\t", "\n", "\r", "(", "[", "{", "<",
                "\"", "'", "`", "/", "\\",
            ]
            let startsBreak = chunk.hasPrefix(" ") || chunk.hasPrefix("\n")
            let startsPunct = chunk.first?.isPunctuation ?? false
            if !startsBreak && !startsPunct && !noSpaceAfter.contains(before) {
                lead = " "
            }
        }
        editor += lead + chunk
    }

    // MARK: - Helpers

    /// The app's pinned model pack, so the replay uses the same Nemotron and
    /// Qwen models the app ships rather than an Application Support override.
    private func modelsDir() -> URL? {
        findUpwards("UnrambleApp/Resources/models")
    }

    private func findUpwards(_ relative: String) -> URL? {
        var dir = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Make newlines visible in the log so break placement is unambiguous.
private func visible(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: "\\n")
}

/// Escape a string for a single-line JSON record.
private func jsonEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

private func indent(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "      | \($0)" }.joined(separator: "\n")
}

private func paragraphCount(_ s: String) -> Int {
    s.components(separatedBy: "\n\n").filter {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.count
}

/// Thread-safe collector for chunks emitted by the handler.
private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []
    func append(_ s: String) { lock.withLock { chunks.append(s) } }
    var all: [String] { lock.withLock { chunks } }
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
