import Foundation
import Testing

@testable import UnrambleKit

// The content-loss guard flags a polish that summarized away a contiguous run
// of spoken content, while allowing faithful rewrites: number normalization,
// scattered filler removal, and repeated-word dedup. It returns the raw input
// as a fallback so nothing the user said is lost.
@Suite("Polish content guard")
struct PolishContentGuardTests {

    @Test("faithful polish keeps all content and does not fall back")
    func faithfulPolishPasses() {
        let raw = "the deployment finished on tuesday and the results look "
            + "really encouraging"
        let polished = "The deployment finished on Tuesday, and the results "
            + "look really encouraging."
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: polished, preprocessed: raw) == nil)
    }

    @Test("a dropped clause falls back to the raw input")
    func droppedClauseFallsBack() {
        let raw = "we finished moving the services on tuesday the nightly "
            + "batch job now finishes in under thirty five minutes"
        // The model summarized away the whole nightly-batch clause.
        let polished = "We finished moving the services on Tuesday."
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: polished, preprocessed: raw) == raw)
    }

    @Test("number normalization does not count as content loss")
    func numberNormalizationPasses() {
        let raw = "latency dropped by about forty percent and the job took "
            + "almost two hundred and fifty minutes"
        let polished = "Latency dropped by about 40%, and the job took almost "
            + "250 minutes."
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: polished, preprocessed: raw) == nil)
    }

    @Test("scattered filler removal does not count as content loss")
    func fillerRemovalPasses() {
        let raw = "um so basically the results are like really good you know"
        let polished = "The results are really good."
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: polished, preprocessed: raw) == nil)
    }

    @Test("repeated-word dedup does not count as content loss")
    func dedupPasses() {
        let raw = "keep an eye out eye on the results results this week"
        let polished = "Keep an eye on the results this week."
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: polished, preprocessed: raw) == nil)
    }

    @Test("a short faithful unit is not flagged")
    func shortUnitPasses() {
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: "See you at the standup.",
            preprocessed: "see you at the standup") == nil)
    }

    @Test("three missing content words in a row is tolerated; four falls back")
    func consecutiveMissingThreshold() {
        let base = "alpha bravo charlie delta echo foxtrot golf hotel"
        // Missing exactly three consecutive: charlie delta echo.
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: "alpha bravo foxtrot golf hotel", preprocessed: base) == nil)
        // Missing four consecutive: charlie delta echo foxtrot.
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: "alpha bravo golf hotel", preprocessed: base) == base)
    }

    @Test("streaming polish recovers content when the model drops a clause")
    func streamingPolishRecoversDroppedClause() async throws {
        let raw = "we shipped the api on monday the cache fix cut latency "
            + "and the dashboard is clean now"
        let out = await PolishPipeline.polish(
            raw, chatClient: ClauseDroppingClient(), breakMode: .commandsOnly)
        // The dropped clause's words survive because polish fell back to raw.
        #expect(out.lowercased().contains("cache"))
        #expect(out.lowercased().contains("latency"))
    }

    @Test("fabricated content falls back to the raw input")
    func fabricationFallsBack() {
        let raw = "the only thing I'm worried about is memory usage on the "
            + "reporting cluster"
        // The model invented a clause that is not in the input.
        let polished = "The only thing I am still doing is waiting for the "
            + "next job to start. I'm worried about memory usage on the "
            + "reporting cluster."
        #expect(PolishPipeline.guardAgainstFabrication(
            polished: polished, preprocessed: raw) == raw)
    }

    @Test("faithful polish adds no fabricated content")
    func faithfulPolishNoFabrication() {
        let raw = "we finished moving the services on tuesday and the results "
            + "look really encouraging"
        let polished = "We finished moving the services on Tuesday, and the "
            + "results look really encouraging."
        #expect(PolishPipeline.guardAgainstFabrication(
            polished: polished, preprocessed: raw) == nil)
    }

    @Test("number normalization is not fabrication")
    func numberNormalizationNotFabrication() {
        let raw = "latency dropped by about forty percent overnight"
        let polished = "Latency dropped by about 40% overnight."
        #expect(PolishPipeline.guardAgainstFabrication(
            polished: polished, preprocessed: raw) == nil)
    }

    @Test("a unit that fails the first polish is resampled and recovered")
    func retryRecoversAfterGuardFailure() async throws {
        let out = await PolishPipeline.polish(
            "our plan is basically to ship the cache fix on friday",
            chatClient: FlakyPolishClient(), breakMode: .commandsOnly)
        // The loop used the clean second attempt, not the raw fallback: the
        // filler is gone and the first attempt's fabricated words never appear.
        #expect(!out.lowercased().contains("basically"),
            "expected the resampled polish, got raw fallback: \(out.debugDescription)")
        #expect(!out.lowercased().contains("pizza"))
        #expect(out.lowercased().contains("cache"))
    }

    // The content guard must catch a genuine clause drop even when the missing
    // words individually reappear elsewhere or the surrounding words are
    // reordered — the two blind spots a set-membership check leaves open.

    @Test("a reordered clause drop falls back even when a word reappears")
    func reorderedClauseDropFallsBack() {
        // The polish dropped "we were worried about" and moved "both" to the
        // front. A set check counts "both" as present, so the missing run stays
        // at three and slips; an ordered comparison sees the real gap.
        let raw = "the two big customers we were worried about both renewed"
        let polished = "Both of our big customers renewed."
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: polished, preprocessed: raw) == raw)
    }

    @Test("a dropped clause whose words echo later still falls back")
    func droppedClauseWithEchoedWordsFallsBack() {
        // "and the latency is way better than before" is dropped, but "better"
        // reappears in "honestly better than expected," so a set check keeps
        // the missing run short. Ordered comparison catches the loss.
        let raw = "the database is running on the new cluster now and the "
            + "latency is way better than before we are seeing the response "
            + "drop by half which is honestly better than expected"
        let polished = "The database is running on the new cluster now. We are "
            + "seeing the response drop by half, which is honestly better than "
            + "expected."
        #expect(PolishPipeline.guardAgainstContentLoss(
            polished: polished, preprocessed: raw) == raw)
    }

    // A short invented phrase (2-3 words) slips under the distinct-novel-word
    // threshold; the contiguous-novel-run check catches it, while still sparing
    // a single-word repair.

    @Test("a short invented phrase falls back even under the novel-word count")
    func shortFabricatedPhraseFallsBack() {
        // "good idea" is only two novel words — under maximumNovelWords — but a
        // contiguous novel run of two, so it is an invented phrase.
        let raw = "on a newsletter open rates are holding steady"
        let polished = "On a newsletter, it's a good idea open rates are "
            + "holding steady."
        #expect(PolishPipeline.guardAgainstFabrication(
            polished: polished, preprocessed: raw) == raw)
    }

    @Test("a single-word repair is not fabrication")
    func singleWordRepairPasses() {
        // A lone novel content word between input anchors ("scenarios" misheard,
        // repaired to "scanners") is a run of one — a legitimate fix.
        let raw = "on the warehouse the new scenarios are working great"
        let polished = "On the warehouse, the new scanners are working great."
        #expect(PolishPipeline.guardAgainstFabrication(
            polished: polished, preprocessed: raw) == nil)
    }

    @Test("a verb-tense repair is not fabrication")
    func verbTenseRepairPasses() {
        let raw = "on the front end we finally ship the redesign"
        let polished = "On the front end, we finally shipped the redesign."
        #expect(PolishPipeline.guardAgainstFabrication(
            polished: polished, preprocessed: raw) == nil)
    }

    @Test("a phrase duplicated across a boundary falls back")
    func duplicatedPhraseFallsBack() {
        // "two weeks out" belongs to the first area; the model repeated it for
        // the second area and dropped that area's real content.
        let raw = "we're two weeks out on the machine learning models accuracy "
            + "is up on the dashboards leadership finally has what they need"
        let polished = "We're two weeks out. On the machine learning model, "
            + "we're two weeks out. On the dashboards, leadership finally has "
            + "what they need."
        #expect(PolishPipeline.guardAgainstDuplication(
            polished: polished, preprocessed: raw) == raw)
    }

    @Test("faithful segmentation is not duplication")
    func faithfulSegmentationNoDuplication() {
        let raw = "on the front end we finally ship the redesign on the back "
            + "end we're still chasing a memory leak"
        let polished = "On the front end, we finally shipped the redesign. On "
            + "the back end, we're still chasing a memory leak."
        #expect(PolishPipeline.guardAgainstDuplication(
            polished: polished, preprocessed: raw) == nil)
    }

    @Test("a novel pair split by a function word is still a run")
    func functionWordDoesNotMaskRun() {
        // "tightened" and "brakes" are separated by "our" (a function word in
        // the input) — without treating it as transparent the run stays at one
        // and the invented clause slips.
        let raw = "on reliability we hit our uptime goal on local"
        let polished = "On reliability, we hit our uptime goal. On local, we "
            + "tightened our brakes."
        #expect(PolishPipeline.guardAgainstFabrication(
            polished: polished, preprocessed: raw) == raw)
    }

    @Test("a single inserted word falls back")
    func singleInsertedWordFallsBack() {
        // "green" is one novel word, but it is added (content count grows), not
        // substituted for an input word — an insertion.
        let raw = "on error rates a little elevated but nothing serious"
        let polished = "On error rates, green a little elevated but nothing "
            + "serious."
        #expect(PolishPipeline.guardAgainstFabrication(
            polished: polished, preprocessed: raw) == raw)
    }

    @Test("a preposition swap is not an insertion")
    func prepositionSwapPasses() {
        // "waiting on" -> "waiting for" swaps one function word for another;
        // content count is unchanged, so it is not a fabricated insertion.
        let raw = "on procurement we're waiting on one approval"
        let polished = "On procurement, we're waiting for one approval."
        #expect(PolishPipeline.guardAgainstFabrication(
            polished: polished, preprocessed: raw) == nil)
    }
}

/// Echoes the input but deletes a middle clause, simulating a model that
/// summarizes a long unpunctuated run.
private final class ClauseDroppingClient: PolishChatClient, @unchecked Sendable {
    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        if let start = userPrompt.range(of: "the cache fix"),
            let end = userPrompt.range(of: "latency")
        {
            var trimmed = userPrompt
            trimmed.removeSubrange(start.lowerBound..<end.upperBound)
            return trimmed
        }
        return userPrompt
    }
}

/// Fabricates on the first call, then returns a clean, faithful polish — like
/// a model that only lands a good sample on a retry.
private final class FlakyPolishClient: PolishChatClient, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        let n = lock.withLock { calls += 1; return calls }
        if n == 1 {
            return "Our plan is basically to ship the cache fix on Friday and "
                + "then we celebrated with pizza cake and beer."
        }
        return "Our plan is to ship the cache fix on Friday."
    }
}
