import Foundation
import Testing

@testable import FreeFlowKit

@Suite("WAV fixture parsing")
struct WAVFixtureTests {

    @Test("extracts PCM after metadata instead of assuming a 44-byte header")
    func metadataChunkBeforeAudio() throws {
        let url = try #require(WAVFixture.audioURL(named: "meeting-10efb8de"))
        let original = try Data(contentsOf: url)
        let fixture = try WAVFixture(data: original)

        #expect(fixture.dataOffset == 78)
        #expect(fixture.pcm.count == 382_400)
        #expect(fixture.sampleRate == 16_000)
        #expect(fixture.channels == 1)
        #expect(fixture.bitsPerSample == 16)
        #expect(fixture.duration == 11.95)
        #expect(fixture.canonicalWAV.count == fixture.pcm.count + WAVEncoder.headerSize)
        #expect(
            fixture.canonicalWAV.subdata(
                in: WAVEncoder.headerSize..<fixture.canonicalWAV.count)
                == fixture.pcm)
    }

    @Test("honors odd-sized RIFF chunk padding")
    func oddChunkPadding() throws {
        let pcm = Data([1, 0, 2, 0])
        let wav = makeWAVWithOddMetadata(pcm: pcm)

        let fixture = try WAVFixture(data: wav)

        #expect(fixture.pcm == pcm)
        #expect(fixture.dataOffset == 54)
    }

    private func makeWAVWithOddMetadata(pcm: Data) -> Data {
        var body = Data("WAVE".utf8)
        appendChunk(
            id: "fmt ",
            payload: littleEndian(UInt16(1))
                + littleEndian(UInt16(1))
                + littleEndian(UInt32(16_000))
                + littleEndian(UInt32(32_000))
                + littleEndian(UInt16(2))
                + littleEndian(UInt16(16)),
            to: &body)
        appendChunk(id: "JUNK", payload: Data([0xA5]), to: &body)
        appendChunk(id: "data", payload: pcm, to: &body)

        var wav = Data("RIFF".utf8)
        wav.append(littleEndian(UInt32(body.count)))
        wav.append(body)
        return wav
    }

    private func appendChunk(id: String, payload: Data, to data: inout Data) {
        data.append(Data(id.utf8))
        data.append(littleEndian(UInt32(payload.count)))
        data.append(payload)
        if !payload.count.isMultiple(of: 2) {
            data.append(0)
        }
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
