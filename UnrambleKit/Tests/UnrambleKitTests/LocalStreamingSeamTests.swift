import Foundation
import Testing

@testable import UnrambleKit

/// Seam-carry defenses for a size-cap soft-close that falls mid-word or
/// mid-sentence: dedup a re-recognized span, strip a fabricated fragment
/// completion, and keep a completed partial word from re-appearing.
@Suite("LocalStreamingSeam")
struct LocalStreamingSeamTests {

    // MARK: joinCarryUnit — dedup a re-recognized span at the join

    @Test("Mid-word re-recognition dedups across the seam")
    func midWordDedup() {
        // Carry holds the polish's completion "grabbed it." (terminated); the unit
        // re-emits the same speech from the mid-word split ("...grabb" -> "ed it").
        let out = LocalStreamingProvider.joinCarryUnit(
            carry: "one of my neighbors grabbed it.",
            unit: "ed it for safekeeping and dropped it by later that evening")
        #expect(out == "one of my neighbors grabbed it for safekeeping and dropped it by later that evening")
    }

    @Test("Whole-word re-recognition dedups at the seam")
    func wholeWordDedup() {
        let out = LocalStreamingProvider.joinCarryUnit(
            carry: "lock the back door", unit: "door and set the alarm")
        #expect(out == "lock the back door and set the alarm")
    }

    @Test("A held terminator is dropped so the fragment continues")
    func terminatorStripped() {
        // No overlap: the held sentence's terminator is removed so it reads as
        // continuing into the next unit rather than already finished.
        let out = LocalStreamingProvider.joinCarryUnit(
            carry: "grabbed it.", unit: "then we headed home")
        #expect(out == "grabbed it then we headed home")
    }

    @Test("No overlap leaves both sides intact (previous behavior)")
    func noOverlapPassthrough() {
        let out = LocalStreamingProvider.joinCarryUnit(
            carry: "we started the hike", unit: "the trail was muddy")
        #expect(out == "we started the hike the trail was muddy")
    }

    @Test("A coincidental mid-word match never chops a real word")
    func noMidWordChop() {
        // "saw" is a suffix of the carry key and a prefix of "sawdust", but the
        // match ends mid-word, so "sawdust" must survive whole.
        let out = LocalStreamingProvider.joinCarryUnit(
            carry: "I saw", unit: "sawdust everywhere")
        #expect(out == "I saw sawdust everywhere")
    }

    @Test("A truly repeated leading word is deduped")
    func repeatedLeadingWord() {
        let out = LocalStreamingProvider.joinCarryUnit(
            carry: "I saw", unit: "saw the movie")
        #expect(out == "I saw the movie")
    }

    @Test("Empty sides pass through")
    func emptySides() {
        #expect(LocalStreamingProvider.joinCarryUnit(carry: "", unit: "hello") == "hello")
        #expect(LocalStreamingProvider.joinCarryUnit(carry: "hello", unit: "") == "hello")
    }

    // MARK: stripFabricatedCarryTail — drop an invented fragment completion

    @Test("A fabricated completion past the fragment's last word is stripped")
    func stripsFabricatedCompletion() {
        // The raw fragment ends at "internet"; the polish invented "blinked"
        // (a word that also appears earlier, so a set membership check would miss
        // it — alignment on the last raw content word catches it).
        let out = LocalStreamingProvider.stripFabricatedCarryTail(
            carry: "Then all of a sudden the internet blinked",
            inputTail: "the little lights just blinked for a really long time and then all of a sudden the internet")
        #expect(out == "Then all of a sudden the internet")
    }

    @Test("A carry that ends at the fragment's last word is untouched")
    func keepsFaithfulCompletion() {
        let out = LocalStreamingProvider.stripFabricatedCarryTail(
            carry: "the report is basically done",
            inputTail: "the report is basically done")
        #expect(out == "the report is basically done")
    }

    @Test("A trailing connector after the last word is not a fabrication")
    func keepsTrailingConnector() {
        let out = LocalStreamingProvider.stripFabricatedCarryTail(
            carry: "senior roles and to revisit the",
            inputTail: "we promoted her to senior roles and to revisit the")
        #expect(out == "senior roles and to revisit the")
    }

    @Test("A long tail past the anchor is left alone (unreliable anchor)")
    func keepsLongTail() {
        let out = LocalStreamingProvider.stripFabricatedCarryTail(
            carry: "the internet came back and everything was totally fine",
            inputTail: "all of a sudden the internet")
        #expect(out == "the internet came back and everything was totally fine")
    }

    // MARK: droppedTailSuffix — a completed partial word is not "dropped"

    @Test("A completed partial word is not re-appended")
    func completedPartialNotDropped() {
        let drop = LocalStreamingProvider.droppedTailSuffix(
            inputTail: "one of my neighbors grabb",
            polished: "One of my neighbors grabbed it.")
        #expect(drop == nil)
    }

    @Test("A merged word pair is not mistaken for a dropped tail")
    func mergedWordNotDropped() {
        // Polish rejoins "half way" -> "halfway"; "way" looks missing but the rest
        // of the tail ("up it started pouring again") is present, so nothing was
        // dropped and the suffix must not be re-appended (which would duplicate).
        let drop = LocalStreamingProvider.droppedTailSuffix(
            inputTail: "about half way up it started pouring again",
            polished: "About halfway up it started pouring again.")
        #expect(drop == nil)
    }

    @Test("A genuinely dropped tail is still recovered")
    func realDropStillRecovered() {
        let drop = LocalStreamingProvider.droppedTailSuffix(
            inputTail: "revisit the comp bands",
            polished: "revisit the.")
        #expect(drop != nil)
        #expect(drop?.suffix.contains("comp") == true)
        #expect(drop?.suffix.contains("bands") == true)
    }

    @Test("A number/hyphen form-changed tail is not re-appended")
    func formChangedTailNotDropped() {
        // Polish renders "nine thirty" as "9:30" and "stand up" as "stand-up";
        // those words are present in the output in a changed form, so the tail was
        // not dropped and must not be re-appended (which duplicated "…thanks Alex").
        let drop = LocalStreamingProvider.droppedTailSuffix(
            inputTail: "see you at the stand up at nine thirty thanks Alex",
            polished: "I'll see you at the stand-up at 9:30. Thanks, Alex.")
        #expect(drop == nil)
    }

    // MARK: reconcileSplitWords — rejoin a mid-word space-split from the raw STT

    @Test("A mid-word space-split is rejoined via the raw transcript")
    func splitWordRejoined() {
        let out = LocalStreamingProvider.reconcileSplitWords(
            "On search, the relev ance is much better.",
            raw: "on search the relevance is much better")
        #expect(out == "On search, the relevance is much better.")
    }

    @Test("Split 'mod els' rejoins to 'models'")
    func splitModelsRejoined() {
        let out = LocalStreamingProvider.reconcileSplitWords(
            "the machine learning mod els accuracy is up",
            raw: "on the machine learning models accuracy is up")
        #expect(out == "the machine learning models accuracy is up")
    }

    @Test("A genuine two-word sequence is not merged")
    func genuineWordsNotMerged() {
        // The raw has "saw" and "dust" as separate words, so "sawdust" is not a raw
        // token and the pair is left as two words.
        let out = LocalStreamingProvider.reconcileSplitWords(
            "We swept the saw dust off the bench.",
            raw: "we swept the saw dust off the bench")
        #expect(out == "We swept the saw dust off the bench.")
    }

    @Test("A capitalized continuation is not merged")
    func capitalizedNotMerged() {
        // "Ency" is capitalized (a sentence start) and "residues." is terminated,
        // so the polish garble "residues. Ency" is left alone (out of scope).
        let out = LocalStreamingProvider.reconcileSplitWords(
            "questions about data residues. Ency and more",
            raw: "questions about data residency and more")
        #expect(out == "questions about data residues. Ency and more")
    }
}
