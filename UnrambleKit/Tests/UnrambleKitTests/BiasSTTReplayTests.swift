import Foundation
import Testing

@testable import UnrambleKit

// STT-only replay to measure contextual-biasing efficacy and safety. Runs the
// REAL Nemotron recognizer over a directory of WAVs and logs one raw transcript
// per file — no polish, since biasing only affects the recognizer. Run once
// with the bias flag absent (baseline) and once present (biased), then diff.
//
//   touch /tmp/unramble-test-bias-stt
//   echo <wavdir> >/tmp/unramble-replay-dir
//   # bias run only:
//   cp .scratch/stt-bias-baseline.txt /tmp/unramble-stt-bias
//   echo 2.0 >/tmp/unramble-stt-bias-weight
//   echo /tmp/unramble-bias-on.log >/tmp/unramble-bias-stt-out
//   cd UnrambleKit && xcodebuild test -scheme UnrambleKit \
//        -destination 'platform=macOS' \
//        -only-testing:UnrambleKitTests/BiasSTTReplay \
//        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) UNRAMBLE_MLX_TESTS'
//
// Output: one JSON line per WAV, [[BIASSTT]] {"wav":...,"stt":...}, to the path
// in /tmp/unramble-bias-stt-out (default /tmp/unramble-bias-stt.log).

#if UNRAMBLE_MLX_TESTS

@Suite("Bias STT replay")
struct BiasSTTReplay {

    @Test("Replay WAVs through STT with whatever bias flag is set")
    func replay() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/unramble-test-bias-stt")
        else { return }

        let readFlag = { (path: String) -> String? in
            guard let s = try? String(contentsOfFile: path, encoding: .utf8)
            else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        guard let dirPath = readFlag("/tmp/unramble-replay-dir") else {
            Issue.record(
                "set /tmp/unramble-replay-dir to a directory of sample WAVs")
            return
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let only = readFlag("/tmp/unramble-replay-only")
        let outPath = readFlag("/tmp/unramble-bias-stt-out")
            ?? "/tmp/unramble-bias-stt.log"

        var wavs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))
            ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        if let only { wavs = wavs.filter { $0 == only } }
        guard !wavs.isEmpty else {
            Issue.record("no matching WAVs under \(dir.path)")
            return
        }

        guard let modelsDir = biasFindUpwards("UnrambleApp/Resources/models")
        else {
            Issue.record("model pack not found under UnrambleApp/Resources")
            return
        }
        let modelManager = LocalModelManager(modelsDirectory: modelsDir)
        let nemotron = NemotronEngine(modelManager: modelManager)
        try await nemotron.load()

        // Resume: skip WAVs already recorded so a crash-and-rerun makes progress.
        let existing = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        let done = Set(existing.split(whereSeparator: \.isNewline).compactMap {
            line -> String? in
            guard let r = line.range(of: "\"wav\":\"") else { return nil }
            let rest = line[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        })
        if !FileManager.default.fileExists(atPath: outPath) {
            FileManager.default.createFile(atPath: outPath, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: outPath)
        handle?.seekToEndOfFile()
        defer { try? handle?.close() }

        var processed = 0
        for name in wavs {
            if done.contains(name) { continue }
            let wav = try Data(contentsOf: dir.appendingPathComponent(name))
            guard wav.count > 44 else { continue }
            let seconds = Double(wav.count - 44) / 2.0 / 16_000.0
            // Reset the recognizer on a fresh model before a long recording and
            // periodically. Whole-file feeding aside, CoreML/Metal state
            // accumulates across WAVs and a long file (~70 s) then trips a shape
            // fault; reloading clears it. Reload re-reads the bias flag, so the
            // bias config is preserved.
            if processed > 0 && (seconds > 25 || processed % 20 == 0) {
                await nemotron.unload()
                try await nemotron.load()
            }
            // Feed in ~3 s pieces, matching the live streaming cadence.
            let pieces = max(1, Int(seconds / 3.0))
            let stt = try autoreleasepool {
                try LocalRecognitionFixtureSupport.recognize(
                    wavData: wav, using: nemotron, pieces: pieces)
            }
            let line = "[[BIASSTT]] {\"wav\":\"\(biasJSONEscape(name))\","
                + "\"stt\":\"\(biasJSONEscape(stt))\"}\n"
            handle?.write(Data(line.utf8))
            processed += 1
        }
    }
}

private func biasFindUpwards(_ relative: String) -> URL? {
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

private func biasJSONEscape(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.unicodeScalars.append(ch)
        }
    }
    return out
}

#endif
