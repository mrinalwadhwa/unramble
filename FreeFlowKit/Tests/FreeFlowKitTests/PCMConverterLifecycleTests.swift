import AVFoundation
import Foundation
import Testing

@testable import FreeFlowKit

@Suite("PCM converter session lifecycle")
struct PCMConverterLifecycleTests {
    @Test("Finishing a session returns the converter's buffered tail")
    func finishReturnsBufferedTail() throws {
        let formats = try makeFormats()
        let lifecycle = PCMConverterLifecycle(
            inputFormat: formats.input,
            outputFormat: formats.output
        )

        try lifecycle.begin()
        let body = try lifecycle.consume(
            makeInputBuffer(format: formats.input, seed: 1)
        )
        let tail = try lifecycle.finish()

        #expect(!body.isEmpty)
        #expect(!tail.isEmpty)
    }

    @Test("A completed session cannot contaminate the next session")
    func completedSessionDoesNotContaminateReplacement() throws {
        let formats = try makeFormats()
        let reused = PCMConverterLifecycle(
            inputFormat: formats.input,
            outputFormat: formats.output
        )

        try reused.begin()
        _ = try reused.consume(
            makeInputBuffer(format: formats.input, seed: 1)
        )
        _ = try reused.finish()

        try reused.begin()
        var reusedB = try reused.consume(
            makeInputBuffer(format: formats.input, seed: 2)
        )
        reusedB.append(try reused.finish())

        let fresh = PCMConverterLifecycle(
            inputFormat: formats.input,
            outputFormat: formats.output
        )
        try fresh.begin()
        var freshB = try fresh.consume(
            makeInputBuffer(format: formats.input, seed: 2)
        )
        freshB.append(try fresh.finish())

        #expect(reusedB == freshB)
    }

    @Test("Discard makes buffered tail unavailable")
    func discardDoesNotEmitBufferedTail() throws {
        let formats = try makeFormats()
        let lifecycle = PCMConverterLifecycle(
            inputFormat: formats.input,
            outputFormat: formats.output
        )

        try lifecycle.begin()
        _ = try lifecycle.consume(
            makeInputBuffer(format: formats.input, seed: 1)
        )
        lifecycle.discard()

        #expect(throws: PCMConverterLifecycle.LifecycleError.self) {
            try lifecycle.finish()
        }
    }

    @Test("A trimmed straddling buffer converts exactly like a standalone prefix")
    func trimmedBufferConvertsOnlyRetainedPrefix() throws {
        let formats = try makeFormats()
        let retainedFrames = 2_048
        let straddling = try makeInputBuffer(
            format: formats.input,
            seed: 3,
            frameCount: 4_097)
        let trimmed = try #require(
            AudioCaptureReleaseFence.trimToPrefix(
                straddling,
                frameCount: retainedFrames))

        let trimmedLifecycle = PCMConverterLifecycle(
            inputFormat: formats.input,
            outputFormat: formats.output)
        try trimmedLifecycle.begin()
        var trimmedBytes = try trimmedLifecycle.consume(trimmed)
        trimmedBytes.append(try trimmedLifecycle.finish())

        let prefixLifecycle = PCMConverterLifecycle(
            inputFormat: formats.input,
            outputFormat: formats.output)
        try prefixLifecycle.begin()
        var prefixBytes = try prefixLifecycle.consume(
            makeInputBuffer(
                format: formats.input,
                seed: 3,
                frameCount: AVAudioFrameCount(retainedFrames)))
        prefixBytes.append(try prefixLifecycle.finish())

        #expect(!trimmedBytes.isEmpty)
        #expect(trimmedBytes == prefixBytes)
    }

    private func makeFormats() throws -> (
        input: AVAudioFormat,
        output: AVAudioFormat
    ) {
        let input = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let output = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        return (input, output)
    }

    private func makeInputBuffer(
        format: AVAudioFormat,
        seed: Int,
        frameCount: AVAudioFrameCount = 4_097
    ) throws -> AVAudioPCMBuffer {
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])

        for frame in 0..<Int(frameCount) {
            let position = Float(frame + seed * 97)
            samples[frame] = sin(position * 0.031) * 0.7
        }
        return buffer
    }
}
