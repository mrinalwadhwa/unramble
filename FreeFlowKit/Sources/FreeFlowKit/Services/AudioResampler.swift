import Foundation

/// Resample 16-bit PCM audio between sample rates.
///
/// Used to convert the 16 kHz captured audio to 24 kHz for the OpenAI
/// Realtime API. The Realtime API requires 24 kHz mono PCM16; the app
/// captures at 16 kHz. Linear interpolation is sufficient for speech
/// transcription quality.
public enum AudioResampler {

    /// Stateful 3:2 conversion for a sequence of capture callbacks. Output
    /// samples whose interpolation depends on a later input sample are deferred
    /// until that sample arrives. `finish()` emits the final clamped sample and
    /// resets the stream for the next Realtime audio item.
    struct Stream16kTo24k: Sendable {
        private var previousSample: Int16?
        private var inputSampleCount = 0
        private var nextOutputIndex = 0

        mutating func append(_ pcm16Data: Data) -> Data {
            let sampleCount = pcm16Data.count / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { return Data() }

            var result = Data(capacity: sampleCount * 3)
            pcm16Data.withUnsafeBytes { raw in
                for offset in 0..<sampleCount {
                    let lo = UInt16(raw[offset * 2])
                    let hi = UInt16(raw[offset * 2 + 1])
                    let current = Int16(bitPattern: lo | (hi << 8))
                    let currentIndex = inputSampleCount

                    while nextOutputIndex * 2 <= currentIndex * 3 {
                        let sourceNumerator = nextOutputIndex * 2
                        let remainder = sourceNumerator % 3
                        let output: Int16
                        if remainder == 0 || previousSample == nil {
                            output = current
                        } else {
                            let fraction = Double(remainder) / 3.0
                            let interpolated = Double(previousSample!)
                                * (1.0 - fraction)
                                + Double(current) * fraction
                            let rounded = Int(interpolated.rounded())
                            output = Int16(
                                max(-32_768, min(32_767, rounded)))
                        }
                        Self.append(output, to: &result)
                        nextOutputIndex += 1
                    }

                    previousSample = current
                    inputSampleCount += 1
                }
            }
            return result
        }

        mutating func finish() -> Data {
            guard let previousSample else { return Data() }
            let outputLength = inputSampleCount == 1
                ? 1
                : (inputSampleCount * 3 + 1) / 2
            var result = Data(
                capacity: max(0, outputLength - nextOutputIndex) * 2)
            while nextOutputIndex < outputLength {
                Self.append(previousSample, to: &result)
                nextOutputIndex += 1
            }
            self.previousSample = nil
            inputSampleCount = 0
            nextOutputIndex = 0
            return result
        }

        private static func append(_ sample: Int16, to data: inout Data) {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                data.append(contentsOf: $0)
            }
        }
    }

    /// Resample 16-bit little-endian PCM from 16 kHz to 24 kHz using
    /// linear interpolation.
    ///
    /// The ratio 24000 / 16000 = 3 / 2 means every 2 input samples
    /// produce 3 output samples. Empty input yields empty output.
    /// Fewer than 2 samples pass through unchanged.
    ///
    /// - Parameter pcm16Data: 16-bit little-endian signed PCM at 16 kHz.
    /// - Returns: 16-bit little-endian signed PCM at 24 kHz.
    public static func resample16kTo24k(_ pcm16Data: Data) -> Data {
        if pcm16Data.isEmpty {
            return Data()
        }

        // Unpack 16-bit little-endian signed samples.
        let nSamples = pcm16Data.count / 2
        if nSamples < 2 {
            return pcm16Data
        }

        var samples = [Int16](repeating: 0, count: nSamples)
        pcm16Data.withUnsafeBytes { raw in
            for i in 0..<nSamples {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                samples[i] = Int16(bitPattern: lo | (hi << 8))
            }
        }

        // Resample ratio: 24000 / 16000 = 3 / 2.
        // Output length = ceil(n_samples * 3 / 2).
        let outLen = (nSamples * 3 + 1) / 2
        var output = [Int16](repeating: 0, count: outLen)

        for i in 0..<outLen {
            // Map output index back to input position.
            let src = Double(i) * 2.0 / 3.0
            let idx = Int(src)
            let frac = src - Double(idx)

            if idx >= nSamples - 1 {
                output[i] = samples[nSamples - 1]
            } else {
                // Linear interpolation between adjacent samples.
                let a = Double(samples[idx])
                let b = Double(samples[idx + 1])
                let val = a * (1.0 - frac) + b * frac
                let rounded = Int(val.rounded())
                let clamped = max(-32768, min(32767, rounded))
                output[i] = Int16(clamped)
            }
        }

        // Pack back to little-endian Data.
        var result = Data(capacity: outLen * 2)
        for sample in output {
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { result.append(contentsOf: $0) }
        }
        return result
    }
}
