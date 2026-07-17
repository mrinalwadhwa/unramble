import AVFoundation
import Foundation
import Testing

@testable import UnrambleKit

@Suite("Dictation audio sink")
struct DictationAudioSinkTests {
    @Test("RMS includes speech present only in the right channel")
    func rmsIncludesRightChannelSpeech() throws {
        let format = try makeFormat(sampleRate: 48_000, channelCount: 2)
        let sink = try DictationAudioSink(
            inputFormat: format,
            micProximity: .nearField,
            deviceName: "Stereo Test Mic")
        defer { sink.discard() }

        let amplitude: Float = 0.4
        sink.consume(
            try makePlanarBuffer(
                format: format,
                frameCount: 480,
                channelValues: [0, amplitude]))

        let expectedRMS = amplitude / sqrtf(2)
        #expect(abs(sink.metrics.peakRMS - expectedRMS) < 0.000_001)
    }

    @Test("Ambient calibration uses half a second of native 48 kHz frames")
    func ambientCalibrationUsesInputSampleRate() throws {
        let format = try makeFormat(sampleRate: 48_000, channelCount: 1)
        let sink = try DictationAudioSink(
            inputFormat: format,
            micProximity: .nearField,
            deviceName: "48 kHz Test Mic")
        defer { sink.discard() }

        let amplitude: Float = 0.2
        sink.consume(
            try makePlanarBuffer(
                format: format,
                frameCount: 8_000,
                channelValues: [amplitude]))
        #expect(sink.metrics.ambientRMS == 0)

        sink.consume(
            try makePlanarBuffer(
                format: format,
                frameCount: 15_999,
                channelValues: [amplitude]))
        #expect(sink.metrics.ambientRMS == 0)

        sink.consume(
            try makePlanarBuffer(
                format: format,
                frameCount: 1,
                channelValues: [amplitude]))
        #expect(abs(sink.metrics.ambientRMS - amplitude) < 0.000_001)
    }

    @Test("A conversion failure cannot return earlier PCM as intact")
    func conversionFailurePublishesIntegrity() throws {
        let format = try makeFormat(sampleRate: 48_000, channelCount: 1)
        let converter = TestPCMConverter(
            consumeResults: [
                .success(Data([1, 0, 2, 0])),
                .failure(.consume),
            ],
            finishResult: .failure(.finish))
        let sink = try DictationAudioSink(
            inputFormat: format,
            micProximity: .nearField,
            deviceName: "Failure Test Mic",
            makeConverter: { _, _ in converter })

        sink.consume(
            try makePlanarBuffer(
                format: format,
                frameCount: 480,
                channelValues: [0.2]))
        sink.consume(
            try makePlanarBuffer(
                format: format,
                frameCount: 240,
                channelValues: [0.3]))
        let completion = sink.finishWithIntegrity()

        #expect(!completion.buffer.data.isEmpty)
        #expect(
            completion.integrityFailure
                == AudioCaptureIntegrityFailure(
                    stage: .pcmConversion,
                    affectedFrameCount: 240))
    }

    @Test("A converter tail failure cannot return body PCM as intact")
    func tailDrainFailurePublishesIntegrity() throws {
        let format = try makeFormat(sampleRate: 48_000, channelCount: 1)
        let converter = TestPCMConverter(
            consumeResults: [.success(Data([1, 0, 2, 0]))],
            finishResult: .failure(.finish))
        let sink = try DictationAudioSink(
            inputFormat: format,
            micProximity: .nearField,
            deviceName: "Failure Test Mic",
            makeConverter: { _, _ in converter })

        sink.consume(
            try makePlanarBuffer(
                format: format,
                frameCount: 480,
                channelValues: [0.2]))
        let completion = sink.finishWithIntegrity()

        #expect(!completion.buffer.data.isEmpty)
        #expect(
            completion.integrityFailure
                == AudioCaptureIntegrityFailure(
                    stage: .converterDrain,
                    affectedFrameCount: nil))
    }

    @Test("A blocked converter tail remains owned after the stop deadline")
    func blockedTailRemainsOwnedAfterDeadline() async throws {
        let format = try makeFormat(sampleRate: 48_000, channelCount: 1)
        let converter = BlockingFinishPCMConverter()
        let sink = try DictationAudioSink(
            inputFormat: format,
            micProximity: .nearField,
            deviceName: "Blocked Tail Test Mic",
            makeConverter: { _, _ in converter })
        sink.consume(
            try makePlanarBuffer(
                format: format,
                frameCount: 480,
                channelValues: [0.2]))

        let drain = AudioCaptureStopDrain<DictationAudioSink.Completion>(
            observeRelease: { true },
            finalize: { sink.finishWithIntegrity() })
        let observation = await drain.outcome(timeout: 0.01)

        guard case .deadline = observation else {
            Issue.record("Expected blocked converter tail to hit the deadline")
            converter.releaseFinish()
            return
        }
        #expect(converter.waitUntilFinishEntered())
        #expect(drain.timeoutFailure.stage == .converterDrain)

        converter.releaseFinish()
        guard case .finalized(let completion) = await drain.task.value else {
            Issue.record("Expected retained converter tail to finish")
            return
        }
        #expect(!completion.buffer.data.isEmpty)
        #expect(completion.integrityFailure == nil)
    }

    private func makeFormat(
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) throws -> AVAudioFormat {
        try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false))
    }

    private func makePlanarBuffer(
        format: AVAudioFormat,
        frameCount: Int,
        channelValues: [Float]
    ) throws -> AVAudioPCMBuffer {
        #expect(channelValues.count == Int(format.channelCount))
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channels = try #require(buffer.floatChannelData)
        for channel in channelValues.indices {
            for frame in 0..<frameCount {
                channels[channel][frame] = channelValues[channel]
            }
        }
        return buffer
    }
}

private final class TestPCMConverter: DictationPCMConverting, @unchecked Sendable {
    enum Failure: Error {
        case consume
        case finish
    }

    private let lock = NSLock()
    private var consumeResults: [Result<Data, Failure>]
    private let finishResult: Result<Data, Failure>

    init(
        consumeResults: [Result<Data, Failure>],
        finishResult: Result<Data, Failure>
    ) {
        self.consumeResults = consumeResults
        self.finishResult = finishResult
    }

    func begin() throws {}

    func consume(_ input: AVAudioPCMBuffer) throws -> Data {
        try lock.withLock {
            guard !consumeResults.isEmpty else { return Data() }
            return try consumeResults.removeFirst().get()
        }
    }

    func finish() throws -> Data {
        try finishResult.get()
    }

    func discard() {}
}

private final class BlockingFinishPCMConverter:
    DictationPCMConverting,
    @unchecked Sendable
{
    private let finishEntered = DispatchSemaphore(value: 0)
    private let finishRelease = DispatchSemaphore(value: 0)

    func begin() throws {}

    func consume(_ input: AVAudioPCMBuffer) throws -> Data {
        Data([1, 0])
    }

    func finish() throws -> Data {
        finishEntered.signal()
        finishRelease.wait()
        return Data([2, 0])
    }

    func discard() {}

    func waitUntilFinishEntered() -> Bool {
        finishEntered.wait(timeout: .now() + 1) == .success
    }

    func releaseFinish() {
        finishRelease.signal()
    }
}
