import Foundation

/// A physical or virtual audio input device available on the system.
public struct AudioDevice: Sendable, Equatable, Identifiable {

    /// How the device is connected to the system.
    public enum TransportType: Sendable, Equatable {
        /// Built-in microphone (e.g. MacBook Pro Microphone).
        case builtIn
        /// Bluetooth device (e.g. AirPods, headset).
        case bluetooth
        /// USB device (e.g. Yeti, Scarlett).
        case usb
        /// Virtual or aggregate device, or transport could not be determined.
        case other
    }

    /// Core Audio device ID.
    public let id: UInt32

    /// Human-readable device name (e.g. "MacBook Pro Microphone").
    public let name: String

    /// Whether this is the system default input device.
    public let isDefault: Bool

    /// How the device is physically connected.
    public let transportType: TransportType

    public init(
        id: UInt32,
        name: String,
        isDefault: Bool = false,
        transportType: TransportType = .other
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.transportType = transportType
    }

    /// Mic proximity relative to the speaker's mouth.
    ///
    /// Controls local audio processing (software gain, silence
    /// threshold) and is forwarded to the streaming dictation provider
    /// for noise reduction configuration. Only Bluetooth devices are
    /// near-field (close-talking headset). All others default to
    /// far-field: built-in mics, USB desk mics, virtual/aggregate
    /// devices, and unknown transports.
    ///
    /// Far-field enables adaptive software gain (clamped at 16x) and
    /// a fixed silence threshold. The gain is self-correcting: loud
    /// signals produce a low gain factor, so already-normalized
    /// virtual device audio is not over-amplified.
    public var micProximity: MicProximity {
        switch transportType {
        case .builtIn, .usb, .other:
            return .farField
        case .bluetooth:
            return .nearField
        }
    }
}

/// Microphone proximity relative to the speaker's mouth.
///
/// Sent to the server so it can configure the OpenAI Realtime API's
/// `input_audio_noise_reduction` appropriately.
public enum MicProximity: String, Sendable, Equatable {
    /// Close-talking microphone (headphones, Bluetooth headset).
    case nearField = "near_field"
    /// Far-field microphone (built-in laptop mic, USB desk mic, conference room mic).
    case farField = "far_field"
}
