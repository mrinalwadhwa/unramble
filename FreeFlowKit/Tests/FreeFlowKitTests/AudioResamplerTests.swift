import Foundation
import Testing

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Tests for the 16 kHz → 24 kHz linear interpolation resampler. The
// resampler takes 16-bit little-endian PCM and produces 16-bit LE PCM
// with 3 output samples for every 2 input samples.
// ---------------------------------------------------------------------------

@Suite("AudioResampler – 16k to 24k")
struct AudioResamplerTests {

    /// Pack an array of Int16 samples into little-endian Data.
    private func pack(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            data.append(contentsOf: withUnsafeBytes(of: s.littleEndian) { Array($0) })
        }
        return data
    }

    /// Unpack little-endian Data into an array of Int16 samples.
    private func unpack(_ data: Data) -> [Int16] {
        precondition(data.count % 2 == 0)
        var samples: [Int16] = []
        samples.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Int16.self)
            for i in 0..<buf.count {
                samples.append(Int16(littleEndian: buf[i]))
            }
        }
        return samples
    }

    @Test("empty input returns empty output")
    func emptyInput() {
        let result = AudioResampler.resample16kTo24k(Data())
        #expect(result.isEmpty)
    }

    @Test("single sample returns unchanged data")
    func singleSample() {
        // Less than 2 samples → passthrough.
        let input = pack([42])
        let result = AudioResampler.resample16kTo24k(input)
        #expect(result == input)
    }

    @Test("2 input samples produce 3 output samples")
    func twoInputSamples() {
        // Ratio 3:2 → ceil(2*3/2) = 3 output samples.
        let input = pack([0, 1000])
        let result = AudioResampler.resample16kTo24k(input)
        let samples = unpack(result)
        #expect(samples.count == 3)
    }

    @Test("4 input samples produce 6 output samples")
    func fourInputSamples() {
        let input = pack([0, 100, 200, 300])
        let result = AudioResampler.resample16kTo24k(input)
        let samples = unpack(result)
        #expect(samples.count == 6)
    }

    @Test("output length follows ceil(n * 3 / 2)")
    func outputLength() {
        for n in [2, 3, 5, 10, 100, 1000, 1001] {
            let input = pack(Array(repeating: Int16(0), count: n))
            let result = AudioResampler.resample16kTo24k(input)
            let expected = (n * 3 + 1) / 2
            let actual = result.count / 2
            #expect(actual == expected, "n=\(n): expected \(expected), got \(actual)")
        }
    }

    @Test("constant signal yields same constant")
    func constantSignal() {
        let value: Int16 = 1234
        let input = pack(Array(repeating: value, count: 10))
        let result = AudioResampler.resample16kTo24k(input)
        let samples = unpack(result)
        for sample in samples {
            #expect(sample == value)
        }
    }

    @Test("linear ramp interpolates correctly")
    func linearRamp() {
        // Input:  0, 300, 600, 900 (16 kHz)
        // Output indices map to input positions 0, 2/3, 4/3, 2, 8/3, 10/3
        // Output: 0, 200, 400, 600, 800 (clamped to available), ...
        let input = pack([0, 300, 600, 900])
        let result = AudioResampler.resample16kTo24k(input)
        let samples = unpack(result)
        #expect(samples.count == 6)
        // Each output sample is a linear interpolation between two
        // adjacent input samples. Allow ±1 for rounding.
        #expect(abs(samples[0] - 0) <= 1)
        #expect(abs(samples[1] - 200) <= 1)
        #expect(abs(samples[2] - 400) <= 1)
        #expect(abs(samples[3] - 600) <= 1)
        #expect(abs(samples[4] - 800) <= 1)
        // Last sample may clamp to last input (index >= n-1).
    }

    @Test("negative samples pass through")
    func negativeSamples() {
        let input = pack([-1000, -2000, -3000, -4000])
        let result = AudioResampler.resample16kTo24k(input)
        let samples = unpack(result)
        #expect(samples.count == 6)
        // First sample should be -1000.
        #expect(abs(samples[0] - (-1000)) <= 1)
        // All samples should be negative.
        for sample in samples {
            #expect(sample <= 0)
        }
    }

    @Test("clamps to Int16 range")
    func clampsToInt16() {
        // Extreme values to verify no overflow.
        let input = pack([Int16.max, Int16.min, Int16.max, Int16.min])
        let result = AudioResampler.resample16kTo24k(input)
        let samples = unpack(result)
        for sample in samples {
            #expect(sample >= Int16.min)
            #expect(sample <= Int16.max)
        }
    }

    @Test("odd byte count: last byte ignored")
    func oddByteCount() {
        // 5 bytes = 2 full samples + 1 stray byte.
        var input = pack([100, 200])
        input.append(0xFF)
        let result = AudioResampler.resample16kTo24k(input)
        // Should process 2 samples → 3 output samples.
        #expect(result.count == 6)
    }

    @Test("1 second of silence")
    func oneSecondSilence() {
        // 16000 samples at 16 kHz → 24000 samples at 24 kHz.
        let input = pack(Array(repeating: Int16(0), count: 16000))
        let result = AudioResampler.resample16kTo24k(input)
        #expect(result.count == 24000 * 2)
    }

    @Test("100 ms of signal at realistic size")
    func hundredMs() {
        // 1600 samples in, 2400 samples out.
        let samples: [Int16] = (0..<1600).map { Int16($0 % 1000) }
        let input = pack(samples)
        let result = AudioResampler.resample16kTo24k(input)
        #expect(result.count == 2400 * 2)
    }

    @Test("streaming output is invariant to callback fragmentation")
    func streamingFragmentation() {
        let fragments: [[Int16]] = [
            [0],
            [300, 600, 900],
            [1_200, 1_500],
            [1_800, 2_100, 2_400, 2_700],
        ]
        var stream = AudioResampler.Stream16kTo24k()
        var streamed = Data()
        for fragment in fragments {
            streamed.append(stream.append(pack(fragment)))
        }
        streamed.append(stream.finish())

        let complete = fragments.flatMap { $0 }
        #expect(streamed == AudioResampler.resample16kTo24k(pack(complete)))
        #expect(stream.finish().isEmpty)
    }
}
