import Foundation
import Testing

@testable import UnrambleKit

// The cloud realtime path validates a same-connection polish against the raw
// transcript before injecting it, falling back to the transcript when a guard
// fires. These tests pin the composed floor — hallucination, truncation,
// content loss, fabrication, and number substitution — with the number guard
// added so a corrupted amount cannot reach the editor while a faithful
// digitization still passes.
@Suite("Realtime polish validation")
struct RealtimePolishValidationTests {

    private func validate(_ polished: String, raw: String) -> String {
        OpenAIRealtimeSessionDriver.validatedRealtimePolish(
            polished, rawTranscript: raw)
    }

    // MARK: - Number substitution (the new guard)

    @Test("a substituted number falls back to the transcript")
    func numberSubstitutionFallsBack() {
        // Only the number guard catches this: the content words are faithful,
        // but the amount 45,000 became 54,000.
        let raw = "the budget is forty five thousand dollars"
        let polished = "The budget is $54,000."
        #expect(validate(polished, raw: raw) == raw)
    }

    @Test("a faithful number digitization passes")
    func faithfulDigitizationPasses() {
        let raw = "the budget is forty five thousand dollars"
        let polished = "The budget is $45,000."
        #expect(validate(polished, raw: raw) == polished)
    }

    @Test("digitizing a small count passes")
    func smallCountDigitizationPasses() {
        let raw = "we shipped five features this week"
        let polished = "We shipped 5 features this week."
        #expect(validate(polished, raw: raw) == polished)
    }

    // MARK: - Clean polish passes

    @Test("a clean polish with no numbers passes")
    func cleanPolishPasses() {
        let raw = "so basically we should ship the thing tomorrow"
        let polished = "Basically, we should ship the thing tomorrow."
        #expect(validate(polished, raw: raw) == polished)
    }

    // MARK: - Existing floor still holds

    @Test("a dropped clause still falls back to the transcript")
    func droppedClauseFallsBack() {
        let raw = "we need to review the security report and update the "
            + "dependencies and then schedule the deploy for friday"
        let polished = "We need to review the security report."
        #expect(validate(polished, raw: raw) == raw)
    }

    @Test("an empty polish falls back to the transcript")
    func emptyPolishFallsBack() {
        let raw = "just a quick note about the meeting"
        #expect(validate("   ", raw: raw) == raw)
    }

    @Test("an empty transcript returns the polish unchanged")
    func emptyTranscriptReturnsPolish() {
        #expect(validate("Anything.", raw: "") == "Anything.")
    }
}
