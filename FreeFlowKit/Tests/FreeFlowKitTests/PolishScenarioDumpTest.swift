import Testing
import Foundation
@testable import FreeFlowKit

// Dump actual LLM outputs for all scenarios so we can see real quality.
// Run with: FREEFLOW_TEST_DUMP=1 FREEFLOW_TEST_OPENAI=1 swift test --filter "PolishScenarioDump"
//
// Test data lives in PolishScenarioData.swift (allScenarios).
// Uses multi-accepted matching from the shared PolishScenario struct.

private func runCloudPipeline(
    scenario: PolishScenario,
    client: any PolishChatClient
) async -> String {
    let casual = scenario.style == "casual"
    let substituted = PolishPipeline.substituteDictatedPunctuation(
        scenario.input, casual: casual,
        precedingText: scenario.precedingText)
    let stripped = PolishPipeline.stripKeepTags(
        substituted, casual: casual)

    let context = scenario.context
    let systemPrompt = PolishPipeline.buildCloudSystemPrompt(
        context: context, language: nil)
    let userPrompt = PolishPipeline.buildUserPrompt(
        substituted, context: context)

    do {
        let raw = try await client.complete(
            model: PolishPipeline.polishModel,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt)
        if raw.isEmpty {
            return "[empty] \(PolishPipeline.normalizeFormatting(stripped, casual: casual))"
        }
        let cleaned = PolishPipeline.guardAgainstEcho(
            polished: raw,
            precedingText: scenario.precedingText)
        let guarded: String
        if let fallback = PolishPipeline.guardAgainstTruncation(
            polished: cleaned, preprocessed: stripped) {
            guarded = fallback
        } else {
            guarded = cleaned
        }
        let untagged = PolishPipeline.stripKeepTags(guarded, casual: casual)
        let normalized = PolishPipeline.normalizeFormatting(
            untagged, casual: casual)
        let cased = PolishPipeline.matchInputCasing(
            normalized, preprocessedInput: substituted,
            casual: casual)
        let noPreceding = scenario.precedingText == nil
            || scenario.precedingText!.isEmpty
        return PolishPipeline.adjustFirstCharCasing(
            cased, preprocessed: stripped, casual: casual,
            noPreceding: noPreceding)
    } catch {
        return "[error] \(error)"
    }
}

@Suite(
    "Polish Scenario Dump -- Cloud",
    .disabled(
        if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_DUMP"] != "1"
            || ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI"] != "1"))
struct PolishScenarioDumpCloud {
    @Test("cloud LLM results for all scenarios")
    func dump() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            !apiKey.isEmpty
        else { return }
        let client = OpenAIChatClient(apiKey: apiKey)

        let scenarios = evalScenarios()
        print("\n=== CLOUD LLM (\(PolishPipeline.polishModel), \(scenarios.count) scenarios) ===\n")
        var matches = 0
        var categoryStats: [String: (match: Int, total: Int)] = [:]
        for s in scenarios {
            let result = await runCloudPipeline(
                scenario: s, client: client)
            let isMatch = s.matches(result)
            if isMatch { matches += 1 }

            var stats = categoryStats[s.category, default: (0, 0)]
            stats.total += 1
            if isMatch { stats.match += 1 }
            categoryStats[s.category] = stats

            let tag = isMatch ? "MATCH" : "DIFF"
            print("[\(s.category)] \(tag)")
            print("  Input:    \(s.input)")
            print("  Output:   \(result)")
            if !isMatch {
                print("  Expected: \(s.accepted[0])")
            }
            print()
        }
        print("Score: \(matches)/\(scenarios.count)")
        print("\n--- Category breakdown ---")
        for cat in categoryStats.keys.sorted() {
            let s = categoryStats[cat]!
            print("  \(cat): \(s.match)/\(s.total)")
        }
        print()
    }
}

// MLX model dump tests are in PolishScenarioDumpMLXTest.swift.
// They must be run via xcodebuild (Metal shaders required).
