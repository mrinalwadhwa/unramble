import Foundation
import Testing

@testable import UnrambleKit

// MARK: - Gain factor computation

@Suite("Software gain factor computation")
struct GainFactorTests {

    @Test("Far-field mic with typical built-in ambient computes correct gain")
    func farFieldTypicalAmbient() {
        // Built-in mic ambient is ~0.001. Target is 0.02.
        // Expected gain: 0.02 / 0.001 = 20.0, clamped to 16.0.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.001,
            micProximity: .farField
        )
        #expect(gain == 16.0)
    }

    @Test("Far-field mic with moderate ambient computes unclamped gain")
    func farFieldModerateAmbient() {
        // Ambient 0.002. Target 0.02. Expected: 0.02 / 0.002 ≈ 10.0.
        // Float32 division may produce 9.999999 instead of 10.0 exactly.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.002,
            micProximity: .farField
        )
        #expect(abs(gain - 10.0) < 0.001)
    }

    @Test("Far-field mic with high ambient produces low gain")
    func farFieldHighAmbient() {
        // Ambient 0.005 (fan blowing on laptop). Target 0.02.
        // Expected: 0.02 / 0.005 = 4.0.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.005,
            micProximity: .farField
        )
        #expect(gain == 4.0)
    }

    @Test("Far-field mic with ambient above target returns 1.0")
    func farFieldAmbientAboveTarget() {
        // Ambient 0.03 is above the target 0.02.
        // Raw gain would be 0.02 / 0.03 = 0.667, clamped to 1.0.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.03,
            micProximity: .farField
        )
        #expect(gain == 1.0)
    }

    @Test("Far-field mic with ambient exactly at target returns 1.0")
    func farFieldAmbientAtTarget() {
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.02,
            micProximity: .farField
        )
        #expect(gain == 1.0)
    }

    @Test("Far-field mic with zero ambient returns 1.0")
    func farFieldZeroAmbient() {
        // Zero ambient means calibration produced no useful data.
        // Gain stays at 1.0 to avoid division by zero.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0,
            micProximity: .farField
        )
        #expect(gain == 1.0)
    }

    @Test("Far-field mic with very low ambient clamps to max gain")
    func farFieldVeryLowAmbient() {
        // Ambient 0.0005 (extremely quiet room).
        // Raw gain: 0.02 / 0.0005 = 40.0, clamped to 16.0.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.0005,
            micProximity: .farField
        )
        #expect(gain == 16.0)
    }

    @Test("Near-field mic always returns 1.0 regardless of ambient")
    func nearFieldAlwaysUnity() {
        // Near-field mics (AirPods, USB) produce strong signals.
        // Gain is never applied, even with low ambient.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.001,
            micProximity: .nearField
        )
        #expect(gain == 1.0)
    }

    @Test("Near-field mic with zero ambient returns 1.0")
    func nearFieldZeroAmbient() {
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0,
            micProximity: .nearField
        )
        #expect(gain == 1.0)
    }

    @Test("Near-field mic with high ambient returns 1.0")
    func nearFieldHighAmbient() {
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.05,
            micProximity: .nearField
        )
        #expect(gain == 1.0)
    }

    @Test("Gain at max boundary is exactly 16.0")
    func gainMaxBoundary() {
        // Ambient that produces exactly 16x: 0.02 / 16.0 = 0.00125.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.00125,
            micProximity: .farField
        )
        #expect(gain == 16.0)
    }

    @Test("Gain just below max boundary is unclamped")
    func gainJustBelowMax() {
        // Ambient 0.0013: 0.02 / 0.0013 ≈ 15.38, below 16.0.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.0013,
            micProximity: .farField
        )
        let expected = Float(0.02) / Float(0.0013)
        #expect(gain == expected)
        #expect(gain < 16.0)
        #expect(gain > 1.0)
    }
}

// MARK: - Software gain application

@Suite("Software gain PCM application")
struct ApplySoftwareGainTests {

    /// Build a Data buffer from an array of Int16 samples.
    private func dataFrom(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Read Int16 samples from a Data buffer.
    private func samplesFrom(_ data: Data) -> [Int16] {
        let count = data.count / 2
        return data.withUnsafeBytes { raw in
            let bound = raw.bindMemory(to: Int16.self)
            return (0..<count).map { bound[$0] }
        }
    }

    @Test("Gain of 1.0 returns data unchanged")
    func unityGainPassthrough() {
        let input: [Int16] = [0, 100, -100, 32767, -32768, 1000, -1000]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 1.0)
        #expect(result == data)
    }

    @Test("Gain below 1.0 returns data unchanged")
    func subUnityGainPassthrough() {
        let input: [Int16] = [500, -500, 10000]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 0.5)
        #expect(result == data)
    }

    @Test("Gain of 2.0 doubles sample values")
    func doubleGain() {
        let input: [Int16] = [100, -100, 0, 5000, -5000]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 2.0)
        let output = samplesFrom(result)
        #expect(output == [200, -200, 0, 10000, -10000])
    }

    @Test("Gain of 10.0 amplifies quiet speech samples")
    func tenXGain() {
        // Typical built-in mic quiet speech: samples around ±100-200.
        let input: [Int16] = [150, -150, 200, -200]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 10.0)
        let output = samplesFrom(result)
        #expect(output == [1500, -1500, 2000, -2000])
    }

    @Test("Positive overflow clamps to Int16.max")
    func positiveOverflowClamps() {
        // 3000 * 16.0 = 48000, exceeds Int16.max (32767).
        let input: [Int16] = [3000]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 16.0)
        let output = samplesFrom(result)
        #expect(output == [Int16.max])
    }

    @Test("Negative overflow clamps to Int16.min")
    func negativeOverflowClamps() {
        // -3000 * 16.0 = -48000, below Int16.min (-32768).
        let input: [Int16] = [-3000]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 16.0)
        let output = samplesFrom(result)
        #expect(output == [Int16.min])
    }

    @Test("Max positive sample clamps correctly at any gain above 1.0")
    func maxPositiveSampleClamps() {
        let input: [Int16] = [Int16.max]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 2.0)
        let output = samplesFrom(result)
        // 32767 * 2 = 65534, clamped to 32767.
        #expect(output == [Int16.max])
    }

    @Test("Min negative sample clamps correctly at any gain above 1.0")
    func minNegativeSampleClamps() {
        let input: [Int16] = [Int16.min]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 2.0)
        let output = samplesFrom(result)
        // -32768 * 2 = -65536, clamped to -32768.
        #expect(output == [Int16.min])
    }

    @Test("Boundary sample just below overflow is not clamped")
    func boundaryNoOverflow() {
        // 2048 * 16.0 = 32768, which overflows Int16 by 1.
        // 2047 * 16.0 = 32752, which fits.
        let input: [Int16] = [2047]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 16.0)
        let output = samplesFrom(result)
        #expect(output == [32752])
    }

    @Test("Boundary sample at overflow is clamped")
    func boundaryAtOverflow() {
        // 2048 * 16.0 = 32768, one past Int16.max.
        let input: [Int16] = [2048]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 16.0)
        let output = samplesFrom(result)
        #expect(output == [Int16.max])
    }

    @Test("Zero samples remain zero at any gain")
    func zeroSamplesUnchanged() {
        let input: [Int16] = [0, 0, 0]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 16.0)
        let output = samplesFrom(result)
        #expect(output == [0, 0, 0])
    }

    @Test("Empty data returns empty data")
    func emptyInput() {
        let data = Data()
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 10.0)
        #expect(result.isEmpty)
    }

    @Test("Mixed signal with gain has correct clamping behavior")
    func mixedSignalClamping() {
        // Simulate a real buffer: mostly quiet with one loud sample.
        // At 16x gain: 100→1600, -100→-1600, 2500→40000(clamped),
        // -2500→-40000(clamped), 0→0.
        let input: [Int16] = [100, -100, 2500, -2500, 0]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 16.0)
        let output = samplesFrom(result)
        #expect(output == [1600, -1600, Int16.max, Int16.min, 0])
    }

    @Test("Data size is preserved after gain application")
    func dataSizePreserved() {
        let input: [Int16] = [100, 200, 300, 400, 500]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 8.0)
        #expect(result.count == data.count)
    }

    @Test("Gain of 16x on typical whisper samples produces usable signal")
    func whisperAmplification() {
        // Whisper on built-in mic: samples around ±30-60 (RMS ~0.001).
        // At 16x: 30→480, 60→960, -45→-720. All well within Int16 range
        // and now audible to the transcription model.
        let input: [Int16] = [30, 60, -45, 50, -30]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 16.0)
        let output = samplesFrom(result)
        #expect(output == [480, 960, -720, 800, -480])
    }

    @Test("Gain on single sample data works correctly")
    func singleSample() {
        let input: [Int16] = [1000]
        let data = dataFrom(input)
        let result = AudioCaptureProvider.applySoftwareGain(data, gain: 5.0)
        let output = samplesFrom(result)
        #expect(output == [5000])
    }
}

// MARK: - End-to-end gain scenarios

@Suite("Software gain end-to-end scenarios")
struct GainEndToEndTests {

    @Test("Built-in mic whisper: gain computed and applied correctly")
    func builtInMicWhisperScenario() {
        // Simulate: built-in mic, ambient RMS 0.001, whisper samples ±50.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.001,
            micProximity: .farField
        )
        // Gain should be 16.0 (clamped from 20.0).
        #expect(gain == 16.0)

        // Apply to whisper samples.
        var data = Data(capacity: 4)
        withUnsafeBytes(of: Int16(50).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int16(-50).littleEndian) { data.append(contentsOf: $0) }

        let gained = AudioCaptureProvider.applySoftwareGain(data, gain: gain)
        let samples = gained.withUnsafeBytes { raw in
            let bound = raw.bindMemory(to: Int16.self)
            return [bound[0], bound[1]]
        }
        // 50 * 16 = 800, -50 * 16 = -800. Both well within range.
        #expect(samples == [800, -800])
    }

    @Test("Built-in mic normal speech: gain applied, no clipping")
    func builtInMicNormalSpeechScenario() {
        // Ambient 0.002, gain = 0.02/0.002 ≈ 10.0.
        // Float32 division may produce 9.999999, so use approximate check.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.002,
            micProximity: .farField
        )
        #expect(abs(gain - 10.0) < 0.001)

        // Normal speech samples around ±200 (RMS ~0.006).
        // 200 * ~10.0 ≈ 2000: well within Int16 range. Allow ±1 for
        // Float32→Int32 truncation from the non-exact gain factor.
        var data = Data(capacity: 4)
        withUnsafeBytes(of: Int16(200).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int16(-200).littleEndian) { data.append(contentsOf: $0) }

        let gained = AudioCaptureProvider.applySoftwareGain(data, gain: gain)
        let samples = gained.withUnsafeBytes { raw in
            let bound = raw.bindMemory(to: Int16.self)
            return [bound[0], bound[1]]
        }
        #expect(abs(Int32(samples[0]) - 2000) <= 1)
        #expect(abs(Int32(samples[1]) + 2000) <= 1)
    }

    @Test("AirPods mic: no gain applied regardless of ambient")
    func airPodsNoGainScenario() {
        // AirPods are near-field; gain is always 1.0.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.002,
            micProximity: .nearField
        )
        #expect(gain == 1.0)

        // Samples pass through unchanged.
        var data = Data(capacity: 4)
        withUnsafeBytes(of: Int16(3000).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int16(-3000).littleEndian) { data.append(contentsOf: $0) }

        let gained = AudioCaptureProvider.applySoftwareGain(data, gain: gain)
        #expect(gained == data)
    }

    @Test("Built-in mic loud speech with low ambient clips gracefully")
    func builtInMicLoudSpeechClipsGracefully() {
        // Ambient 0.001, gain = 16.0 (clamped).
        // Loud speech sample 2500: 2500 * 16 = 40000, clamped to 32767.
        let gain = AudioCaptureProvider.computeGainFactor(
            ambientRMS: 0.001,
            micProximity: .farField
        )
        #expect(gain == 16.0)

        var data = Data(capacity: 2)
        withUnsafeBytes(of: Int16(2500).littleEndian) { data.append(contentsOf: $0) }

        let gained = AudioCaptureProvider.applySoftwareGain(data, gain: gain)
        let sample = gained.withUnsafeBytes { $0.bindMemory(to: Int16.self)[0] }
        #expect(sample == Int16.max)
    }
}
