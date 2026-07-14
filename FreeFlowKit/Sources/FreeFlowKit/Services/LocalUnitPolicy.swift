import Foundation

/// Byte-accurate boundaries that close a local dictation unit for polish.
/// Decisions use admitted 16 kHz mono PCM16 source bytes rather than wall-clock
/// time so buffering and scheduler delays cannot move where a unit ends.
///
/// A unit closes on an acoustic pause or on a size cap. The cap bounds the
/// polish input so the on-device model stays faithful on long, unpunctuated
/// speech. A pause long enough to be a `hardPause` is also a safe point to reset
/// recognition state, because no spoken word spans it; a size-cap close is not,
/// because it can fall mid-word.
public struct LocalUnitPolicy: Equatable, Sendable {

    /// How a unit ends. `hardPause` also authorizes a recognition-state reset;
    /// `softClose` only ends the unit for polish and never resets state.
    public enum Boundary: Equatable, Sendable {
        case softClose
        case hardPause
    }

    static let sourceBytesPerSecond = 16_000 * MemoryLayout<Int16>.size

    let minimumSpeechBytes: Int
    let softPauseSilenceBytes: Int
    let hardPauseSilenceBytes: Int
    let maximumUnitBytes: Int

    public init(
        minimumSpeechSeconds: TimeInterval = 0.6,
        softPauseSeconds: TimeInterval = 0.3,
        hardPauseSeconds: TimeInterval = 0.7,
        maximumUnitSeconds: TimeInterval = 11
    ) {
        self.init(
            minimumSpeechBytes: Self.alignedByteCount(minimumSpeechSeconds),
            softPauseSilenceBytes: Self.alignedByteCount(softPauseSeconds),
            hardPauseSilenceBytes: Self.alignedByteCount(hardPauseSeconds),
            maximumUnitBytes: Self.alignedByteCount(maximumUnitSeconds))
    }

    init(
        minimumSpeechBytes: Int,
        softPauseSilenceBytes: Int,
        hardPauseSilenceBytes: Int,
        maximumUnitBytes: Int
    ) {
        precondition(minimumSpeechBytes >= 0 && minimumSpeechBytes.isMultiple(of: 2))
        precondition(softPauseSilenceBytes >= 0 && softPauseSilenceBytes.isMultiple(of: 2))
        precondition(hardPauseSilenceBytes >= softPauseSilenceBytes)
        precondition(hardPauseSilenceBytes.isMultiple(of: 2))
        precondition(maximumUnitBytes > 0 && maximumUnitBytes.isMultiple(of: 2))
        self.minimumSpeechBytes = minimumSpeechBytes
        self.softPauseSilenceBytes = softPauseSilenceBytes
        self.hardPauseSilenceBytes = hardPauseSilenceBytes
        self.maximumUnitBytes = maximumUnitBytes
    }

    /// Decide whether the current unit should close.
    /// - Parameters:
    ///   - unitByteCount: total admitted source bytes since the unit began,
    ///     including any trailing silence.
    ///   - trailingSilenceByteCount: the current run of trailing silence bytes.
    func boundary(
        unitByteCount: Int,
        trailingSilenceByteCount: Int
    ) -> Boundary? {
        let speechBytes = unitByteCount - trailingSilenceByteCount
        // A long pause both ends the unit and authorizes a reset, but only once
        // the unit holds enough speech to be worth closing.
        if speechBytes >= minimumSpeechBytes,
            trailingSilenceByteCount >= hardPauseSilenceBytes
        {
            return .hardPause
        }
        if speechBytes >= minimumSpeechBytes,
            trailingSilenceByteCount >= softPauseSilenceBytes
        {
            return .softClose
        }
        // A unit that never pauses still closes at the cap to keep the polish
        // input small; without a pause it is not safe to reset state.
        if unitByteCount >= maximumUnitBytes {
            return .softClose
        }
        return nil
    }

    private static func alignedByteCount(_ seconds: TimeInterval) -> Int {
        precondition(seconds >= 0 && seconds.isFinite)
        let raw = Int(seconds * Double(sourceBytesPerSecond))
        return raw - raw % MemoryLayout<Int16>.size
    }
}
