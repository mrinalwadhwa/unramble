import Foundation

/// Analyze audio levels from raw PCM data.
public enum AudioLevelAnalyzer {
    /// Lowest RMS that the capture policy may accept as speech. Realtime pause
    /// detection must never use a higher threshold, or accepted quiet speech
    /// could be mistaken for a safe commit boundary.
    static let minimumAcceptedSpeechRMS: Float = 0.0005

    /// Measure trailing silence without treating a mixed callback as one
    /// indivisible speech/silence decision. Windows are scanned from the end;
    /// the window containing the last detected speech is conservatively counted
    /// as speech, so silence can be under-counted by at most one window but is
    /// never over-counted past detected speech.
    static func trailingSilenceByteCount(
        pcm16: Data,
        threshold: Float,
        windowSampleCount: Int = 320
    ) -> Int {
        precondition(windowSampleCount > 0)
        guard pcm16.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            return 0
        }

        let sampleCount = pcm16.count / MemoryLayout<Int16>.size
        var windowEnd = sampleCount
        var silentSampleCount = 0

        while windowEnd > 0 {
            let windowStart = max(0, windowEnd - windowSampleCount)
            let byteStart = windowStart * MemoryLayout<Int16>.size
            let byteEnd = windowEnd * MemoryLayout<Int16>.size
            let byteRange = byteStart..<byteEnd
            if rmsLevel(pcm16: pcm16.subdata(in: byteRange)) > threshold {
                return silentSampleCount * MemoryLayout<Int16>.size
            }
            silentSampleCount += windowEnd - windowStart
            windowEnd = windowStart
        }

        return pcm16.count
    }

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
