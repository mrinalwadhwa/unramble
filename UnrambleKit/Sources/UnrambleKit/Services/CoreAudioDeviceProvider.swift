import Foundation

#if canImport(CoreAudio)
    import CoreAudio
#endif

#if canImport(IOKit)
    import IOKit
#endif

/// Enumerate and select audio input devices using Core Audio.
///
/// Uses `AudioObjectGetPropertyData` to list physical and virtual input
/// devices, read their names, and detect the system default. Device
/// selection stores the chosen device ID; `AudioCaptureProvider` reads
/// it before creating or reconfiguring its `AVAudioEngine`.
///
/// Listens for hardware device list changes (connect/disconnect) and
/// default device changes so `availableDevices()` always reflects the
/// current state.
public final class CoreAudioDeviceProvider: AudioDeviceProviding, @unchecked Sendable {

    private let lock = NSLock()

    /// Explicitly selected device ID, or nil to use the system default.
    private var _selectedDeviceID: UInt32?

    /// Weak reference to the audio capture provider. When a device
    /// list or default-device change is detected, the provider is
    /// notified so it can mark its engine for rebuild. AVAudioEngine
    /// does not emit configuration-change notifications when stopped,
    /// so without this, device changes between recording sessions
    /// leave the engine with stale CoreAudio state.
    private weak var _audioCaptureProvider: (any AudioCaptureRebuildSink)?

    /// Listeners registered with Core Audio for device changes.
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {
        #if canImport(CoreAudio)
            registerListeners()
        #endif
    }

    /// Set the audio capture provider to notify on device changes.
    ///
    /// Call once during setup, after both providers are created.
    /// The provider is held weakly to avoid retain cycles.
    public func setAudioCaptureProvider(_ provider: any AudioCaptureRebuildSink) {
        lock.withLock { _audioCaptureProvider = provider }
    }

    deinit {
        #if canImport(CoreAudio)
            unregisterListeners()
        #endif
    }

    // MARK: - AudioDeviceProviding

    public func availableDevices() async -> [AudioDevice] {
        #if canImport(CoreAudio)
            return listInputDevices()
        #else
            return []
        #endif
    }

    public func currentDevice() async -> AudioDevice? {
        #if canImport(CoreAudio)
            let devices = listInputDevices()
            let selectedID: UInt32? = lock.withLock { _selectedDeviceID }

            if let selectedID {
                // Return the selected device if it still exists.
                if let device = devices.first(where: { $0.id == selectedID }) {
                    return device
                }
                // Selected device was disconnected — fall through to default.
            }

            // Return the system default input device.
            return devices.first(where: { $0.isDefault }) ?? devices.first
        #else
            return nil
        #endif
    }

    public func selectDevice(id: UInt32) async throws {
        #if canImport(CoreAudio)
            let devices = listInputDevices()
            guard devices.contains(where: { $0.id == id }) else {
                throw CoreAudioDeviceError.deviceNotFound(id)
            }
            lock.withLock { _selectedDeviceID = id }
            Log.debug("[CoreAudioDeviceProvider] Selected device id=\(id)")
        #else
            throw CoreAudioDeviceError.coreAudioUnavailable
        #endif
    }

    /// The device ID that should be used for the next recording session.
    ///
    /// Returns the explicitly selected device, or nil to use the system
    /// default. `AudioCaptureProvider` reads this before creating its
    /// engine to configure the correct input device.
    public var selectedDeviceID: UInt32? {
        lock.withLock { _selectedDeviceID }
    }

    /// Whether the user is in auto-detect mode (no explicit selection).
    public var isAutoDetect: Bool {
        lock.withLock { _selectedDeviceID == nil }
    }

    /// Clear the explicit device selection, reverting to auto-detect.
    public func clearSelection() {
        lock.withLock { _selectedDeviceID = nil }
        Log.debug("[CoreAudioDeviceProvider] Cleared selection, using auto-detect")
    }

    /// Whether the MacBook lid is closed (clamshell mode).
    ///
    /// When true and the built-in mic is selected, audio quality
    /// will be poor because the mic is behind the closed lid.
    public var isClamshellClosed: Bool {
        #if canImport(IOKit)
            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching("IOPMrootDomain"),
                &iterator)
            guard result == KERN_SUCCESS else { return false }
            defer { IOObjectRelease(iterator) }

            let service = IOIteratorNext(iterator)
            guard service != 0 else { return false }
            defer { IOObjectRelease(service) }

            guard let prop = IORegistryEntryCreateCFProperty(
                service,
                "AppleClamshellState" as CFString,
                kCFAllocatorDefault,
                0)?.takeRetainedValue()
            else { return false }

            return (prop as? Bool) ?? false
        #else
            return false
        #endif
    }

    /// Return the mic proximity for a device ID.
    ///
    /// If `deviceID` is nil (system default), looks up the current
    /// default input device. Returns `.nearField` if the device
    /// cannot be found.
    public func micProximityForDevice(_ deviceID: UInt32?) -> MicProximity {
        #if canImport(CoreAudio)
            let id: AudioObjectID
            if let deviceID {
                id = deviceID
            } else if let defaultID = getDefaultInputDeviceID() {
                id = defaultID
            } else {
                return .nearField
            }
            switch getTransportType(deviceID: id) {
            case .builtIn, .usb, .other:
                return .farField
            case .bluetooth:
                return .nearField
            }
        #else
            return .nearField
        #endif
    }

    /// Return the device name for a device ID.
    ///
    /// If `deviceID` is nil (system default), looks up the current
    /// default input device. Returns `nil` if the device cannot be
    /// found.
    public func deviceNameForDevice(_ deviceID: UInt32?) -> String? {
        #if canImport(CoreAudio)
            let id: AudioObjectID
            if let deviceID {
                id = deviceID
            } else if let defaultID = getDefaultInputDeviceID() {
                id = defaultID
            } else {
                return nil
            }
            return getDeviceName(deviceID: id)
        #else
            return nil
        #endif
    }

    // MARK: - Core Audio Enumeration

    #if canImport(CoreAudio)

        /// List audio input devices, filtering out virtual and
        /// aggregate devices that aren't real microphones.
        private func listInputDevices() -> [AudioDevice] {
            let allDeviceIDs = getAllAudioDeviceIDs()
            let defaultInputID = getDefaultInputDeviceID()

            var inputDevices: [AudioDevice] = []

            for deviceID in allDeviceIDs {
                guard hasInputStreams(deviceID: deviceID) else { continue }
                guard let name = getDeviceName(deviceID: deviceID) else { continue }

                let transport = getTransportType(deviceID: deviceID)

                Log.debug(
                    "[CoreAudioDeviceProvider] Input device: \"\(name)\" "
                    + "id=\(deviceID) transport=\(transport)"
                    + (deviceID == defaultInputID ? " (default)" : "")
                )

                // Skip known virtual and aggregate devices.
                // Allow transport=other for real hardware like
                // iPhone Continuity Microphone.
                if isVirtualDevice(name: name) { continue }

                let device = AudioDevice(
                    id: deviceID,
                    name: name,
                    isDefault: deviceID == defaultInputID,
                    transportType: transport
                )
                inputDevices.append(device)
            }

            return inputDevices
        }

        /// Get all audio device IDs on the system.
        private func getAllAudioDeviceIDs() -> [AudioObjectID] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var dataSize: UInt32 = 0
            let sizeStatus = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            )
            guard sizeStatus == noErr, dataSize > 0 else { return [] }

            let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)

            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &deviceIDs
            )
            guard status == noErr else { return [] }

            return deviceIDs
        }

        /// Get the system default input device ID.
        private func getDefaultInputDeviceID() -> AudioObjectID? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceID: AudioObjectID = kAudioObjectUnknown
            var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &deviceID
            )

            guard status == noErr, deviceID != kAudioObjectUnknown else {
                return nil
            }
            return deviceID
        }

        /// Check whether a device has input streams (i.e. is a microphone).
        private func hasInputStreams(deviceID: AudioObjectID) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var dataSize: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &dataSize
            )

            // A device with input streams has dataSize > 0.
            return status == noErr && dataSize > 0
        }

        /// Map the Core Audio transport type constant to our enum.
        private func getTransportType(deviceID: AudioObjectID) -> AudioDevice.TransportType {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var transportType: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size)

            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &transportType
            )

            guard status == noErr else { return .other }

            switch transportType {
            case kAudioDeviceTransportTypeBuiltIn:
                return .builtIn
            case kAudioDeviceTransportTypeBluetooth,
                kAudioDeviceTransportTypeBluetoothLE:
                return .bluetooth
            case kAudioDeviceTransportTypeUSB:
                return .usb
            default:
                return .other
            }
        }

        /// Check if a device is a known virtual/aggregate device that
        /// should be hidden from the mic menu.
        private func isVirtualDevice(name: String) -> Bool {
            let lower = name.lowercased()
            return lower.contains("aggregate")
                || lower.contains("zoomaudiodevice")
                || lower.contains("screencastaudio")
                || lower.contains("blackhole")
                || lower.contains("loopback")
                || lower.contains("soundflower")
        }

        /// Get the human-readable name of a device.
        private func getDeviceName(deviceID: AudioObjectID) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var name: CFString = "" as CFString
            var dataSize = UInt32(MemoryLayout<CFString>.size)

            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &name
            )

            guard status == noErr else { return nil }
            return name as String
        }

        // MARK: - Device Change Listeners

        /// Register listeners for device list changes and default device changes.
        private func registerListeners() {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                Log.debug("[CoreAudioDeviceProvider] Device list changed")
                let (selectedID, captureProvider): (UInt32?, (any AudioCaptureRebuildSink)?) = self.lock
                    .withLock {
                        (self._selectedDeviceID, self._audioCaptureProvider)
                    }
                if let selectedID {
                    let devices = self.listInputDevices()
                    if !devices.contains(where: { $0.id == selectedID }) {
                        self.lock.withLock { self._selectedDeviceID = nil }
                        Log.debug(
                            "[CoreAudioDeviceProvider] Selected device \(selectedID) disconnected, reverting to default"
                        )
                        captureProvider?.markNeedsRebuild()
                    }
                    // Selected device still present — skip rebuild.
                } else {
                    // Using system default — rebuild to pick up changes.
                    captureProvider?.markNeedsRebuild()
                }
            }

            let devicesStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                nil,
                devicesBlock
            )
            if devicesStatus != noErr {
                Log.debug("[CoreAudioDeviceProvider] Failed to register device list listener: \(devicesStatus)")
            }
            deviceListListenerBlock = devicesBlock

            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Log.debug("[CoreAudioDeviceProvider] Default input device changed")
                let (selectedID, captureProvider): (UInt32?, (any AudioCaptureRebuildSink)?) =
                    self?.lock.withLock {
                        (self?._selectedDeviceID, self?._audioCaptureProvider)
                    } ?? (nil, nil)
                if selectedID == nil {
                    captureProvider?.markNeedsRebuild()
                }
            }

            let defaultStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                nil,
                defaultBlock
            )
            if defaultStatus != noErr {
                Log.debug("[CoreAudioDeviceProvider] Failed to register default device listener: \(defaultStatus)")
            }
            defaultDeviceListenerBlock = defaultBlock
        }

        /// Remove all registered Core Audio listeners.
        private func unregisterListeners() {
            if let block = deviceListListenerBlock {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    nil,
                    block
                )
                deviceListListenerBlock = nil
            }

            if let block = defaultDeviceListenerBlock {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    nil,
                    block
                )
                defaultDeviceListenerBlock = nil
            }
        }

    #endif
}

/// Errors thrown by `CoreAudioDeviceProvider`.
public enum CoreAudioDeviceError: Error, Sendable {
    case deviceNotFound(UInt32)
    case coreAudioUnavailable
}
