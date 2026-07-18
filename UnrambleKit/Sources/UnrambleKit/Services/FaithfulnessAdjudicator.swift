import Foundation
import FoundationModels

/// Judge faithfulness candidates with Apple's on-device language model.
///
/// The deterministic `FaithfulnessVerifier` surfaces changed spans it cannot
/// resolve. This adjudicates each one with a narrow, well-posed question, so the
/// model only ever sees a short phrase and its immediate context — never the
/// whole dictation. It runs only when Apple Intelligence is available; when it
/// is not, it flags nothing and the pipeline keeps its existing deterministic
/// behavior.
@available(macOS 26.0, *)
enum FaithfulnessAdjudicator {

    /// Whether on-device adjudication can run right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Adjudicate each candidate and return only the ones the model judges a
    /// real faithfulness break. Returns an empty result when the model is
    /// unavailable, so callers keep today's deterministic-only behavior.
    static func flagged(
        _ candidates: [FaithfulnessVerifier.Candidate]
    ) async -> [FaithfulnessVerifier.Candidate] {
        guard isAvailable, !candidates.isEmpty else { return [] }
        var result: [FaithfulnessVerifier.Candidate] = []
        for candidate in candidates {
            if await isBreak(candidate) { result.append(candidate) }
        }
        return result
    }

    /// Judge a candidate, voting across several samples to damp the model's
    /// run-to-run nondeterminism. A tie breaks toward flagging so faithfulness
    /// stays the floor: a false positive costs some polish, a false negative
    /// costs meaning.
    static func isBreak(_ candidate: FaithfulnessVerifier.Candidate, votes: Int = 3) async -> Bool {
        var flags = 0
        for _ in 0..<max(1, votes) {
            if await judgeOnce(candidate) { flags += 1 }
        }
        return flags * 2 >= max(1, votes)
    }

    /// One model judgment. A failed judgment is biased toward flagging.
    static func judgeOnce(_ candidate: FaithfulnessVerifier.Candidate) async -> Bool {
        let session = LanguageModelSession(instructions: systemInstructions)
        do {
            switch candidate.kind {
            case .omission:
                let response = try await session.respond(
                    to: omissionPrompt(candidate), generating: OmissionVerdict.self)
                return response.content == .meaningful
            case .substitution:
                let response = try await session.respond(
                    to: substitutionPrompt(candidate), generating: SubstitutionVerdict.self)
                return response.content == .changed
            }
        } catch {
            Log.debug("[Faithfulness] adjudication failed, flagging to be safe: \(error)")
            return true
        }
    }

    /// Whether removing a span dropped meaning.
    @Generable
    enum OmissionVerdict {
        /// The removed words carry meaning that should have been kept.
        case meaningful
        /// The removed words are filler, a stutter, or a self-correction.
        case noise
    }

    /// Whether a substitution changed meaning.
    @Generable
    enum SubstitutionVerdict {
        /// A form fix — tense, plural, or number rendering — same meaning.
        case same
        /// A different word — the meaning changed.
        case changed
    }

    static let systemInstructions = """
        You are a strict faithfulness checker for a dictation cleanup tool. The \
        tool may remove filler words (um, uh, okay, like), stutters, and \
        self-corrections, and may fix punctuation, capitalization, tense, \
        plurals, and sentence breaks. It must not drop meaningful content, \
        change a word's meaning, or move a phrase into the wrong sentence.
        """

    static func omissionPrompt(_ candidate: FaithfulnessVerifier.Candidate) -> String {
        """
        A phrase that names a place, area, thing, person, time, or amount is \
        meaningful even if short. Only fillers (um, uh, okay, like, you know), \
        stutters, and self-corrections are noise.
        Dictation: "\(candidate.context)"
        The cleanup removed the words: "\(candidate.span)".
        """
    }

    static func substitutionPrompt(_ candidate: FaithfulnessVerifier.Candidate) -> String {
        """
        A typo, tense, plural, or number-form fix keeps the same meaning. A \
        different word, even a similar-sounding one, changed the meaning.
        Dictation said: "\(candidate.span)"
        The cleanup changed it to: "\(candidate.replacement)".
        """
    }
}
