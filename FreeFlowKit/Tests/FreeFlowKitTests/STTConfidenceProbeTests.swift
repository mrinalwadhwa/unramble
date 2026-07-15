import Foundation
import Testing

@testable import FreeFlowKit

// Transcribe saved WAVs through the real Nemotron recognizer with per-token
// confidence capture on, to learn whether recognition errors are low-confidence
// (and whether the correct word is the runner-up). Diagnostic for the STT
// quality work; not part of any normal lane.
//
//   touch /tmp/freeflow-stt-probe
//   echo <wavdir> > /tmp/freeflow-replay-dir
//   cd FreeFlowKit && xcodebuild test -scheme FreeFlowKit \
//        -destination 'platform=macOS' -skipPackagePluginValidation \
//        -only-testing:FreeFlowKitTests/STTConfidenceProbe \
//        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FREEFLOW_MLX_TESTS'
//
// Output: /tmp/freeflow-stt-confidence.log — per-word confidence + runner-up.

#if FREEFLOW_MLX_TESTS

@Suite("STT confidence probe")
struct STTConfidenceProbe {

    @Test("Transcribe WAVs with per-word confidence")
    func probe() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/freeflow-stt-probe")
        else { return }

        let dirPath = (try? String(
            contentsOfFile: "/tmp/freeflow-replay-dir", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !dirPath.isEmpty else {
            Issue.record("set /tmp/freeflow-replay-dir to a WAV directory")
            return
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let wavs = ((try? FileManager.default.contentsOfDirectory(
            atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".wav") }.sorted()
        guard !wavs.isEmpty else {
            Issue.record("no WAVs under \(dir.path)")
            return
        }

        guard let modelsDir = Self.findUpwards(
            "FreeFlowApp/Resources/models")
        else {
            Issue.record("model pack not found under FreeFlowApp/Resources")
            return
        }
        let manager = LocalModelManager(modelsDirectory: modelsDir)
        let nemotron = NemotronEngine(modelManager: manager)
        try await nemotron.load()

        // Turn on the engine's confidence capture; start a fresh output log.
        FileManager.default.createFile(
            atPath: "/tmp/freeflow-stt-confidence", contents: nil)
        let logPath = "/tmp/freeflow-stt-confidence.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let append = { (line: String) in
            guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }

        for name in wavs {
            let wav = try Data(contentsOf: dir.appendingPathComponent(name))
            append("\n=== \(name) ===")
            let stt = try await nemotron.transcribe(audio: wav)
            append("STT: \(stt)")
        }

        await nemotron.unload()
        try? FileManager.default.removeItem(
            atPath: "/tmp/freeflow-stt-confidence")
    }

    private static func findUpwards(_ relative: String) -> URL? {
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

#endif
