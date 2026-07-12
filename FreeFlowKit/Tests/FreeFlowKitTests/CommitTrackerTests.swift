import Foundation
import Testing

@testable import FreeFlowKit

@Suite("CommitTracker")
struct CommitTrackerTests {

    /// A false sentence terminator (a period a later cycle extends past)
    /// must not be committed. Reproduces the real failure from a 96s
    /// dictation where "…before our sync." became
    /// "…before our sync tomorrow new paragraph.".
    @Test("False terminator is not committed prematurely")
    func falseTerminator() {
        var tracker = CommitTracker()

        // Cycle 1: recognizer ends the sentence early at "sync".
        #expect(tracker.ingest(
            "Hi Prio before our sync.").isEmpty)
        #expect(tracker.committed == 0)

        // Cycle 2: the boundary moved — "sync" was not the end.
        let c2 = tracker.ingest(
            "Hi Prio before our sync tomorrow new paragraph. "
            + "We finished the work")
        #expect(c2.isEmpty)
        #expect(tracker.committed == 0)

        // Cycle 3: sentence 0 is now stable and followed by more, so it
        // commits — in its corrected form, never as "…sync.".
        let c3 = tracker.ingest(
            "Hi Prio before our sync tomorrow new paragraph. "
            + "We finished the work. Query latency dropped.")
        #expect(c3.contains(
            "Hi Prio before our sync tomorrow new paragraph."))
        #expect(!c3.contains("Hi Prio before our sync."))
        #expect(tracker.committed == 2)
    }

    /// Committing is forward-only and loses nothing: every sentence of
    /// the final transcript is emitted exactly once, in order, across
    /// the ingest cycles plus the final flush.
    @Test("Forward-only commit reconstructs the full transcript")
    func lossless() {
        let final = emailFinal
        let words = final.split(separator: " ").map(String.init)

        var tracker = CommitTracker()
        var emitted: [String] = []

        // Simulate streaming growth: feed increasing word-prefixes.
        var count = 6
        while count < words.count {
            let prefix = words.prefix(count).joined(separator: " ")
            emitted += tracker.ingest(prefix)
            count += 7
        }
        emitted += tracker.ingest(final)
        emitted += tracker.commitRemaining(final)

        #expect(emitted == CommitTracker.splitIntoSentences(final))
        // Nothing was dropped: the stranded phrase survives.
        #expect(emitted.joined(separator: " ")
            .contains("sync tomorrow new paragraph"))
    }

    /// A list dictated without sentence terminators stays fully volatile
    /// until it closes, so it is polished as one holistic unit.
    @Test("Terminator-less list stays volatile until it closes")
    func listHeldVolatile() {
        var tracker = CommitTracker()

        #expect(tracker.ingest(
            "The action items are as follows").isEmpty)
        #expect(tracker.ingest(
            "The action items are as follows new line fix the login "
            + "bug new line update the docs").isEmpty)
        #expect(tracker.ingest(
            "The action items are as follows new line fix the login "
            + "bug new line update the docs new line deploy to staging"
        ).isEmpty)
        #expect(tracker.committed == 0)

        // Once the list closes with a real sentence, the whole thing
        // flushes together at finish.
        let remaining = tracker.commitRemaining(
            "The action items are as follows new line fix the login "
            + "bug new line update the docs new line deploy to staging. "
            + "Let me know.")
        #expect(!remaining.isEmpty)
        #expect(remaining.joined(separator: " ").contains("deploy to staging"))
    }

    /// The committed count never decreases across a noisy sequence.
    @Test("Commit count is monotonic")
    func monotonic() {
        var tracker = CommitTracker()
        var last = 0
        for transcript in [
            "One two three.",
            "One two three. Four five.",
            "One two three. Four five six. Seven.",
            "One two three. Four five six. Seven eight nine.",
        ] {
            _ = tracker.ingest(transcript)
            #expect(tracker.committed >= last)
            last = tracker.committed
        }
    }

    /// Abbreviations, initials, and decimals must not be split, so a
    /// committed or tail chunk is never cut mid-token.
    @Test("Abbreviations, initials, and decimals stay intact")
    func abbreviationsNotSplit() {
        let a = CommitTracker.splitIntoSentences(
            "The meeting is at 3 p.m. in room 4.5 today. See you then.")
        #expect(a == [
            "The meeting is at 3 p.m. in room 4.5 today.",
            "See you then.",
        ])

        let b = CommitTracker.splitIntoSentences(
            "We met Dr. Smith from the U.S. yesterday. It went well.")
        #expect(b == [
            "We met Dr. Smith from the U.S. yesterday.",
            "It went well.",
        ])
    }

    // The real Nemotron final transcript from a 96s email dictation.
    private let emailFinal =
        "Hi Prio, I wanted to give you a quick update on where things "
        + "stand with the analytics migration before our sync tomorrow "
        + "new paragraph. We finished moving the last three services "
        + "over the new over to the new pipeline on Tuesday and so far "
        + "the results look really encouraging. Query latency dropped "
        + "by about forty percent and the Nightly batch job that used "
        + "to take almost two hours now finishes in under thirty five "
        + "minutes. The only thing I'm still a little worried about is "
        + "memory usage on the reporting cluster which spiked to around "
        + "twelve gigabytes overnight, so I have asked Marcus to keep "
        + "an eye out eye on it this week new paragraph on this "
        + "timeline. I still think we can hit the end of month "
        + "deadline, but it depends on whether the security review "
        + "comes back clean. If we get sign off by Thursday, we should "
        + "be able to ship to production on the twenty eighth I'll send "
        + "out a more detailed plan once I've talked to the platform "
        + "team. Let me know if you have any questions and I'll see. "
        + "See you at the stand up at nine thirty. Thanks, Alex."
}
