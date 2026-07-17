import Foundation
import Testing

@testable import UnrambleKit

// Check that real audio produces the same transcript when an incremental
// recognition session receives all samples at once or across several feeds.
// Uses only the Nemotron CoreML models (no MLX), so it runs under `swift test`.
//
// Enable: touch /tmp/unramble-test-nemotron-streaming
// Requires the Nemotron model installed and audio fixtures under
// .scratch/. Output: /tmp/unramble-nemotron-streaming.log

@Suite("Nemotron streaming")
struct NemotronStreamingTests {

    @Test("Recognition is independent of feed boundaries")
    func compareOnePieceToPiecewiseRecognition() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/unramble-test-nemotron-streaming")
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

        let log = StreamingEvalLog(path: "/tmp/unramble-nemotron-streaming.log")
        log.log("=== one-piece vs piecewise (\(wavs.count) files) ===\n")

        for url in wavs {
            let wav = try Data(contentsOf: url)
            guard wav.count > 44 else { continue }

            let onePieceStart = CFAbsoluteTimeGetCurrent()
            let onePiece = try LocalRecognitionFixtureSupport.recognize(
                wavData: wav, using: engine)
            let onePieceTime = CFAbsoluteTimeGetCurrent() - onePieceStart

            let piecewiseStart = CFAbsoluteTimeGetCurrent()
            let piecewise = try LocalRecognitionFixtureSupport.recognize(
                wavData: wav, using: engine, pieces: 5)
            let piecewiseTime = CFAbsoluteTimeGetCurrent() - piecewiseStart

            log.log("[\(url.lastPathComponent)]")
            log.log(String(
                format: "  one-piece (%.2fs): %@", onePieceTime, onePiece))
            log.log(String(
                format: "  piecewise (%.2fs): %@", piecewiseTime, piecewise))
            log.log("")

            #expect(
                onePiece == piecewise,
                "Feed boundaries changed \(url.lastPathComponent) recognition")
        }

        await engine.unload()
    }

    // MARK: - Helpers

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
