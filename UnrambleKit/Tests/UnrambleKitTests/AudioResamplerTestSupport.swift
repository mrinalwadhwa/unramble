import Foundation

enum AudioResamplerOracle {
    static func pcm16(_ samples: [Int16]) -> Data {
        samples.reduce(into: Data(capacity: samples.count * 2)) { data, sample in
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                data.append(contentsOf: $0)
            }
        }
    }

    static func samples(from data: Data) -> [Int16] {
        let sampleCount = data.count / 2
        return data.withUnsafeBytes { raw in
            (0..<sampleCount).map { index in
                let lo = UInt16(raw[index * 2])
                let hi = UInt16(raw[index * 2 + 1])
                return Int16(bitPattern: lo | (hi << 8))
            }
        }
    }

    /// Independent, random-access reference for the production streaming
    /// resampler. Keeping this in the test target avoids a second production
    /// implementation while preserving an oracle for callback fragmentation.
    static func resample16kTo24k(_ pcm16Data: Data) -> Data {
        let input = samples(from: pcm16Data)
        guard let last = input.last else { return Data() }

        let outputCount = input.count == 1
            ? 1
            : (input.count * 3 + 1) / 2
        let output: [Int16] = (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * 2.0 / 3.0
            let lowerIndex = Int(sourcePosition)
            guard lowerIndex < input.count - 1 else { return last }

            let fraction = sourcePosition - Double(lowerIndex)
            let interpolated = Double(input[lowerIndex]) * (1.0 - fraction)
                + Double(input[lowerIndex + 1]) * fraction
            return Int16(max(-32_768, min(32_767, Int(interpolated.rounded()))))
        }
        return pcm16(output)
    }
}
