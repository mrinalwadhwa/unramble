import Foundation

/// Enumerate and select audio input devices.
///
/// Separate from `AudioProviding` because device listing and recording are
/// independent concerns. The menu bar microphone submenu depends only on
/// this protocol; the pipeline depends only on `AudioProviding`. Each can
/// be mocked independently.
public protocol AudioDeviceProviding: Sendable {

    /// All audio input devices currently available on the system.
    func availableDevices() async -> [AudioDevice]

    /// The currently selected input device, or nil if no device is available.
    func currentDevice() async -> AudioDevice?

    /// Select an input device by its Core Audio device ID.
    ///
    /// The next recording session uses the selected device. Does not affect
    /// a recording that is already in progress.
    func selectDevice(id: UInt32) async throws

    /// Whether the user is in auto-detect mode (no explicit selection).
    var isAutoDetect: Bool { get }

    /// Clear the explicit device selection, reverting to auto-detect.
    func clearSelection()

    /// Whether the MacBook lid is closed (clamshell mode).
    var isClamshellClosed: Bool { get }
}
