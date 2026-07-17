import Foundation
import Testing

@testable import UnrambleKit

@Suite("SoundFeedbackProvider – sound path resolution")
struct SoundFeedbackPathTests {

    @Test("resolveSoundPath returns first existing path")
    func firstExistingPath() {
        let bogus = "/nonexistent/path/\(UUID().uuidString).caf"
        let known = "/System/Library/Sounds/Tink.aiff"
        let result = SoundFeedbackProvider.resolveSoundPath([bogus, known])
        #expect(result == known)
    }

    @Test("resolveSoundPath returns nil when no paths exist")
    func noPathsExist() {
        let result = SoundFeedbackProvider.resolveSoundPath([
            "/nonexistent/a.caf",
            "/nonexistent/b.caf",
        ])
        #expect(result == nil)
    }

    @Test("resolveSoundPath returns first path when multiple exist")
    func prefersFirstMatch() {
        let first = "/System/Library/Sounds/Tink.aiff"
        let second = "/System/Library/Sounds/Pop.aiff"
        let result = SoundFeedbackProvider.resolveSoundPath([first, second])
        #expect(result == first)
    }

    @Test("Start sound candidates include stable fallback")
    func startCandidatesHaveFallback() {
        let candidates = SoundFeedbackProvider.startSoundCandidates
        #expect(candidates.count >= 2, "Must have at least a primary and a fallback")
        // The last candidate should be from /System/Library/Sounds/ (stable).
        let last = candidates.last!
        #expect(last.hasPrefix("/System/Library/Sounds/"))
    }

    @Test("Stop sound candidates include stable fallback")
    func stopCandidatesHaveFallback() {
        let candidates = SoundFeedbackProvider.stopSoundCandidates
        #expect(candidates.count >= 2, "Must have at least a primary and a fallback")
        let last = candidates.last!
        #expect(last.hasPrefix("/System/Library/Sounds/"))
    }

    @Test("Resolved start sound exists on this machine")
    func startSoundResolvesOnThisMachine() {
        let path = SoundFeedbackProvider.resolveSoundPath(
            SoundFeedbackProvider.startSoundCandidates)
        #expect(path != nil, "At least one start sound candidate must exist")
    }

    @Test("Resolved stop sound exists on this machine")
    func stopSoundResolvesOnThisMachine() {
        let path = SoundFeedbackProvider.resolveSoundPath(
            SoundFeedbackProvider.stopSoundCandidates)
        #expect(path != nil, "At least one stop sound candidate must exist")
    }

    @Test("availableSystemSounds returns non-empty list")
    func availableSystemSoundsNonEmpty() {
        let sounds = SoundFeedbackProvider.availableSystemSounds()
        #expect(!sounds.isEmpty)
        // All paths should exist.
        for path in sounds {
            #expect(
                FileManager.default.fileExists(atPath: path),
                "Listed sound must exist: \(path)")
        }
    }
}
