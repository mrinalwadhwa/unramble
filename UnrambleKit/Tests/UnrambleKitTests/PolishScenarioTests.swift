import Foundation
import Testing

@testable import UnrambleKit

// Deterministic scenario coverage derived from real-world dictation pain points.
// Model-backed local evaluations live in the MLX-specific suites. Cloud polish
// is exercised through the production Realtime audio path, not Chat Completions.

@Suite("Polish Scenarios -- Stage 1 regex")
struct PolishScenarioRegexTests {

    @Test("dictated punctuation commands are substituted")
    func punctuationSubstitution() {
        let punctuationCases = allScenarios.filter { $0.category == "punctuation" }
        for scenario in punctuationCases {
            let result = PolishPipeline.substituteDictatedPunctuation(scenario.input)
            // "period" and "full stop" remain model-owned commands.
            #expect(
                !result.lowercased().contains(" comma"),
                "comma command should be replaced in: \(scenario.input)")
            #expect(
                !result.lowercased().contains("question mark"),
                "question mark should be replaced in: \(scenario.input)")
            #expect(
                !result.lowercased().contains("exclamation point"),
                "exclamation should be replaced in: \(scenario.input)")
        }
    }

    @Test("dot dot dot becomes ellipsis")
    func ellipsis() {
        let input = "wait dot dot dot I need to think about this"
        let result = PolishPipeline.substituteDictatedPunctuation(input)
        let stripped = PolishPipeline.stripKeepTags(result)
        #expect(stripped.contains("\u{2026}"))
    }
}

@Suite("Polish Scenarios -- deterministic passthrough")
struct PolishScenarioDeterministicTests {

    @Test("wording-preservation inputs with punctuation pass through unchanged")
    func preservePassthrough() {
        let preserveCases = allScenarios.filter {
            $0.category == "preserve" && $0.input.hasSuffix(".")
        }
        for scenario in preserveCases {
            let substituted = PolishPipeline.substituteDictatedPunctuation(
                scenario.input)
            let stripped = PolishPipeline.stripKeepTags(substituted)
            let normalized = PolishPipeline.normalizeFormatting(stripped)
            #expect(
                normalized == scenario.accepted[0],
                "Preserve case should pass through unchanged: \(scenario.input)")
        }
    }
}
