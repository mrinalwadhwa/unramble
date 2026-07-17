import XCTest

@testable import UnrambleKit

final class WAVEncoderTests: XCTestCase {

    // MARK: - Header structure

    func testHeaderStartsWithRIFF() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let riff = String(bytes: wav[0..<4], encoding: .ascii)
        XCTAssertEqual(riff, "RIFF")
    }

    func testHeaderContainsWAVEFormat() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let wave = String(bytes: wav[8..<12], encoding: .ascii)
        XCTAssertEqual(wave, "WAVE")
    }

    func testHeaderContainsFmtSubchunk() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let fmt = String(bytes: wav[12..<16], encoding: .ascii)
        XCTAssertEqual(fmt, "fmt ")
    }

    func testHeaderContainsDataSubchunk() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let data = String(bytes: wav[36..<40], encoding: .ascii)
        XCTAssertEqual(data, "data")
    }

    func testHeaderIs44Bytes() {
        let pcm = Data()
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        // Even with no PCM data the header is 44 bytes.
        XCTAssertEqual(wav.count, 44)
    }

    // MARK: - File size fields

    func testRIFFChunkSizeMatchesFileLength() {
        let pcm = Data(repeating: 0x7F, count: 320)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let chunkSize = readLittleEndianUInt32(wav, offset: 4)
        // RIFF chunk size = total file size - 8
        XCTAssertEqual(chunkSize, UInt32(wav.count - 8))
    }

    func testDataSubchunkSizeMatchesPCMLength() {
        let pcm = Data(repeating: 0x7F, count: 500)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let dataSize = readLittleEndianUInt32(wav, offset: 40)
        XCTAssertEqual(dataSize, UInt32(pcm.count))
    }

    // MARK: - Format fields

    func testAudioFormatIsPCM() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let audioFormat = readLittleEndianUInt16(wav, offset: 20)
        XCTAssertEqual(audioFormat, 1, "Audio format 1 = PCM")
    }

    func testMonoChannelCount() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let channels = readLittleEndianUInt16(wav, offset: 22)
        XCTAssertEqual(channels, 1)
    }

    func testStereoChannelCount() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 44100, channels: 2, bitsPerSample: 16
        )

        let channels = readLittleEndianUInt16(wav, offset: 22)
        XCTAssertEqual(channels, 2)
    }

    func testSampleRate16kHz() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let sampleRate = readLittleEndianUInt32(wav, offset: 24)
        XCTAssertEqual(sampleRate, 16000)
    }

    func testSampleRate44100Hz() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 44100, channels: 2, bitsPerSample: 16
        )

        let sampleRate = readLittleEndianUInt32(wav, offset: 24)
        XCTAssertEqual(sampleRate, 44100)
    }

    func testByteRateForMono16kHz16Bit() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let byteRate = readLittleEndianUInt32(wav, offset: 28)
        // byteRate = sampleRate * channels * bitsPerSample / 8
        XCTAssertEqual(byteRate, 16000 * 1 * 2)
    }

    func testByteRateForStereo44100Hz16Bit() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 44100, channels: 2, bitsPerSample: 16
        )

        let byteRate = readLittleEndianUInt32(wav, offset: 28)
        XCTAssertEqual(byteRate, 44100 * 2 * 2)
    }

    func testBlockAlignMono16Bit() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let blockAlign = readLittleEndianUInt16(wav, offset: 32)
        XCTAssertEqual(blockAlign, 2)
    }

    func testBlockAlignStereo16Bit() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 44100, channels: 2, bitsPerSample: 16
        )

        let blockAlign = readLittleEndianUInt16(wav, offset: 32)
        XCTAssertEqual(blockAlign, 4)
    }

    func testBitsPerSample16() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let bps = readLittleEndianUInt16(wav, offset: 34)
        XCTAssertEqual(bps, 16)
    }

    func testFmtSubchunkSizeIs16ForPCM() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let fmtSize = readLittleEndianUInt32(wav, offset: 16)
        XCTAssertEqual(fmtSize, 16)
    }

    // MARK: - PCM data integrity

    func testPCMDataFollowsHeader() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let payload = wav.subdata(in: 44..<wav.count)
        XCTAssertEqual(payload, pcm)
    }

    func testTotalSizeIsHeaderPlusPCM() {
        let pcm = Data(repeating: 0xAB, count: 1024)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        XCTAssertEqual(wav.count, 44 + 1024)
    }

    func testEmptyPCMProducesHeaderOnly() {
        let wav = WAVEncoder.encode(
            pcmData: Data(), sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        XCTAssertEqual(wav.count, 44)

        let dataSize = readLittleEndianUInt32(wav, offset: 40)
        XCTAssertEqual(dataSize, 0)
    }

    func testLargePCMDataPreserved() {
        // 5 seconds at 16kHz mono 16-bit = 160,000 bytes
        let byteCount = 16000 * 2 * 5
        let pcm = Data(repeating: 0x42, count: byteCount)
        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        XCTAssertEqual(wav.count, 44 + byteCount)
        let payload = wav.subdata(in: 44..<wav.count)
        XCTAssertEqual(payload, pcm)
    }

    // MARK: - Duration calculation

    func testDurationOneSecondMono16kHz16Bit() {
        // 1 second = 16000 samples * 2 bytes = 32000 bytes
        let duration = WAVEncoder.duration(
            byteCount: 32000, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )
        XCTAssertEqual(duration, 1.0, accuracy: 0.001)
    }

    func testDurationHalfSecond() {
        let duration = WAVEncoder.duration(
            byteCount: 16000, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )
        XCTAssertEqual(duration, 0.5, accuracy: 0.001)
    }

    func testDurationZeroBytes() {
        let duration = WAVEncoder.duration(
            byteCount: 0, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )
        XCTAssertEqual(duration, 0.0)
    }

    func testDurationStereo44100Hz() {
        // 1 second stereo 44100Hz 16-bit = 44100 * 2 * 2 = 176400 bytes
        let duration = WAVEncoder.duration(
            byteCount: 176400, sampleRate: 44100, channels: 2, bitsPerSample: 16
        )
        XCTAssertEqual(duration, 1.0, accuracy: 0.001)
    }

    func testDurationFiveSeconds() {
        let byteCount = 16000 * 2 * 5
        let duration = WAVEncoder.duration(
            byteCount: byteCount, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )
        XCTAssertEqual(duration, 5.0, accuracy: 0.001)
    }

    func testDurationFractionalSeconds() {
        // 0.75 seconds = 12000 samples * 2 bytes = 24000 bytes
        let duration = WAVEncoder.duration(
            byteCount: 24000, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )
        XCTAssertEqual(duration, 0.75, accuracy: 0.001)
    }

    // MARK: - Round-trip consistency

    func testEncodedDurationMatchesCalculatedDuration() {
        // 2.5 seconds of 16kHz mono 16-bit
        let sampleCount = 40000
        let byteCount = sampleCount * 2
        let pcm = Data(repeating: 0, count: byteCount)

        let calculatedDuration = WAVEncoder.duration(
            byteCount: byteCount, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        let wav = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        // Verify the data sub-chunk size matches
        let dataSize = readLittleEndianUInt32(wav, offset: 40)
        let durationFromWAV = WAVEncoder.duration(
            byteCount: Int(dataSize), sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        XCTAssertEqual(calculatedDuration, 2.5, accuracy: 0.001)
        XCTAssertEqual(durationFromWAV, calculatedDuration, accuracy: 0.001)
    }

    func testMultipleEncodesProduceIdenticalOutput() {
        let pcm = Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60])

        let wav1 = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )
        let wav2 = WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16
        )

        XCTAssertEqual(wav1, wav2)
    }

    // MARK: - Helpers

    private func readLittleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            $0.load(as: UInt16.self).littleEndian
        }
    }

    private func readLittleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
    }
}
