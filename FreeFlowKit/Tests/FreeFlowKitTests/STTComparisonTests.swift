import CryptoKit
import XCTest

@testable import FreeFlowKit

/// Compare STT engines on pre-generated TTS audio files.
///
/// Feed each WAV through Parakeet and (on macOS 26+) Apple
/// SFSpeechRecognizer, printing raw transcriptions for comparison.
/// No polish — this isolates STT accuracy.
///
/// Enable: touch /tmp/freeflow-test-stt-compare
/// Requires: audio in .scratch/e2e/audio/ and Parakeet model
/// in ~/Library/Application Support/freeflow/models/.
final class STTComparisonTests: XCTestCase {

    private var audioDir: URL?

    override func setUp() {
        super.setUp()
        guard FileManager.default.fileExists(
            atPath: "/tmp/freeflow-test-stt-compare") else { return }
        audioDir = findAudioDir()
    }

    func testCompareSTTEngines() async throws {
        guard let audioDir else {
            throw XCTSkip(
                "Enable: touch /tmp/freeflow-test-stt-compare")
        }

        // Set up Parakeet.
        let modelManager = LocalModelManager()
        guard modelManager.isDownloaded("parakeet-tdt-0.6b-v3") else {
            throw XCTSkip("Parakeet model not downloaded")
        }
        let parakeet = ParakeetEngine(modelManager: modelManager)
        try await parakeet.load()

        print("\n═══ STT Comparison ═══\n")

        var parakeetMatches = 0
        var appleMatches = 0
        var count = 0

        for scenario in allScenarios {
            let filename = scenarioFilename(scenario)
            let wavPath = audioDir.appendingPathComponent(
                "\(filename).wav")

            guard FileManager.default.fileExists(
                atPath: wavPath.path) else { continue }

            let wavData = try Data(contentsOf: wavPath)
            guard wavData.count > 44 else { continue }

            count += 1

            // Parakeet
            let pStart = CFAbsoluteTimeGetCurrent()
            let pResult = try await parakeet.transcribe(audio: wavData)
            let pTime = CFAbsoluteTimeGetCurrent() - pStart
            let pNorm = pResult.lowercased().trimmingCharacters(
                in: .whitespacesAndNewlines)
            let expected = scenario.input.lowercased()
            let pMatch = pNorm == expected
            if pMatch { parakeetMatches += 1 }

            // Apple SFSpeechRecognizer (macOS 26+)
            var aResult = ""
            var aTime = 0.0
            var aMatch = false
            if #available(macOS 26, *) {
                let provider = SpeechAnalyzerDictationProvider(
                    polishChatClient: nil)
                let aStart = CFAbsoluteTimeGetCurrent()
                // dictate with nil polisher returns raw transcript
                aResult = try await provider.dictate(
                    audio: wavData, context: .empty)
                aTime = CFAbsoluteTimeGetCurrent() - aStart
                let aNorm = aResult.lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                aMatch = aNorm == expected
                if aMatch { appleMatches += 1 }
            }

            let pTag = pMatch ? "✓" : " "
            let aTag = aMatch ? "✓" : " "

            print("[\(scenario.category)]")
            print("  Expected: \(scenario.input)")
            print("  Parakeet: \(pTag) \(pResult)")
            print(String(format: "            (%.2fs)", pTime))
            if #available(macOS 26, *) {
                print("  Apple:    \(aTag) \(aResult)")
                print(String(format: "            (%.2fs)", aTime))
            }
            print()
        }

        print("═══ Results: \(count) files ═══")
        print("  Parakeet exact match: \(parakeetMatches)/\(count)")
        print("  Apple exact match:    \(appleMatches)/\(count)")
        print()

        await parakeet.unload()
    }

    // MARK: - Helpers

    private func findAudioDir() -> URL? {
        var dir = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(
                ".scratch/e2e/audio")
            if FileManager.default.fileExists(
                atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func scenarioFilename(
        _ scenario: PolishScenario
    ) -> String {
        let data = scenario.input.data(using: .utf8) ?? Data()
        let digest = Insecure.MD5.hash(data: data)
        let h = digest.prefix(4).map {
            String(format: "%02x", $0)
        }.joined()
        return "\(scenario.category)-\(h)"
    }
}
