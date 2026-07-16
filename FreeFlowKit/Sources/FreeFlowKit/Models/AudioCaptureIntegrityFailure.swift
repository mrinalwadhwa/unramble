import Foundation

/// A capture completed without every frame that may belong to the dictation.
public struct AudioCaptureIntegrityFailure: Error, Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case retentionCopy
        case routeSliceCopy
        case timestampCoverage
        case pcmConversion
        case converterDrain
        case releaseDrain
    }

    public let stage: Stage
    public let affectedFrameCount: Int?

    public init(stage: Stage, affectedFrameCount: Int?) {
        self.stage = stage
        self.affectedFrameCount = affectedFrameCount
    }
}

/// Exact-route first-failure publication shared by the router and PCM sink.
final class AudioCaptureIntegrityPublication: @unchecked Sendable {
    private let lock = NSLock()
    private var firstFailure: AudioCaptureIntegrityFailure?

    var failure: AudioCaptureIntegrityFailure? {
        lock.withLock { firstFailure }
    }

    @discardableResult
    func record(_ failure: AudioCaptureIntegrityFailure) -> Bool {
        lock.withLock {
            guard firstFailure == nil else { return false }
            firstFailure = failure
            return true
        }
    }
}
