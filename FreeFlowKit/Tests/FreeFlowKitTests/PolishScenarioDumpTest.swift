import Testing
import Foundation
@testable import FreeFlowKit

// Dump actual LLM outputs for all scenarios so we can see real quality.
// Run with: FREEFLOW_TEST_DUMP=1 FREEFLOW_TEST_OPENAI=1 FREEFLOW_TEST_LOCAL_LLM=1 swift test --filter "PolishScenarioDump"
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
        let untagged = PolishPipeline.stripKeepTags(raw, casual: casual)
        let normalized = PolishPipeline.normalizeFormatting(
            untagged, casual: casual)
        return PolishPipeline.matchInputCasing(
            normalized, preprocessedInput: substituted,
            casual: casual)
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

        print("\n=== CLOUD LLM (buildCloudSystemPrompt + \(PolishPipeline.polishModel)) ===\n")
        var matches = 0
        var categoryStats: [String: (match: Int, total: Int)] = [:]
        for s in allScenarios {
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
        print("Score: \(matches)/\(allScenarios.count)")
        print("\n--- Category breakdown ---")
        for cat in categoryStats.keys.sorted() {
            let s = categoryStats[cat]!
            print("  \(cat): \(s.match)/\(s.total)")
        }
        print()
    }
}

#if canImport(FoundationModels)
@Suite(
    "Polish Scenario Dump -- Local",
    .disabled(
        if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_DUMP"] != "1"
            || ProcessInfo.processInfo.environment["FREEFLOW_TEST_LOCAL_LLM"] != "1"))
struct PolishScenarioDumpLocal {
    @Test("local LLM results for all scenarios")
    func dump() async throws {
        guard #available(macOS 26, *) else { return }
        let client = FoundationModelChatClient()

        print("\n=== LOCAL LLM (systemPromptLocal + Apple Foundation Models) ===\n")
        var matches = 0
        for s in allScenarios {
            let substituted = PolishPipeline.substituteDictatedPunctuation(s.input)
            let stripped = PolishPipeline.stripKeepTags(substituted)
            do {
                // Send tag-stripped text to local model (matches
                // real provider behavior — local models don't
                // understand <keep> tags).
                let raw = try await client.complete(
                    model: "",
                    systemPrompt: PolishPipeline.systemPromptLocal,
                    userPrompt: stripped)
                let result = PolishPipeline.normalizeFormatting(
                    raw.isEmpty ? stripped : raw)
                let isMatch = s.matches(result)
                if isMatch { matches += 1 }
                let tag = isMatch ? "MATCH" : "DIFF"
                print("[\(s.category)] \(tag)")
                print("  Input:    \(s.input)")
                print("  Output:   \(result)")
                if !isMatch {
                    print("  Expected: \(s.accepted[0])")
                }
                print()
            } catch {
                print("[\(s.category)] ERROR: \(error)")
                print("  Input: \(s.input)\n")
            }
        }
        print("Score: \(matches)/\(allScenarios.count)\n")
    }
}
#endif

// MLX model dump tests are in PolishScenarioDumpMLXTest.swift.
// They must be run via xcodebuild (Metal shaders required).
