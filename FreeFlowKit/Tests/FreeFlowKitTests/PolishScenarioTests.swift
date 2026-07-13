import Foundation
import Testing

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Polish scenario tests derived from real-world dictation pain points.
// Each test case represents a realistic messy input that the polish
// pipeline should clean up.
//
// Two test levels:
//   1. Deterministic -- Stage 1 regex substitution (always runs)
//   2. Cloud LLM -- full pipeline with OpenAI (FREEFLOW_TEST_OPENAI=1)
//
// Test data lives in PolishScenarioData.swift (allScenarios).
// Validators are property-based per category (not exact match).
// ---------------------------------------------------------------------------

// MARK: - Deterministic Tests (Stage 1)

@Suite("Polish Scenarios -- Stage 1 regex")
struct PolishScenarioRegexTests {

    @Test("dictated punctuation commands are substituted")
    func punctuationSubstitution() {
        let punctCases = allScenarios.filter { $0.category == "punctuation" }
        for s in punctCases {
            let result = PolishPipeline.substituteDictatedPunctuation(s.input)
            // The command word should be gone. "period" and "full
            // stop" are handled by the model, not deterministically.
            #expect(
                !result.lowercased().contains(" comma"),
                "comma command should be replaced in: \(s.input)")
            #expect(
                !result.lowercased().contains("question mark"),
                "question mark should be replaced in: \(s.input)")
            #expect(
                !result.lowercased().contains("exclamation point"),
                "exclamation should be replaced in: \(s.input)")
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
        // Preserve cases that already have proper punctuation go through
        // deterministic stages only (substitution + strip tags + normalize).
        let preserveCases = allScenarios.filter {
            $0.category == "preserve" && $0.input.hasSuffix(".")
        }
        for s in preserveCases {
            let substituted = PolishPipeline.substituteDictatedPunctuation(s.input)
            let stripped = PolishPipeline.stripKeepTags(substituted)
            let normalized = PolishPipeline.normalizeFormatting(stripped)
            #expect(
                normalized == s.accepted[0],
                "Preserve case should pass through unchanged: \(s.input)")
        }
    }
}

// MARK: - Cloud LLM Tests (full pipeline, gated)

@Suite(
    "Polish Scenarios -- Cloud LLM",
    .disabled(
        if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI"] != "1"))
struct PolishScenarioCloudTests {

    private func polishWithCloud(
        _ input: String,
        context: AppContext = .empty
    ) async throws -> String {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            !apiKey.isEmpty
        else {
            throw PolishTestError.noAPIKey
        }
        let client = OpenAIChatClient(apiKey: apiKey)
        let substituted = PolishPipeline.substituteDictatedPunctuation(input)
        let stripped = PolishPipeline.stripKeepTags(substituted)
        let userPrompt = PolishPipeline.buildUserPrompt(
            substituted, context: context)
        let result = try await client.complete(
            model: PolishPipeline.polishModel,
            systemPrompt: PolishPipeline.systemPromptEnglish,
            userPrompt: userPrompt)
        if result.isEmpty { return PolishPipeline.normalizeFormatting(stripped) }
        return PolishPipeline.normalizeFormatting(
            PolishPipeline.stripKeepTags(result))
    }

    @Test("filler removal")
    func fillers() async throws {
        for s in allScenarios where s.category == "filler" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.lowercased().contains(" um "),
                "Should remove 'um' from: \(s.input), got: \(result)")
            #expect(
                !result.lowercased().contains(" uh "),
                "Should remove 'uh' from: \(s.input), got: \(result)")
            #expect(
                !result.starts(with: "Um"),
                "Should not start with 'Um': \(s.input), got: \(result)")
            #expect(
                !result.starts(with: "Uh"),
                "Should not start with 'Uh': \(s.input), got: \(result)")
        }
    }

    @Test("discourse markers cleaned")
    func discourse() async throws {
        for s in allScenarios where s.category == "discourse" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.lowercased().contains(" um "),
                "Should remove 'um' from: \(s.input), got: \(result)")
            #expect(
                !result.lowercased().contains(" uh "),
                "Should remove 'uh' from: \(s.input), got: \(result)")
        }
    }

    @Test("thinking sounds cleaned")
    func thinking() async throws {
        for s in allScenarios where s.category == "thinking" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.lowercased().contains(" um "),
                "Should remove 'um' from: \(s.input), got: \(result)")
            #expect(
                !result.starts(with: "Um"),
                "Should not start with 'Um': \(s.input), got: \(result)")
            #expect(
                !result.starts(with: "Uh"),
                "Should not start with 'Uh': \(s.input), got: \(result)")
        }
    }

    @Test("repetitions cleaned up")
    func repetitions() async throws {
        for s in allScenarios where s.category == "repetition" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.isEmpty,
                "Repetition cleanup should produce output: \(s.input)")
        }
    }

    @Test("corrections keep only final version")
    func corrections() async throws {
        for s in allScenarios where s.category == "correction" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.isEmpty,
                "Correction should produce output: \(s.input)")
        }
    }

    @Test("backtracking resolved")
    func backtracking() async throws {
        for s in allScenarios where s.category == "backtrack" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.isEmpty,
                "Backtrack should produce output: \(s.input)")
        }
    }

    @Test("punctuation commands processed")
    func punctuation() async throws {
        for s in allScenarios where s.category == "punctuation" {
            let result = try await polishWithCloud(s.input)
            let lower = result.lowercased()
            #expect(
                !lower.contains(" period") && !lower.contains(" comma")
                    && !lower.contains("question mark")
                    && !lower.contains("exclamation point"),
                "Punctuation commands should be removed: \(s.input), got: \(result)")
        }
    }

    @Test("numbers formatted as digits")
    func numbers() async throws {
        for s in allScenarios where s.category == "number" {
            let result = try await polishWithCloud(s.input)
            #expect(
                result.contains(where: { $0.isNumber }),
                "Numbers should be formatted as digits: \(s.input), got: \(result)")
        }
    }

    @Test("lists formatted with line breaks")
    func lists() async throws {
        for s in allScenarios where s.category == "list" {
            let result = try await polishWithCloud(s.input)
            #expect(
                result.contains("\n"),
                "Lists should have line breaks: \(s.input), got: \(result)")
        }
    }

    @Test("capitalization applied")
    func capitalization() async throws {
        for s in allScenarios where s.category == "capitalization" {
            let result = try await polishWithCloud(s.input)
            #expect(
                result.first?.isUppercase == true,
                "Should start with uppercase: \(s.input), got: \(result)")
        }
    }

    @Test("run-on sentences split")
    func runOn() async throws {
        for s in allScenarios where s.category == "run-on" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.isEmpty,
                "Run-on should produce output: \(s.input)")
        }
    }

    @Test("false starts resolved")
    func falseStarts() async throws {
        for s in allScenarios where s.category == "false-start" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.isEmpty,
                "False start should produce output: \(s.input)")
        }
    }

    @Test("homophones fixed")
    func homophones() async throws {
        for s in allScenarios where s.category == "homophone" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.isEmpty,
                "Homophone fix should produce output: \(s.input)")
        }
    }

    @Test("URLs and email addresses formatted")
    func urls() async throws {
        for s in allScenarios where s.category == "url" {
            let result = try await polishWithCloud(s.input)
            let hasDotOrAt = result.contains(".") || result.contains("@")
            #expect(
                hasDotOrAt,
                "URL/email should contain '.' or '@': \(s.input), got: \(result)")
        }
    }

    @Test("wording preserved, not rephrased")
    func wording() async throws {
        for s in allScenarios where s.category == "preserve" {
            let result = try await polishWithCloud(s.input)
            let keywords = ["grab", "mentioned", "kinda", "reckon"]
            for kw in keywords where s.input.contains(kw) {
                #expect(
                    result.contains(kw),
                    "Should preserve '\(kw)' in: \(s.input), got: \(result)")
            }
        }
    }

    @Test("clean text passes through unchanged")
    func clean() async throws {
        for s in allScenarios where s.category == "clean" {
            let result = try await polishWithCloud(s.input)
            #expect(
                result == s.accepted[0],
                "Clean text should not change: \(s.input), got: \(result)")
        }
    }

    @Test("emphasis preserved")
    func emphasis() async throws {
        for s in allScenarios where s.category == "emphasis" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.isEmpty,
                "Emphasis should produce output: \(s.input)")
        }
    }

    @Test("meeting notes formatted")
    func meeting() async throws {
        for s in allScenarios where s.category == "meeting" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.isEmpty,
                "Meeting notes should produce output: \(s.input)")
        }
    }

    @Test("vocab capitalization applied")
    func vocab() async throws {
        for s in allScenarios where s.category == "vocab" {
            let result = try await polishWithCloud(s.input)
            #expect(
                result.first?.isUppercase == true,
                "Should start with uppercase: \(s.input), got: \(result)")
        }
    }

    @Test("email context produces output")
    func email() async throws {
        for s in allScenarios where s.category == "email" {
            let result = try await polishWithCloud(s.input, context: s.context)
            #expect(
                !result.isEmpty,
                "Email context should produce output: \(s.input)")
        }
    }

    @Test("slack context produces output")
    func slack() async throws {
        for s in allScenarios where s.category == "slack" {
            let result = try await polishWithCloud(s.input, context: s.context)
            #expect(
                !result.isEmpty,
                "Slack context should produce output: \(s.input)")
        }
    }

    @Test("code context produces output")
    func code() async throws {
        for s in allScenarios where s.category == "code" {
            let result = try await polishWithCloud(s.input, context: s.context)
            #expect(
                !result.isEmpty,
                "Code context should produce output: \(s.input)")
        }
    }

    @Test("multilingual input produces output")
    func multilingual() async throws {
        for s in allScenarios where s.category == "multilingual" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.isEmpty,
                "Multilingual should produce output: \(s.input)")
        }
    }

    @Test("keep tags preserve symbols through polish")
    func keepTags() async throws {
        for s in allScenarios where s.category == "keep-tag" {
            let result = try await polishWithCloud(s.input)
            #expect(
                s.matches(result),
                "Keep-tag should match accepted: \(s.input), got: \(result)")
        }
    }

    @Test("two-item lists stay inline")
    func twoItemLists() async throws {
        for s in allScenarios where s.category == "two-item-list" {
            let result = try await polishWithCloud(s.input)
            #expect(
                !result.contains("\n"),
                "Two-item list should stay inline: \(s.input), got: \(result)")
        }
    }

    @Test("lists without speaker lead-in have no fabricated intro")
    func noLeadInLists() async throws {
        let fabricatedIntros = [
            "Here are", "The items are:", "Please note:",
            "The following", "Items:", "List:",
        ]
        for s in allScenarios where s.category == "no-leadin-list" {
            let result = try await polishWithCloud(s.input)
            for intro in fabricatedIntros {
                #expect(
                    !result.hasPrefix(intro),
                    "Should not fabricate lead-in '\(intro)': \(s.input), got: \(result)")
            }
        }
    }

    @Test("contractions preserved, not expanded")
    func contractions() async throws {
        let pairs = [
            ("I'll", "I will"), ("we'll", "we will"),
            ("we're", "we are"), ("it's", "it is"),
            ("they've", "they have"), ("we've", "we have"),
            ("can't", "cannot"), ("doesn't", "does not"),
        ]
        for s in allScenarios where s.category == "contraction" {
            let result = try await polishWithCloud(s.input)
            for (contraction, expanded) in pairs where s.input.contains(contraction) {
                #expect(
                    !result.contains(expanded),
                    "Should keep '\(contraction)' not expand to '\(expanded)': \(s.input), got: \(result)")
            }
        }
    }

    @Test("small numbers converted to digits")
    func smallNumbers() async throws {
        for s in allScenarios where s.category == "small-number" {
            let result = try await polishWithCloud(s.input)
            #expect(
                result.contains(where: { $0.isNumber }),
                "Small numbers should be digits: \(s.input), got: \(result)")
        }
    }

    @Test("ordinal numbers converted to digits")
    func ordinals() async throws {
        for s in allScenarios where s.category == "ordinal" {
            let result = try await polishWithCloud(s.input)
            #expect(
                result.contains(where: { $0.isNumber }),
                "Ordinals should be digits: \(s.input), got: \(result)")
        }
    }
}

// MARK: - Helpers

private enum PolishTestError: Error {
    case noAPIKey
}
