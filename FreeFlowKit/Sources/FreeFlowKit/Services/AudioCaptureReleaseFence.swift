import Foundation

#if canImport(AVFoundation)
    import AVFoundation
    import CoreAudio
    import Darwin

    /// One physical key press owns one release boundary. The event-tap thread
    /// publishes key-up directly so audio callbacks do not wait for driver or
    /// pipeline actor scheduling before observing the cutoff.
    public final class AudioCaptureReleaseBoundary: @unchecked Sendable {
        private let lock = NSLock()
        private var storedReleaseHostTime: UInt64?
        public let pressHostTime: UInt64

        public convenience init() {
            self.init(pressHostTime: AudioCaptureReleaseFence.currentHostTime())
        }

        public init(pressHostTime: UInt64) {
            self.pressHostTime = pressHostTime
        }

        public var releaseHostTime: UInt64? {
            lock.withLock { storedReleaseHostTime }
        }

        /// Publish only the first release. Duplicate or stale releases cannot
        /// move an already-owned boundary later in time.
        @discardableResult
        public func publish(releaseHostTime: UInt64) -> Bool {
            lock.withLock {
                guard storedReleaseHostTime == nil else { return false }
                storedReleaseHostTime = releaseHostTime
                return true
            }
        }
    }

    /// Converts a host-time release boundary into the exact prefix of an input
    /// buffer whose sample timestamps precede that boundary.
    enum AudioCaptureReleaseFence {
        static func currentHostTime() -> UInt64 {
            mach_absolute_time()
        }

        /// `CGEvent.timestamp` is elapsed nanoseconds since startup. Convert it
        /// into the Mach host-time ticks used by AVAudioTime before comparison.
        static func hostTime(eventTimestampNanoseconds: UInt64) -> UInt64 {
            AudioConvertNanosToHostTime(eventTimestampNanoseconds)
        }

        static func bufferStartHostTime(
            timestamp: AVAudioTime
        ) -> UInt64? {
            timestamp.isHostTimeValid ? timestamp.hostTime : nil
        }

        /// Count samples whose timestamps are strictly before release. Host-time
        /// comparison avoids floating-point rounding at an exact sample boundary.
        static func preReleaseFrameCount(
            bufferStartHostTime: UInt64,
            releaseHostTime: UInt64,
            sampleRate: Double,
            frameLength: Int
        ) -> Int {
            guard sampleRate > 0, frameLength > 0,
                releaseHostTime > bufferStartHostTime
            else { return 0 }

            var lowerBound = 0
            var upperBound = frameLength
            while lowerBound < upperBound {
                let candidate = lowerBound + (upperBound - lowerBound) / 2
                let offset = AVAudioTime.hostTime(
                    forSeconds: Double(candidate) / sampleRate)
                let (sampleHostTime, overflow) =
                    bufferStartHostTime.addingReportingOverflow(offset)
                if !overflow, sampleHostTime < releaseHostTime {
                    lowerBound = candidate + 1
                } else {
                    upperBound = candidate
                }
            }
            return lowerBound
        }

        /// Restrict the callback-owned buffer to its pre-release prefix. The tap
        /// buffer is not retained after the callback, so reducing frameLength is
        /// sufficient; the converter observes only the retained prefix.
        static func trimToPrefix(
            _ buffer: AVAudioPCMBuffer,
            frameCount: Int
        ) -> AVAudioPCMBuffer? {
            guard frameCount > 0 else { return nil }
            let retainedFrames = min(frameCount, Int(buffer.frameLength))
            guard retainedFrames > 0 else { return nil }
            buffer.frameLength = AVAudioFrameCount(retainedFrames)
            return buffer
        }
    }
#endif
