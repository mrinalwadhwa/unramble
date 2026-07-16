import Foundation

@testable import FreeFlowKit

enum LocalRecognitionFixtureSupport {
    enum Failure: Error, Equatable {
        case unsupportedSampleRate(Int)
        case unsupportedChannelCount(Int)
        case unsupportedBitsPerSample(Int)
        case invalidPieceCount(Int)
    }

    static func recognize(
        wavData: Data,
        using recognizer: any LocalStreamingRecognizer,
        pieces: Int = 1
    ) throws -> String {
        try recognize(
            fixture: WAVFixture(data: wavData),
            using: recognizer,
            pieces: pieces)
    }

    static func recognize(
        fixture: WAVFixture,
        using recognizer: any LocalStreamingRecognizer,
        pieces: Int = 1
    ) throws -> String {
        guard fixture.sampleRate == 16_000 else {
            throw Failure.unsupportedSampleRate(fixture.sampleRate)
        }
        guard fixture.channels == 1 else {
            throw Failure.unsupportedChannelCount(fixture.channels)
        }
        guard fixture.bitsPerSample == 16 else {
            throw Failure.unsupportedBitsPerSample(fixture.bitsPerSample)
        }
        guard pieces > 0 else {
            throw Failure.invalidPieceCount(pieces)
        }

        let samples = normalizedSamples(fromLittleEndianPCM: fixture.pcm)
        let session = try recognizer.makeRecognitionSession()
        guard !samples.isEmpty else { return try session.finish() }

        let chunkSize = max(
            1,
            samples.count / pieces + (samples.count.isMultiple(of: pieces) ? 0 : 1))
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            try session.feed(Array(samples[offset..<end]))
            offset = end
        }
        return try session.finish()
    }

    private static func normalizedSamples(
        fromLittleEndianPCM pcm: Data
    ) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(pcm.count / MemoryLayout<Int16>.size)
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let next = pcm.index(after: offset)
            let bitPattern = UInt16(pcm[offset]) | UInt16(pcm[next]) << 8
            samples.append(Float(Int16(bitPattern: bitPattern)) / 32_768)
            offset = pcm.index(after: next)
        }
        return samples
    }
}
