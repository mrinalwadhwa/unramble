import Foundation

/// Captured audio data ready for dictation.
public struct AudioBuffer: Sendable, Equatable {
    /// WAV-encoded PCM audio data.
    public let data: Data

    /// Duration of the captured audio in seconds.
    public let duration: TimeInterval

    /// Sample rate in Hz (default: 16000).
    public let sampleRate: Int

    /// Number of audio channels (default: 1 for mono).
    public let channels: Int

    /// Bits per sample (default: 16).
    public let bitsPerSample: Int

    public init(
        data: Data,
        duration: TimeInterval,
        sampleRate: Int = 16000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) {
        self.data = data
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    /// An empty buffer representing no captured audio.
    public static let empty = AudioBuffer(
        data: Data(),
        duration: 0
    )
}
