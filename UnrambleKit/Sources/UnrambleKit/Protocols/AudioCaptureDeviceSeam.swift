import Foundation

/// A read-only snapshot of the selected audio input device, plus the ability to
/// clear the selection. The capture provider pulls the device id, name, and
/// proximity through this seam, so it does not depend on the concrete device
/// provider type.
public protocol AudioInputDeviceSnapshotProviding: AnyObject {
    var selectedDeviceID: UInt32? { get }
    func clearSelection()
    func micProximityForDevice(_ deviceID: UInt32?) -> MicProximity
    func deviceNameForDevice(_ deviceID: UInt32?) -> String?
}

/// Receives a request to rebuild the capture engine after a device change. The
/// device provider pushes through this seam, so it does not depend on the
/// concrete capture provider type.
public protocol AudioCaptureRebuildSink: AnyObject {
    func markNeedsRebuild()
}

extension CoreAudioDeviceProvider: AudioInputDeviceSnapshotProviding {}
extension AudioCaptureProvider: AudioCaptureRebuildSink {}
