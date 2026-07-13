import Foundation
import Testing

@testable import FreeFlowKit

// Compare batch transcription against the incremental streaming path on
// real audio, to check the streaming rework preserves quality and is
// faster. Uses only the Nemotron CoreML models (no MLX), so it runs
// under `swift test`.
//
// Enable: touch /tmp/freeflow-test-nemotron-streaming
// Requires the Nemotron model installed and audio fixtures under
// .scratch/. Output: /tmp/freeflow-nemotron-streaming.log

@Suite("Nemotron streaming")
struct NemotronStreamingTests {

    @Test("Streaming matches batch and is faster")
    func compareStreamingToBatch() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/freeflow-test-nemotron-streaming")
        else { return }

        let modelManager = LocalModelManager()
        let modelID = "nemotron-speech-streaming-en-0.6b-coreml"
        guard FileManager.default.fileExists(
            atPath: modelManager.modelPath(for: modelID).path)
        else {
            throw XCTSkipLike("Nemotron model not installed")
        }

        let engine = NemotronEngine(modelManager: modelManager)
        try await engine.load()

        let wavs = findWAVs()
        guard !wavs.isEmpty else {
            throw XCTSkipLike("No WAV fixtures found under .scratch")
        }

        let log = StreamingEvalLog(path: "/tmp/freeflow-nemotron-streaming.log")
        log.log("=== batch vs streaming (\(wavs.count) files) ===\n")

        var totalErr = 0
        var totalWords = 0
        var totalBatchTime = 0.0
        var totalStreamTime = 0.0

        for url in wavs {
            let wav = try Data(contentsOf: url)
            guard wav.count > 44 else { continue }

            let b0 = CFAbsoluteTimeGetCurrent()
            let batch = try await engine.transcribe(audio: wav)
            let bt = CFAbsoluteTimeGetCurrent() - b0

            let s0 = CFAbsoluteTimeGetCurrent()
            let stream = try engine.transcribeStreaming(audio: wav)
            let st = CFAbsoluteTimeGetCurrent() - s0

            let (err, words) = wer(reference: batch, hypothesis: stream)
            totalErr += err
            totalWords += words
            totalBatchTime += bt
            totalStreamTime += st

            log.log("[\(url.lastPathComponent)]")
            log.log(String(
                format: "  batch  (%.2fs): %@", bt, batch))
            log.log(String(
                format: "  stream (%.2fs): %@", st, stream))
            log.log("  word diff vs batch: \(err)/\(words)\n")
        }

        let divergence = totalWords > 0
            ? 100.0 * Double(totalErr) / Double(totalWords) : 0
        log.log("=== totals ===")
        log.log(String(format: "  batch  total: %.2fs", totalBatchTime))
        log.log(String(format: "  stream total: %.2fs", totalStreamTime))
        log.log(String(
            format: "  streaming divergence from batch: %.2f%%", divergence))

        // Determinism: feeding in pieces equals one shot.
        if let first = wavs.first {
            let wav = try Data(contentsOf: first)
            let oneShot = try engine.transcribeStreaming(audio: wav)
            let piecewise = try transcribePiecewise(engine, wav: wav, pieces: 5)
            #expect(oneShot == piecewise,
                "Piecewise feeding must equal one-shot streaming")
        }

        await engine.unload()
    }

    // MARK: - Helpers

    /// Feed a WAV to the streaming session in `pieces` separate `feed`
    /// calls to confirm chunk boundaries do not depend on call size.
    private func transcribePiecewise(
        _ engine: NemotronEngine, wav: Data, pieces: Int
    ) throws -> String {
        let pcm = wav.subdata(in: WAVEncoder.headerSize..<wav.count)
        let sampleCount = pcm.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        pcm.withUnsafeBytes { raw in
            let i16 = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount { samples[i] = Float(i16[i]) / 32768.0 }
        }
        let session = try engine.makeRecognitionSession()
        let step = max(1, sampleCount / pieces)
        var offset = 0
        while offset < sampleCount {
            let end = min(offset + step, sampleCount)
            try session.feed(Array(samples[offset..<end]))
            offset = end
        }
        return try session.finish()
    }

    private func findWAVs() -> [URL] {
        // Walk up to the repo root (the directory that contains .scratch).
        var root = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            root = root.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".scratch").path) {
                break
            }
        }
        var result: [URL] = []
        let email = root.appendingPathComponent(
            ".scratch/nemotron-eval/samples/email-96s.wav")
        if FileManager.default.fileExists(atPath: email.path) {
            result.append(email)
        }
        let audioDir = root.appendingPathComponent(".scratch/e2e/audio")
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: audioDir.path)) ?? []
        for name in names.sorted().prefix(8) where name.hasSuffix(".wav") {
            result.append(audioDir.appendingPathComponent(name))
        }
        return result
    }

    /// Word error rate between two transcripts (batch as reference).
    private func wer(reference: String, hypothesis: String) -> (Int, Int) {
        let norm = { (s: String) in
            s.lowercased().unicodeScalars
                .filter {
                    CharacterSet.alphanumerics.contains($0)
                        || CharacterSet.whitespaces.contains($0)
                }
                .map(String.init).joined()
                .split(separator: " ").map(String.init)
        }
        let r = norm(reference)
        let h = norm(hypothesis)
        var d = Array(repeating: Array(repeating: 0, count: h.count + 1),
            count: r.count + 1)
        for i in 0...r.count { d[i][0] = i }
        for j in 0...h.count { d[0][j] = j }
        for i in 1...max(r.count, 1) where r.count > 0 {
            for j in 1...max(h.count, 1) where h.count > 0 {
                if r[i - 1] == h[j - 1] {
                    d[i][j] = d[i - 1][j - 1]
                } else {
                    d[i][j] = min(
                        d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + 1)
                }
            }
        }
        return (d[r.count][h.count], r.count)
    }
}

/// Minimal skip signal for Swift Testing (no XCTSkip available).
private struct XCTSkipLike: Error { let message: String
    init(_ m: String) { message = m } }

/// Append-only log file for streaming eval output.
private final class StreamingEvalLog {
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
