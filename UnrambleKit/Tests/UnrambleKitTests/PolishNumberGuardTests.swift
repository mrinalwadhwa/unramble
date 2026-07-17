import Foundation
import Testing

@testable import UnrambleKit

// The number guard flags a polish that substituted or duplicated a dictated
// number — the costliest faithfulness failure and one the content-word guards
// ignore by design. It must fire only on a clear substitution and stay silent
// on every faithful rendering: digit normalization, composed numbers, times,
// years, versions, ordinals, and small numbers kept as words.
@Suite("Polish number guard")
struct PolishNumberGuardTests {

    // MARK: - Fires on a real substitution

    @Test("a substituted number falls back to the raw input")
    func substitutedNumberFallsBack() {
        // "twelve" became "3," conflated with the nearby "three minutes": the
        // value 12 is gone and 3 is duplicated.
        let raw = "we cut the build time from about forty five minutes down to "
            + "twelve and the test suite now runs in under three minutes"
        let polished = "We cut the build time from about 45 minutes down to 3 "
            + "minutes, and the test suite now runs in under 3 minutes."
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: polished, preprocessed: raw) == raw)
    }

    // MARK: - False-positive wall (must not fire)

    @Test("digit normalization is faithful")
    func normalizationPasses() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "Latency dropped by about 40%.",
            preprocessed: "latency dropped by about forty percent") == nil)
    }

    @Test("a composed number is faithful")
    func composedNumberPasses() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "The job took 250 minutes.",
            preprocessed: "the job took two hundred and fifty minutes") == nil)
    }

    @Test("a spoken time is faithful")
    func timePasses() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "Let's meet at 3:30.",
            preprocessed: "let's meet at three thirty") == nil)
    }

    @Test("a version number is faithful")
    func versionPasses() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "Ship version 2.1.",
            preprocessed: "ship version two point one") == nil)
    }

    @Test("a spoken year is faithful")
    func yearPasses() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "Back in 1984 it shipped.",
            preprocessed: "back in nineteen eighty four it shipped") == nil)
    }

    @Test("small numbers kept as words are faithful")
    func smallNumbersAsWordsPass() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "Give me one or two options.",
            preprocessed: "give me one or two options") == nil)
    }

    @Test("an ordinal date is faithful")
    func ordinalPasses() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "The deadline is April 15th.",
            preprocessed: "the deadline is April fifteenth") == nil)
    }

    @Test("digits passed through unchanged are faithful")
    func digitPassthroughPasses() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "The timeout is 5 minutes.",
            preprocessed: "the timeout is 5 minutes") == nil)
    }

    @Test("two faithfully normalized numbers do not fire")
    func twoFaithfulNumbersPass() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "We need 45 servers and 60 gigs.",
            preprocessed: "we need forty five servers and sixty gigs") == nil)
    }

    @Test("a comma-grouped thousand is faithful")
    func commaGroupedThousandPasses() {
        #expect(PolishPipeline.guardAgainstNumberChange(
            polished: "That is about 1,200 rows.",
            preprocessed: "that is about twelve hundred rows") == nil)
    }
}
