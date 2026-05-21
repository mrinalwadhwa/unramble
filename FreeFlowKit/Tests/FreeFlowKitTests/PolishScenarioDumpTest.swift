import Testing
import Foundation
@testable import FreeFlowKit

// Dump actual LLM outputs for all scenarios so we can see real quality.
// Run with: FREEFLOW_TEST_DUMP=1 FREEFLOW_TEST_OPENAI=1 FREEFLOW_TEST_LOCAL_LLM=1 swift test --filter "PolishScenarioDump"
//
// Test data lives in PolishScenarioData.swift (allScenarios).
// Uses multi-accepted matching from the shared PolishScenario struct.

private func runPipeline(
    input: String,
    context: AppContext,
    systemPrompt: String,
    client: any PolishChatClient
) async -> String {
    let substituted = PolishPipeline.substituteDictatedPunctuation(input)
    let stripped = PolishPipeline.stripKeepTags(substituted)
    do {
        let raw = try await client.complete(
            model: PolishPipeline.polishModel,
            systemPrompt: systemPrompt,
            userPrompt: PolishPipeline.buildUserPrompt(
                substituted, context: context))
        if raw.isEmpty { return "[empty] \(PolishPipeline.normalizeFormatting(stripped))" }
        return PolishPipeline.normalizeFormatting(
            PolishPipeline.stripKeepTags(raw))
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

        print("\n=== CLOUD LLM (systemPromptEnglish + gpt-4.1-nano) ===\n")
        var matches = 0
        for s in allScenarios {
            let result = await runPipeline(
                input: s.input,
                context: s.context,
                systemPrompt: PolishPipeline.systemPromptEnglish,
                client: client)
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
        }
        print("Score: \(matches)/\(allScenarios.count)\n")
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
