import Foundation
import Testing

@testable import UnrambleKit

@Suite("AudioResampler - 16k to 24k stream")
struct AudioResamplerTests {
    @Test("known ramp preserves interpolation and deferred tail")
    func knownRamp() {
        var stream = AudioResampler.Stream16kTo24k()

        let immediate = stream.append(
            AudioResamplerOracle.pcm16([0, 300, 600, 900]))
        let tail = stream.finish()

        #expect(
            AudioResamplerOracle.samples(from: immediate)
                == [0, 200, 400, 600, 800])
        #expect(AudioResamplerOracle.samples(from: tail) == [900])
    }

    @Test("empty callbacks and an unused stream finish produce no output")
    func emptyInput() {
        var stream = AudioResampler.Stream16kTo24k()

        #expect(stream.append(Data()).isEmpty)
        #expect(stream.finish().isEmpty)
    }

    @Test("output length follows the 3:2 conversion")
    func outputLength() {
        for inputCount in [1, 2, 3, 4, 5, 10, 16_000] {
            var stream = AudioResampler.Stream16kTo24k()
            var output = stream.append(
                AudioResamplerOracle.pcm16(
                    Array(repeating: 0, count: inputCount)))
            output.append(stream.finish())

            let expectedCount = inputCount == 1
                ? 1
                : (inputCount * 3 + 1) / 2
            #expect(
                output.count / MemoryLayout<Int16>.size == expectedCount,
                "inputCount=\(inputCount)")
        }
    }

    @Test("constant signal remains constant")
    func constantSignal() {
        var stream = AudioResampler.Stream16kTo24k()
        var output = stream.append(
            AudioResamplerOracle.pcm16(
                Array(repeating: 1_234, count: 101)))
        output.append(stream.finish())

        #expect(
            AudioResamplerOracle.samples(from: output)
                == Array(repeating: 1_234, count: 152))
    }

    @Test("output is invariant to capture callback fragmentation")
    func callbackFragmentation() {
        let input: [Int16] = [
            Int16.min, -20_000, -301, 0, 300, 1_001, 20_000, Int16.max,
            12_345, -12_345, 42,
        ]
        let expected = AudioResamplerOracle.resample16kTo24k(
            AudioResamplerOracle.pcm16(input))
        let fragmentations = [
            [input.count],
            Array(repeating: 1, count: input.count),
            [1, 3, 2, 5],
            [4, 1, 1, 1, 4],
        ]

        for fragmentSizes in fragmentations {
            var stream = AudioResampler.Stream16kTo24k()
            var output = Data()
            var offset = 0
            output.append(stream.append(Data()))
            for size in fragmentSizes {
                output.append(
                    stream.append(
                        AudioResamplerOracle.pcm16(
                            Array(input[offset..<(offset + size)]))))
                offset += size
            }
            output.append(stream.finish())

            #expect(offset == input.count)
            #expect(output == expected, "fragmentSizes=\(fragmentSizes)")
        }
    }

    @Test("finish resets all interpolation state")
    func finishResetsState() {
        let inputs: [[Int16]] = [
            [0, 900, -300, 1_200],
            [Int16.max, Int16.min, 17],
        ]
        var stream = AudioResampler.Stream16kTo24k()

        for input in inputs {
            var output = stream.append(AudioResamplerOracle.pcm16(input))
            output.append(stream.finish())
            #expect(
                output
                    == AudioResamplerOracle.resample16kTo24k(
                        AudioResamplerOracle.pcm16(input)))
        }
        #expect(stream.finish().isEmpty)
    }
}
