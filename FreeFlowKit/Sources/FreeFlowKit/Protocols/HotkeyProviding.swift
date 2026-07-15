import Foundation

/// Provides global hotkey registration and event delivery.
///
/// The hotkey listener runs system-wide, capturing key events from any application.
/// Requires the app to be trusted for accessibility (AXIsProcessTrusted).
public protocol HotkeyProviding: Sendable {

    /// Register a global hotkey listener.
    ///
    /// The callback fires on the provider's event-tap thread for each press and
    /// release event. Callers must dispatch UI work to the main actor.
    /// Only one listener can be active at a time; calling `register` again
    /// replaces the previous callback.
    ///
    /// - Parameter callback: Called with `.pressed` on key-down and `.released` on key-up.
    /// - Throws: If the event tap cannot be created (e.g. accessibility permission not granted).
    func register(callback: @escaping @Sendable (HotkeyEvent) -> Void) throws

    /// Register with the physical event timestamp converted into AVAudio Mach
    /// host-time ticks. Implementations without a native event clock may use
    /// callback-entry host time.
    func registerTimestamped(
        callback: @escaping @Sendable (HotkeyEvent, UInt64) -> Void
    ) throws

    /// Remove the global hotkey listener and release the event tap.
    func unregister()
}

extension HotkeyProviding {
    public func registerTimestamped(
        callback: @escaping @Sendable (HotkeyEvent, UInt64) -> Void
    ) throws {
        try register { event in
            callback(event, AudioCaptureReleaseFence.currentHostTime())
        }
    }
}
