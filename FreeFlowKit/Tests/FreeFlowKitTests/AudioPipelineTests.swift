import CryptoKit
import XCTest

@testable import FreeFlowKit

/// End-to-end pipeline tests using pre-generated TTS audio.
///
/// Each test feeds a WAV file through the real OpenAI streaming
/// provider (transcription + polish) and compares the output against
/// the accepted results from PolishScenarioData.
///
/// Gated by FREEFLOW_TEST_OPENAI=1 and requires audio fixtures in
/// Tests/FreeFlowKitTests/Fixtures/audio/.
///
/// These tests hit the real OpenAI API and cost real money. They are
/// slow (~2s per scenario) and should not run in CI without explicit
/// opt-in.
final class AudioPipelineTests: XCTestCase {

    private var apiKey: String?

    override func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI"] == "1" else {
            return
        }
        apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    /// Run all scenarios that have audio files.
    func testAllScenariosWithAudio() async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw XCTSkip("FREEFLOW_TEST_OPENAI and OPENAI_API_KEY required")
        }

        let audioDir = findAudioDir()
        guard let audioDir else {
            throw XCTSkip("Audio fixtures not found at Tests/FreeFlowKitTests/Fixtures/audio/")
        }

        // Build providers.
        let polishClient = OpenAIChatClient(apiKey: apiKey)
        let streamingProvider = OpenAIRealtimeProvider(
            apiKey: apiKey,
            polishChatClient: polishClient)
        let batchProvider = OpenAIDictationProvider(
            apiKey: apiKey,
            polishChatClient: polishClient)

        var passed = 0
        var mismatched = 0
        var broken = 0
        var skipped = 0
        var mismatches: [(PolishScenario, String)] = []
        var brokenScenarios: [PolishScenario] = []

        for scenario in allScenarios {
            let filename = scenarioFilename(scenario)
            let wavPath = audioDir.appendingPathComponent("\(filename).wav")

            guard FileManager.default.fileExists(atPath: wavPath.path) else {
                skipped += 1
                continue
            }

            // Load WAV and extract PCM.
            let wavData = try Data(contentsOf: wavPath)
            guard wavData.count > 44 else {
                skipped += 1
                continue
            }

            // Build a mock audio provider that emits the WAV's PCM.
            let audio = MockAudioProvider()
            audio.enablePCMStream = true
            audio.stubbedPeakRMS = 0.05  // above silence threshold

            // Set up a buffer with the WAV data for batch fallback.
            let duration = Double(wavData.count - 44) / (2 * 16000)  // 16kHz 16-bit mono
            audio.stubbedBuffer = AudioBuffer(
                data: wavData,
                duration: duration,
                sampleRate: 16000,
                channels: 1
            )

            // Capture injected text.
            let injector = MockTextInjector()
            let coordinator = RecordingCoordinator()

            let pipeline = DictationPipeline(
                audioProvider: audio,
                contextProvider: MockAppContextProvider(),
                dictationProvider: batchProvider,
                textInjector: injector,
                coordinator: coordinator,
                streamingProvider: streamingProvider
            )

            // Activate and feed audio.
            await pipeline.activate()

            // Feed PCM chunks (skip WAV header, 4096-byte chunks).
            let pcm = wavData.subdata(in: 44..<wavData.count)
            let chunkSize = 4096
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + chunkSize, pcm.count)
                audio.emitPCMChunk(pcm.subdata(in: offset..<end))
                offset = end
                // Small delay to simulate real-time streaming.
                try? await Task.sleep(nanoseconds: 10_000_000)
            }

            await pipeline.complete()

            // Check result.
            let output = injector.lastInjectedText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let esc = { (s: String) in s.replacingOccurrences(of: "\n", with: "\\n") }

            if output.isEmpty {
                broken += 1
                brokenScenarios.append(scenario)
                print("BROKEN [\(scenario.category)] \"\(scenario.input)\"")
                print("  Pipeline returned empty output")
                print()
            } else if scenario.matches(output) {
                passed += 1
                print("PASS [\(scenario.category)]")
                print("  Input:    \"\(scenario.input)\"")
                print("  Got:      \"\(esc(output))\"")
                print("  Expected: \"\(esc(scenario.accepted[0]))\"")
                print()
            } else {
                mismatched += 1
                mismatches.append((scenario, output))
                print("MISMATCH [\(scenario.category)] \"\(scenario.input)\"")
                print("  Got:      \"\(esc(output))\"")
                print("  Expected: \"\(esc(scenario.accepted[0]))\"")
                print()
            }

            // Reset for next scenario.
            await pipeline.cancel()

            // Brief pause between API calls.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        print("\n═══ Results: \(passed) passed, \(mismatched) mismatched, \(broken) broken, \(skipped) skipped ═══\n")

        if broken > 0 {
            let summary = brokenScenarios.map { s in
                "[\(s.category)] \"\(s.input)\""
            }.joined(separator: "\n")
            XCTFail("\(broken) scenario(s) returned empty output:\n\(summary)")
        }
    }

    // MARK: - Helpers

    /// Find the audio fixtures directory next to the test source.
    private func findAudioDir() -> URL? {
        let testFile = URL(fileURLWithPath: #file)
        let testDir = testFile.deletingLastPathComponent()
        let candidate = testDir.appendingPathComponent("Fixtures/audio")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// Generate a stable filename for a scenario (must match generate-audio.sh).
    private func scenarioFilename(_ scenario: PolishScenario) -> String {
        let data = scenario.input.data(using: .utf8) ?? Data()
        let digest = Insecure.MD5.hash(data: data)
        let h = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(scenario.category)-\(h)"
    }
}
