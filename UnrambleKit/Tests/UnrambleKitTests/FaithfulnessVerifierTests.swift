import Foundation
import Testing

@testable import UnrambleKit

/// The deterministic half of faithfulness verification: diff the transcript
/// against the output, then pre-filter the spans that are decidably a
/// legitimate cleanup. A real drop or meaning change must survive as a
/// candidate; a filler, stutter, number/tense form, or command must not.
@Suite("FaithfulnessVerifier")
struct FaithfulnessVerifierTests {

    private func candidates(_ transcript: String, _ output: String) -> [FaithfulnessVerifier.Candidate] {
        FaithfulnessVerifier.candidates(transcript: transcript, output: output)
    }

    // MARK: candidates — real drops and meaning changes survive

    @Test("A short meaningful drop survives as an omission candidate")
    func meaningfulDropSurvives() {
        let out = candidates(
            "let's tackle one area at a time on the product side onboarding is live",
            "Let's tackle one area at a time. Onboarding is live.")
        #expect(out.count == 1)
        #expect(out.first?.kind == .omission)
        #expect(out.first?.span == "on the product side")
    }

    @Test("A meaning-changing substitution survives")
    func substitutionSurvives() {
        let out = candidates(
            "the new scenarios are working great",
            "The new scanners are working great.")
        #expect(out.count == 1)
        #expect(out.first?.kind == .substitution)
        #expect(out.first?.span == "scenarios")
        #expect(out.first?.replacement == "scanners")
    }

    @Test("A different-word swap survives even when short")
    func adverbSwapSurvives() {
        let out = candidates(
            "the notifications occasionally fire twice",
            "The notifications often fire twice.")
        #expect(out.map(\.kind) == [.substitution])
        #expect(out.first?.span == "occasionally")
        #expect(out.first?.replacement == "often")
    }

    // MARK: candidates — legitimate cleanups are filtered out

    @Test("A leading filler produces no candidate")
    func fillerFiltered() {
        #expect(candidates("okay a bunch of stuff from testing",
                           "A bunch of stuff from testing.").isEmpty)
    }

    @Test("A self-correction stutter produces no candidate")
    func selfCorrectionFiltered() {
        #expect(candidates("so i hoped uh i hopped on the call",
                           "So I hopped on the call.").isEmpty)
    }

    @Test("An offered alternative produces no candidate")
    func offeredAlternativeFiltered() {
        #expect(candidates("grab a couple of heat lamps or headlamps and a decent",
                           "Grab a couple of headlamps and a decent.").isEmpty)
    }

    @Test("A spoken-number-to-digits change produces no candidate")
    func numberFormFiltered() {
        #expect(candidates("let's meet at nine thirty tomorrow",
                           "Let's meet at 9:30 tomorrow.").isEmpty)
    }

    @Test("A tense fix produces no candidate")
    func tenseFormFiltered() {
        #expect(candidates("we finally ship the redesign",
                           "We finally shipped the redesign.").isEmpty)
    }

    @Test("A spoken punctuation command produces no candidate")
    func spokenPunctuationFiltered() {
        #expect(candidates("fix the bug exclamation point", "Fix the bug!").isEmpty)
    }

    @Test("A repeated word before the span is a stutter, so no candidate")
    func stutterBeforeSpanFiltered() {
        #expect(candidates("response time drop by about by almost half",
                           "Response time drop by about almost half.").isEmpty)
    }

    @Test("A stutter collapsed into a substitution produces no candidate")
    func disfluencyStutterSubstitutionFiltered() {
        #expect(candidates("everyone el everyone's already expecting it",
                           "Everyone else's already expecting it.").isEmpty)
    }

    @Test("A low-content lead-in inflected into the target produces no candidate")
    func disfluencyLeadInSubstitutionFiltered() {
        #expect(candidates("we are we finish the task", "We finished the task.").isEmpty)
    }

    @Test("Faithful passthrough produces no candidate")
    func passthroughClean() {
        #expect(candidates("the app crashes on older phones",
                           "The app crashes on older phones.").isEmpty)
    }

    // MARK: repair — restore a flagged span to what was spoken

    @Test("Repair restores a substituted word, keeping the rest of the polish")
    func repairSubstitution() {
        let output = "The new scanners are working great."
        let flagged = candidates("the new scenarios are working great", output)
        #expect(FaithfulnessVerifier.repair(output: output, flagged: flagged)
            == "The new scenarios are working great.")
    }

    @Test("Repair preserves sentence-start capitalization of the restored word")
    func repairSubstitutionCapitalization() {
        let output = "Scanners are the focus."
        let flagged = candidates("scenarios are the focus", output)
        #expect(FaithfulnessVerifier.repair(output: output, flagged: flagged)
            == "Scenarios are the focus.")
    }

    @Test("Repair re-inserts a dropped phrase onto the preceding clause")
    func repairOmissionReinserts() {
        let output = "Let's tackle one area at a time. Onboarding is live."
        let flagged = candidates(
            "let's tackle one area at a time on the product side onboarding is live", output)
        #expect(FaithfulnessVerifier.repair(output: output, flagged: flagged)
            == "Let's tackle one area at a time on the product side. Onboarding is live.")
    }

    @Test("Repair skips re-inserting content the polish only reordered")
    func repairOmissionSkipsPreserved() {
        let output = "A precurated palette here."
        let candidate = FaithfulnessVerifier.Candidate(
            kind: .omission, span: "precurated palette", replacement: "",
            context: "", restoration: "precurated palette", outputStart: 5, outputEnd: 5)
        #expect(FaithfulnessVerifier.repair(output: output, flagged: [candidate]) == output)
    }

    @Test("Repair with nothing flagged returns the output unchanged")
    func repairEmptyIsNoop() {
        let output = "The app crashes on older phones."
        #expect(FaithfulnessVerifier.repair(output: output, flagged: []) == output)
    }

    // MARK: normalizeTokens

    @Test("Tokenization lowercases, keeps apostrophes, and splits on symbols")
    func tokenization() {
        #expect(FaithfulnessVerifier.normalizeTokens("Hello, world! It's 9:30.")
            == ["hello", "world", "it's", "9", "30"])
    }

    // MARK: isCommandSpan

    @Test("Break commands are recognized, content words are not")
    func commandSpan() {
        #expect(FaithfulnessVerifier.isCommandSpan(["new", "paragraph"]))
        #expect(FaithfulnessVerifier.isCommandSpan(["comma"]))
        #expect(FaithfulnessVerifier.isCommandSpan(["exclamation", "point"]))
        // Fillers do not disqualify a command span.
        #expect(FaithfulnessVerifier.isCommandSpan(["new", "paragraph", "um"]))
        #expect(!FaithfulnessVerifier.isCommandSpan(["product"]))
        #expect(!FaithfulnessVerifier.isCommandSpan(["um"]))
    }

    // MARK: isNoiseSpan

    @Test("A filler-only span is noise")
    func noiseFillerOnly() {
        #expect(FaithfulnessVerifier.isNoiseSpan(["um"], transcript: ["um", "they", "should"], end: 1))
    }

    @Test("A span ending in an offered alternative is noise")
    func noiseOfferedAlternative() {
        #expect(FaithfulnessVerifier.isNoiseSpan(
            ["heat", "lamps", "or"],
            transcript: ["of", "heat", "lamps", "or", "headlamps"],
            end: 4))
    }

    @Test("A near-duplicate just after the span is a self-correction, so noise")
    func noiseSelfCorrection() {
        #expect(FaithfulnessVerifier.isNoiseSpan(
            ["hoped"],
            transcript: ["i", "hoped", "uh", "i", "hopped", "on"],
            end: 2))
    }

    @Test("A content span with no legitimizing signal is not noise")
    func notNoiseContent() {
        #expect(!FaithfulnessVerifier.isNoiseSpan(
            ["product", "side"],
            transcript: ["time", "on", "product", "side", "onboarding"],
            end: 4))
    }

    // MARK: isFormChange

    @Test("Spoken numbers rendered as digits are the same form")
    func formNumberDigits() {
        #expect(FaithfulnessVerifier.isFormChange(src: ["forty", "five"], dst: ["45"]))
        #expect(FaithfulnessVerifier.isFormChange(src: ["nine", "thirty"], dst: ["9", "30"]))
    }

    @Test("Tense, plural, and compound merges are the same form")
    func formStemChanges() {
        #expect(FaithfulnessVerifier.isFormChange(src: ["ship"], dst: ["shipped"]))
        #expect(FaithfulnessVerifier.isFormChange(src: ["half", "way"], dst: ["halfway"]))
    }

    @Test("A genuinely different word is not a form change")
    func formDifferentWord() {
        #expect(!FaithfulnessVerifier.isFormChange(src: ["scenarios"], dst: ["scanners"]))
        #expect(!FaithfulnessVerifier.isFormChange(src: ["occasionally"], dst: ["often"]))
    }

    // MARK: editDistanceWithin

    @Test("Bounded edit distance accepts within and rejects beyond the budget")
    func editDistance() {
        #expect(FaithfulnessVerifier.editDistanceWithin("hoped", "hopped", 1))
        #expect(FaithfulnessVerifier.editDistanceWithin("cat", "cats", 1))
        #expect(!FaithfulnessVerifier.editDistanceWithin("cat", "dog", 1))
        #expect(FaithfulnessVerifier.editDistanceWithin("", "ab", 2))
    }
}
