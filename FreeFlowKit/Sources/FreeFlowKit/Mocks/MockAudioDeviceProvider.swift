import Foundation

/// A mock audio device provider that returns stub devices for testing.
///
/// Used in tests to exercise mic enumeration and selection without
/// real audio hardware.
public final class MockAudioDeviceProvider: AudioDeviceProviding, @unchecked Sendable {

    private let lock = NSLock()

    private var _devices: [AudioDevice]
    private var _selectedDeviceID: UInt32?
    private var _selectCallCount = 0

    /// Error to throw from `selectDevice(id:)`, or nil to succeed.
    public var stubbedSelectError: (any Error)?

    /// Number of times `selectDevice(id:)` has been called.
    public var selectCallCount: Int {
        lock.withLock { _selectCallCount }
    }

    /// The device ID most recently passed to `selectDevice(id:)`, or nil.
    public var lastSelectedDeviceID: UInt32? {
        lock.withLock { _selectedDeviceID }
    }

    public init(devices: [AudioDevice]? = nil) {
        self._devices =
            devices ?? [
                AudioDevice(id: 1, name: "MacBook Pro Microphone", isDefault: true),
                AudioDevice(id: 2, name: "External USB Microphone"),
            ]
    }

    /// Replace the list of available devices.
    public func setDevices(_ devices: [AudioDevice]) {
        lock.withLock { _devices = devices }
    }

    public func availableDevices() async -> [AudioDevice] {
        lock.withLock { _devices }
    }

    public func currentDevice() async -> AudioDevice? {
        lock.withLock {
            if let selectedID = _selectedDeviceID {
                return _devices.first { $0.id == selectedID }
            }
            return _devices.first { $0.isDefault } ?? _devices.first
        }
    }

    public func selectDevice(id: UInt32) async throws {
        try lock.withLock {
            _selectCallCount += 1
            if let error = stubbedSelectError {
                throw error
            }
            guard _devices.contains(where: { $0.id == id }) else {
                throw MockAudioDeviceError.deviceNotFound(id)
            }
            _selectedDeviceID = id
        }
    }

    public var isAutoDetect: Bool {
        lock.withLock { _selectedDeviceID == nil }
    }

    public func clearSelection() {
        lock.withLock { _selectedDeviceID = nil }
    }

    public var isClamshellClosed: Bool { false }
}

/// Errors thrown by `MockAudioDeviceProvider`.
public enum MockAudioDeviceError: Error, Equatable {
    case deviceNotFound(UInt32)
}
