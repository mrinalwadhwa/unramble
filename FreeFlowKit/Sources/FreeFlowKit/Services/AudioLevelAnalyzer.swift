import Foundation

/// Analyze audio levels from raw PCM data.
public enum AudioLevelAnalyzer {
    /// Compute the RMS amplitude of raw 16-bit signed little-endian
    /// PCM samples, with no WAV header.
    ///
    /// Used by the streaming provider to classify incoming audio
    /// chunks as speech or silence without round-tripping through an
    /// `AudioBuffer`. The returned value is normalized to 0.0–1.0
    /// where 1.0 represents full-scale 16-bit audio.
    public static func rmsLevel(pcm16: Data) -> Float {
        let bytesPerSample = 2
        let sampleCount = pcm16.count / bytesPerSample
        guard sampleCount > 0 else { return 0.0 }

        var sumOfSquares: Double = 0.0
        pcm16.withUnsafeBytes { rawBuffer in
            for i in 0..<sampleCount {
                let lo = UInt16(rawBuffer[i * 2])
                let hi = UInt16(rawBuffer[i * 2 + 1])
                let sample = Int16(bitPattern: lo | (hi << 8))
                let normalized = Double(sample) / 32768.0
                sumOfSquares += normalized * normalized
            }
        }

        let rms = Float(sqrt(sumOfSquares / Double(sampleCount)))
        return min(rms, 1.0)
    }
}
