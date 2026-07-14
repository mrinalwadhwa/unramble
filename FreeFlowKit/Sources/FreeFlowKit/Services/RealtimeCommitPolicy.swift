import Foundation

/// Byte-accurate commit boundaries for 16 kHz mono PCM16 source audio.
/// Decisions use captured audio duration rather than wall-clock time so replay,
/// buffering, and scheduler delays cannot change source coverage.
public struct RealtimeCommitPolicy: Equatable, Sendable {

    static let sourceBytesPerSecond = 16_000 * MemoryLayout<Int16>.size

    /// A 7 MiB source slice becomes at most 10.5 MiB of 24 kHz PCM and
    /// 14,680,064 bytes of unescaped base64. That leaves about 319 KB for the
    /// JSON envelope below a conservative 15,000,000-byte ceiling, which is
    /// stricter than the API's documented 15 MiB append-event limit.
    static let maximumAppendSourceBytes = 7 * 1_024 * 1_024

    let maximumUniqueBytes: Int
    let minimumUniqueBytesBeforeSilence: Int
    let trailingSilenceBytesRequired: Int

    public init(
        maxChunkSeconds: TimeInterval = 300,
        minSilenceCommitSeconds: TimeInterval = 180,
        requiredSilenceSeconds: TimeInterval = 10
    ) {
        self.init(
            maximumUniqueBytes: Self.alignedByteCount(maxChunkSeconds),
            minimumUniqueBytesBeforeSilence: Self.alignedByteCount(
                minSilenceCommitSeconds),
            trailingSilenceBytesRequired: Self.alignedByteCount(
                requiredSilenceSeconds))
    }

    init(
        maximumUniqueBytes: Int,
        minimumUniqueBytesBeforeSilence: Int,
        trailingSilenceBytesRequired: Int
    ) {
        precondition(maximumUniqueBytes > 0 && maximumUniqueBytes.isMultiple(of: 2))
        precondition(minimumUniqueBytesBeforeSilence >= 0)
        precondition(minimumUniqueBytesBeforeSilence <= maximumUniqueBytes)
        precondition(minimumUniqueBytesBeforeSilence.isMultiple(of: 2))
        precondition(trailingSilenceBytesRequired >= 0)
        precondition(trailingSilenceBytesRequired.isMultiple(of: 2))
        self.maximumUniqueBytes = maximumUniqueBytes
        self.minimumUniqueBytesBeforeSilence = minimumUniqueBytesBeforeSilence
        self.trailingSilenceBytesRequired = trailingSilenceBytesRequired
    }

    func shouldCommit(
        uniqueByteCount: Int,
        trailingSilenceByteCount: Int
    ) -> Bool {
        if uniqueByteCount >= maximumUniqueBytes {
            return true
        }
        return uniqueByteCount >= minimumUniqueBytesBeforeSilence
            && trailingSilenceByteCount >= trailingSilenceBytesRequired
    }

    private static func alignedByteCount(_ seconds: TimeInterval) -> Int {
        precondition(seconds >= 0 && seconds.isFinite)
        let raw = Int(seconds * Double(sourceBytesPerSecond))
        return raw - raw % MemoryLayout<Int16>.size
    }
}
