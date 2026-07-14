import Foundation

@testable import FreeFlowKit

/// RIFF-aware WAV fixture reader. Test fixtures may contain metadata chunks,
/// so their PCM payload does not necessarily start after a 44-byte header.
struct WAVFixture: Sendable {
    enum Failure: Error, Equatable {
        case truncatedHeader
        case invalidContainer
        case truncatedChunk(id: String)
        case missingFormat
        case missingAudio
        case unsupportedFormat(UInt16)
        case invalidFormat
        case unalignedAudio(byteCount: Int, blockAlign: Int)
    }

    let pcm: Data
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let dataOffset: Int

    var duration: TimeInterval {
        WAVEncoder.duration(
            byteCount: pcm.count,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample)
    }

    var canonicalWAV: Data {
        WAVEncoder.encode(
            pcmData: pcm,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample)
    }

    init(data: Data) throws {
        guard data.count >= 12 else { throw Failure.truncatedHeader }
        guard Self.fourCC(in: data, at: 0) == "RIFF",
            Self.fourCC(in: data, at: 8) == "WAVE"
        else {
            throw Failure.invalidContainer
        }

        var format: (sampleRate: Int, channels: Int, bits: Int, blockAlign: Int)?
        var audio: (range: Range<Int>, offset: Int)?
        var cursor = 12

        while cursor <= data.count - 8 {
            let id = Self.fourCC(in: data, at: cursor)
            let size = Int(Self.uint32(in: data, at: cursor + 4))
            let payloadStart = cursor + 8
            guard size <= data.count - payloadStart else {
                throw Failure.truncatedChunk(id: id)
            }
            let payloadEnd = payloadStart + size

            if id == "fmt " {
                guard size >= 16 else { throw Failure.invalidFormat }
                let audioFormat = Self.uint16(in: data, at: payloadStart)
                guard audioFormat == 1 else {
                    throw Failure.unsupportedFormat(audioFormat)
                }
                let channels = Int(Self.uint16(in: data, at: payloadStart + 2))
                let sampleRate = Int(Self.uint32(in: data, at: payloadStart + 4))
                let blockAlign = Int(Self.uint16(in: data, at: payloadStart + 12))
                let bits = Int(Self.uint16(in: data, at: payloadStart + 14))
                guard channels > 0, sampleRate > 0, bits > 0,
                    bits.isMultiple(of: 8),
                    blockAlign == channels * bits / 8
                else {
                    throw Failure.invalidFormat
                }
                format = (sampleRate, channels, bits, blockAlign)
            } else if id == "data", audio == nil {
                audio = (payloadStart..<payloadEnd, payloadStart)
            }

            let paddedSize = size + (size.isMultiple(of: 2) ? 0 : 1)
            guard paddedSize <= data.count - payloadStart else {
                throw Failure.truncatedChunk(id: id)
            }
            cursor = payloadStart + paddedSize
        }

        guard let format else { throw Failure.missingFormat }
        guard let audio else { throw Failure.missingAudio }
        guard audio.range.count.isMultiple(of: format.blockAlign) else {
            throw Failure.unalignedAudio(
                byteCount: audio.range.count,
                blockAlign: format.blockAlign)
        }

        pcm = data.subdata(in: audio.range)
        sampleRate = format.sampleRate
        channels = format.channels
        bitsPerSample = format.bits
        dataOffset = audio.offset
    }

    static func audioURL(named name: String) -> URL? {
        let testDirectory = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
        let url = testDirectory
            .appendingPathComponent("Fixtures/audio")
            .appendingPathComponent("\(name).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func fourCC(in data: Data, at offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func uint16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset])
            | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
