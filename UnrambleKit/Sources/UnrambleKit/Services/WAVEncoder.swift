import Foundation

/// Encode raw PCM audio samples into WAV format.
///
/// Produces a complete WAV file (RIFF header + raw PCM data) suitable
/// for APIs that accept WAV input.
enum WAVEncoder {

    /// Encode raw PCM data into a WAV file.
    ///
    /// - Parameters:
    ///   - pcmData: Raw PCM audio samples (little-endian).
    ///   - sampleRate: Sample rate in Hz (e.g. 16000).
    ///   - channels: Number of audio channels (1 for mono, 2 for stereo).
    ///   - bitsPerSample: Bits per sample (e.g. 16).
    /// - Returns: Complete WAV file data with a 44-byte RIFF header.
    /// Size of the standard 44-byte RIFF/WAV header.
    static let headerSize = 44

    /// Maximum PCM data size that fits in a WAV file (4 GB minus header).
    static let maxDataSize = Int(UInt32.max) - headerSize

    static func encode(
        pcmData: Data,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> Data {
        precondition(
            pcmData.count <= maxDataSize,
            "PCM data exceeds WAV format limit (~4 GB)")

        let headerSize = Self.headerSize
        let dataSize = pcmData.count
        let fileSize = headerSize + dataSize

        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var header = Data(capacity: headerSize)

        // RIFF chunk descriptor
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
        header.appendLittleEndianUInt32(UInt32(fileSize - 8))  // File size minus 8
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"

        // fmt sub-chunk
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
        header.appendLittleEndianUInt32(16)  // Sub-chunk size (PCM = 16)
        header.appendLittleEndianUInt16(1)  // Audio format (PCM = 1)
        header.appendLittleEndianUInt16(UInt16(channels))
        header.appendLittleEndianUInt32(UInt32(sampleRate))
        header.appendLittleEndianUInt32(UInt32(byteRate))
        header.appendLittleEndianUInt16(UInt16(blockAlign))
        header.appendLittleEndianUInt16(UInt16(bitsPerSample))

        // data sub-chunk
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
        header.appendLittleEndianUInt32(UInt32(dataSize))

        var result = header
        result.append(pcmData)
        return result
    }

    /// Calculate the duration in seconds for the given PCM data.
    ///
    /// - Parameters:
    ///   - byteCount: Number of bytes of raw PCM data.
    ///   - sampleRate: Sample rate in Hz.
    ///   - channels: Number of audio channels.
    ///   - bitsPerSample: Bits per sample.
    /// - Returns: Duration in seconds.
    static func duration(
        byteCount: Int,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> TimeInterval {
        let bytesPerSample = bitsPerSample / 8
        let totalSamples = byteCount / (bytesPerSample * channels)
        return TimeInterval(totalSamples) / TimeInterval(sampleRate)
    }
}

// MARK: - Data helpers for little-endian writes

extension Data {

    fileprivate mutating func appendLittleEndianUInt16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendLittleEndianUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
