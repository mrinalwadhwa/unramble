import Foundation
import Testing

@testable import UnrambleKit

@Suite("AudioLevelAnalyzer")
struct AudioLevelAnalyzerTests {

    /// Build raw 16-bit LE PCM data from an array of Int16 samples.
    private func rawPCM(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test("Raw PCM rmsLevel returns zero for empty data")
    func rawEmptyReturnsZero() {
        #expect(AudioLevelAnalyzer.rmsLevel(pcm16: Data()) == 0.0)
    }

    @Test("Raw PCM rmsLevel matches the known sample amplitude")
    func rawMatchesKnownAmplitude() {
        let samples: [Int16] = (0..<1600).map { $0 % 2 == 0 ? Int16(3000) : Int16(-3000) }
        let rms = AudioLevelAnalyzer.rmsLevel(pcm16: rawPCM(samples))
        #expect(abs(rms - Float(3000.0 / 32768.0)) < 0.000_001)
    }

    @Test("Raw PCM rmsLevel detects speech above the silence threshold")
    func rawDetectsSpeech() {
        let samples: [Int16] = (0..<1600).map { $0 % 2 == 0 ? Int16(3000) : Int16(-3000) }
        let rms = AudioLevelAnalyzer.rmsLevel(pcm16: rawPCM(samples))
        #expect(rms > 0.005)
    }

    @Test("Raw PCM rmsLevel detects silence below the silence threshold")
    func rawDetectsSilence() {
        let samples = [Int16](repeating: 0, count: 1600)
        let rms = AudioLevelAnalyzer.rmsLevel(pcm16: rawPCM(samples))
        #expect(rms <= 0.005)
    }
}
