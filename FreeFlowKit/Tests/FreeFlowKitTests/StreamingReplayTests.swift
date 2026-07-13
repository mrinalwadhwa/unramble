import Foundation
import Testing

@testable import FreeFlowKit

// Replay a saved WAV through the REAL streaming path — Nemotron incremental
// STT + CommitTracker commits + per-chunk Qwen polish + rolling injection —
// and reconstruct the text that would land in the editor, using the exact
// spacing rules of AppTextInjector. This reproduces offline what a live
// dictation actually injects, which batch replay (PipelineReplayTests)
// does not: batch polishes the whole transcript at once, while production
// polishes each committed sentence separately.
//
// Needs Metal for Qwen, so run via xcodebuild:
//
//   touch /tmp/freeflow-test-streaming-replay
//   cd FreeFlowKit && xcodebuild test -scheme FreeFlowKit \
//        -destination 'platform=macOS' \
//        -only-testing:FreeFlowKitTests/StreamingReplay \
//        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FREEFLOW_MLX_TESTS'
//
// Options (flag files — xcodebuild does not forward shell env to xctest):
//   /tmp/freeflow-replay-only     contents: a WAV basename to replay alone
//   /tmp/freeflow-replay-step-ms  contents: audio fed per cycle (default 3000)
//
// Output: /tmp/freeflow-streaming-replay.log — per-cycle committed chunks
// (newlines made visible), the reconstructed editor text, and the raw STT.

#if FREEFLOW_MLX_TESTS

@Suite("Streaming replay")
struct StreamingReplay {

    @Test("Replay saved WAVs through the streaming path")
    func replay() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/freeflow-test-streaming-replay")
        else { return }

        guard let dir = samplesDir() else {
            Issue.record("samples dir not found under .scratch")
            return
        }
        let readFlag = { (path: String) -> String? in
            guard let s = try? String(contentsOfFile: path, encoding: .utf8)
            else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let only = readFlag("/tmp/freeflow-replay-only")
        let stepMS = Int(readFlag("/tmp/freeflow-replay-step-ms") ?? "") ?? 3000
        let stepBytes = max(1, stepMS * 32)  // 16 kHz mono 16-bit = 32 bytes/ms

        var wavs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))
            ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        if let only { wavs = wavs.filter { $0 == only } }
        guard !wavs.isEmpty else {
            Issue.record("no matching WAVs under \(dir.path)")
            return
        }

        let modelManager = LocalModelManager()
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
            modelDirectory: try LocalModelTestSupport.directory(),
            adapterDirectory: hasAdapter ? adapterDir : nil)
        let client = MLXPolishClient(engine: engine, timeoutSeconds: 30)

        let log = ReplayLog(path: "/tmp/freeflow-streaming-replay.log")
        log.log("=== streaming replay (\(wavs.count) files, adapter=\(hasAdapter), step=\(stepMS)ms) ===\n")

        for name in wavs {
            let wav = try Data(contentsOf: dir.appendingPathComponent(name))
            guard wav.count > 44 else { continue }
            let pcm = wav.subdata(in: WAVEncoder.headerSize..<wav.count)

            let provider = LocalStreamingProvider(
                sttEngine: nemotron, polishChatClient: client)
            let chunks = ChunkCollector()
            provider.setChunkHandler { text in chunks.append(text) }

            let tail = try await provider.replay(audio: pcm, stepBytes: stepBytes)

            // Reconstruct what the editor would contain: every committed
            // chunk injected live, then the final tail.
            var editor = ""
            var chunkIdx = 0
            log.log("[\(name)]")
            for chunk in chunks.all {
                chunkIdx += 1
                log.log("  chunk \(chunkIdx): \"\(visible(chunk))\"")
                Self.appendChunk(chunk, to: &editor)
            }
            if !tail.isEmpty {
                log.log("  tail: \"\(visible(tail))\"")
                Self.appendChunk(tail, to: &editor)
            }

            let editorText = editor.trimmingCharacters(in: .whitespaces)
            log.log("  --- raw STT: \(provider.lastRawTranscript)")
            log.log("  --- EDITOR (\(paragraphCount(editorText)) paragraphs):")
            log.log(indent(editorText))
            log.log("")
        }

        await nemotron.unload()
        await engine.unload()
    }

    // MARK: - Editor reconstruction (mirrors AppTextInjector spacing)

    /// Append `raw` chunk to `editor` the way DictationPipeline's chunk
    /// handler + AppTextInjector.inject would: trim only horizontal
    /// whitespace, append a trailing space unless the chunk ends with a
    /// break, and add a leading space unless the chunk starts with a break
    /// or punctuation or the previous character already suppresses it.
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

/// Make newlines visible in the log so break placement is unambiguous.
private func visible(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: "\\n")
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
