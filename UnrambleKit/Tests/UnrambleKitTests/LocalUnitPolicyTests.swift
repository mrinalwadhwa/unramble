import Foundation
import Testing

@testable import UnrambleKit

@Suite("LocalUnitPolicy")
struct LocalUnitPolicyTests {

    // A small, readable byte-based policy: 100 bytes of speech before a unit may
    // close, a 30-byte soft pause, a 70-byte hard pause, and a 1000-byte cap.
    private func policy() -> LocalUnitPolicy {
        LocalUnitPolicy(
            minimumSpeechBytes: 100,
            softPauseSilenceBytes: 30,
            hardPauseSilenceBytes: 70,
            maximumUnitBytes: 1000)
    }

    @Test("default policy derives even byte thresholds from seconds")
    func defaultThresholds() {
        let p = LocalUnitPolicy()
        let bps = 16_000 * MemoryLayout<Int16>.size

        #expect(p.minimumSpeechBytes == Int(0.6 * Double(bps)))
        #expect(p.softPauseSilenceBytes == Int(0.3 * Double(bps)))
        #expect(p.hardPauseSilenceBytes == Int(0.7 * Double(bps)))
        #expect(p.maximumUnitBytes == 11 * bps)
    }

    @Test("a unit below minimum speech never closes, even after a long pause")
    func belowMinimumSpeechNeverCloses() {
        // 50 bytes of speech, 450 of trailing silence: well past the hard pause,
        // but there is too little speech to be worth closing.
        #expect(policy().boundary(
            unitByteCount: 500, trailingSilenceByteCount: 450) == nil)
    }

    @Test("enough speech with a moderate pause soft-closes without a reset")
    func softPauseClosesWithoutReset() {
        // speech 110 >= 100, silence 40 in [30, 70).
        #expect(policy().boundary(
            unitByteCount: 150, trailingSilenceByteCount: 40) == .softClose)
    }

    @Test("enough speech with a long pause closes and authorizes a reset")
    func hardPauseClosesAndAuthorizesReset() {
        // speech 120 >= 100, silence 80 >= 70.
        #expect(policy().boundary(
            unitByteCount: 200, trailingSilenceByteCount: 80) == .hardPause)
    }

    @Test("continuous speech closes at the size cap as a soft close, not a reset")
    func sizeCapSoftClosesContinuousSpeech() {
        // 1000 bytes of speech with no trailing silence: the cap bounds the
        // polish input, but with no pause it is not safe to reset state.
        #expect(policy().boundary(
            unitByteCount: 1000, trailingSilenceByteCount: 0) == .softClose)
    }

    @Test("enough speech but no pause and below the cap does not close")
    func belowAllThresholdsDoesNotClose() {
        // speech 110 >= 100, but silence 10 < 30 soft, and 120 < 1000 cap.
        #expect(policy().boundary(
            unitByteCount: 120, trailingSilenceByteCount: 10) == nil)
    }

    @Test("soft pause fires exactly at its threshold and not one byte below")
    func softPauseBoundaryValue() {
        #expect(policy().boundary(
            unitByteCount: 140, trailingSilenceByteCount: 30) == .softClose)
        #expect(policy().boundary(
            unitByteCount: 138, trailingSilenceByteCount: 28) == nil)
    }

    @Test("hard pause fires exactly at its threshold; just below it soft-closes")
    func hardPauseBoundaryValue() {
        #expect(policy().boundary(
            unitByteCount: 170, trailingSilenceByteCount: 70) == .hardPause)
        #expect(policy().boundary(
            unitByteCount: 168, trailingSilenceByteCount: 68) == .softClose)
    }
}
