import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import UnrambleKit

@Suite("Audio capture release fence")
struct AudioCaptureReleaseFenceTests {
    @Test("CG event nanoseconds convert into the AVAudio host clock")
    func eventTimestampConvertsToHostTime() {
        let eventTimestamp: UInt64 = 12_345_678_901

        #expect(
            AudioCaptureReleaseFence.hostTime(
                eventTimestampNanoseconds: eventTimestamp)
                == AudioConvertNanosToHostTime(eventTimestamp))
    }

    @Test("A release signal publishes the first physical boundary synchronously")
    func releaseSignalPublishesFirstBoundary() {
        let boundary = AudioCaptureReleaseBoundary()

        #expect(boundary.releaseHostTime == nil)
        #expect(boundary.publish(releaseHostTime: 42_000))
        #expect(!boundary.publish(releaseHostTime: 84_000))
        #expect(boundary.releaseHostTime == 42_000)
    }

    @Test("A release inside a buffer keeps only pre-release samples")
    func straddlingBufferKeepsPreReleasePrefix() {
        let start = hostTime(seconds: 100)
        let release = hostTime(seconds: 100.00425)

        let frameCount = AudioCaptureReleaseFence.preReleaseFrameCount(
            bufferStartHostTime: start,
            releaseHostTime: release,
            sampleRate: 1_000,
            frameLength: 10)

        #expect(frameCount == 5)
    }

    @Test("A release on a sample boundary excludes that sample")
    func exactBoundaryExcludesSampleAtRelease() {
        let start = hostTime(seconds: 100)
        let release = hostTime(seconds: 100.004)

        let frameCount = AudioCaptureReleaseFence.preReleaseFrameCount(
            bufferStartHostTime: start,
            releaseHostTime: release,
            sampleRate: 1_000,
            frameLength: 10)

        #expect(frameCount == 4)
    }

    @Test("Buffers entirely on either side of release are classified exactly")
    func wholeBufferClassification() {
        let release = hostTime(seconds: 100.010)

        #expect(
            AudioCaptureReleaseFence.preReleaseFrameCount(
                bufferStartHostTime: hostTime(seconds: 100),
                releaseHostTime: release,
                sampleRate: 1_000,
                frameLength: 10) == 10)
        #expect(
            AudioCaptureReleaseFence.preReleaseFrameCount(
                bufferStartHostTime: release,
                releaseHostTime: release,
                sampleRate: 1_000,
                frameLength: 10) == 0)
    }

    @Test("A callback queued before release can enter during drain and retain its prefix")
    func queuedCallbackUsesReleaseTimestamp() throws {
        let ledger = AudioCapturePublicationLedger<Int>()
        let publication = ledger.begin(1)
        let release = hostTime(seconds: 100.004)

        #expect(ledger.beginDrainingCurrentCapture(releaseHostTime: release))
        let admission = try #require(ledger.admitCallback(for: publication))

        #expect(
            ledger.preReleaseFrameCount(
                for: admission,
                bufferStartHostTime: hostTime(seconds: 100),
                sampleRate: 1_000,
                frameLength: 10) == 4)
    }

    @Test("A callback admitted before release observes a boundary that closes later")
    func admittedCallbackObservesLaterRelease() throws {
        let ledger = AudioCapturePublicationLedger<Int>()
        let publication = ledger.begin(1)
        let admission = try #require(ledger.admitCallback(for: publication))
        let release = hostTime(seconds: 100.006)

        #expect(ledger.beginDrainingCurrentCapture(releaseHostTime: release))

        #expect(
            ledger.preReleaseFrameCount(
                for: admission,
                bufferStartHostTime: hostTime(seconds: 100),
                sampleRate: 1_000,
                frameLength: 10) == 6)
    }

    @Test("A callback observes a physical release before the drain command runs")
    func callbackObservesSynchronousReleaseSignal() throws {
        let boundary = AudioCaptureReleaseBoundary()
        let ledger = AudioCapturePublicationLedger<Int>()
        let publication = ledger.begin(1, releaseBoundary: boundary)
        let admission = try #require(ledger.admitCallback(for: publication))
        let release = hostTime(seconds: 100.006)

        #expect(boundary.publish(releaseHostTime: release))

        #expect(
            ledger.preReleaseFrameCount(
                for: admission,
                bufferStartHostTime: hostTime(seconds: 100),
                sampleRate: 1_000,
                frameLength: 10) == 6)
    }

    @Test("An invalid tap timestamp retains the whole buffer rather than losing speech")
    func invalidTimestampIsLossPreserving() throws {
        let boundary = AudioCaptureReleaseBoundary()
        let ledger = AudioCapturePublicationLedger<Int>()
        let publication = ledger.begin(1, releaseBoundary: boundary)
        let admission = try #require(ledger.admitCallback(for: publication))
        #expect(boundary.publish(releaseHostTime: hostTime(seconds: 100)))

        let invalidTimestamp = AVAudioTime()
        let bufferStartHostTime = AudioCaptureReleaseFence.bufferStartHostTime(
            timestamp: invalidTimestamp)

        #expect(bufferStartHostTime == nil)
        #expect(
            ledger.preReleaseFrameCount(
                for: admission,
                bufferStartHostTime: bufferStartHostTime,
                sampleRate: 1_000,
                frameLength: 10) == 10)
    }

    @Test("Reset invalidates timestamped callback admission")
    func resetInvalidatesTimestampedAdmission() throws {
        let ledger = AudioCapturePublicationLedger<Int>()
        let publication = ledger.begin(1)
        let admission = try #require(ledger.admitCallback(for: publication))

        ledger.reset()

        #expect(
            ledger.preReleaseFrameCount(
                for: admission,
                bufferStartHostTime: hostTime(seconds: 100),
                sampleRate: 1_000,
                frameLength: 10) == nil)
    }

    @Test("Trimming a straddling PCM buffer exposes only its retained prefix")
    func trimmingBufferRetainsPrefix() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 1_000,
                channels: 1,
                interleaved: false))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10))
        buffer.frameLength = 10
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<10 {
            samples[index] = Float(index)
        }

        let retained = try #require(
            AudioCaptureReleaseFence.trimToPrefix(buffer, frameCount: 5))

        #expect(retained === buffer)
        #expect(retained.frameLength == 5)
        #expect(Array(UnsafeBufferPointer(start: samples, count: 5)) == [0, 1, 2, 3, 4])
    }

    private func hostTime(seconds: TimeInterval) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: seconds)
    }
}
