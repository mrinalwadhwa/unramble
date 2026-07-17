import Foundation
import Testing

@testable import UnrambleKit

@Suite("AudioDevice model")
struct AudioDeviceTests {

    @Test("AudioDevice stores all properties")
    func properties() {
        let device = AudioDevice(id: 42, name: "Studio Mic", isDefault: true)

        #expect(device.id == 42)
        #expect(device.name == "Studio Mic")
        #expect(device.isDefault == true)
    }

    @Test("AudioDevice defaults isDefault to false")
    func isDefaultFalse() {
        let device = AudioDevice(id: 1, name: "Built-in")

        #expect(device.isDefault == false)
    }

    @Test("AudioDevice Equatable compares all fields")
    func equatable() {
        let a = AudioDevice(id: 1, name: "Mic A", isDefault: true)
        let b = AudioDevice(id: 1, name: "Mic A", isDefault: true)
        let c = AudioDevice(id: 2, name: "Mic A", isDefault: true)
        let d = AudioDevice(id: 1, name: "Mic B", isDefault: true)
        let e = AudioDevice(id: 1, name: "Mic A", isDefault: false)

        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a != e)
    }

    @Test("AudioDevice Identifiable uses id")
    func identifiable() {
        let device = AudioDevice(id: 7, name: "Test")
        #expect(device.id == 7)
    }

    @Test("AudioDevice defaults transportType to other")
    func transportTypeDefault() {
        let device = AudioDevice(id: 1, name: "Mic")
        #expect(device.transportType == .other)
    }

    @Test("AudioDevice stores explicit transportType")
    func transportTypeExplicit() {
        let builtIn = AudioDevice(id: 1, name: "MacBook Pro Microphone", transportType: .builtIn)
        let bluetooth = AudioDevice(id: 2, name: "AirPods", transportType: .bluetooth)
        let usb = AudioDevice(id: 3, name: "Yeti", transportType: .usb)
        let other = AudioDevice(id: 4, name: "Virtual", transportType: .other)

        #expect(builtIn.transportType == .builtIn)
        #expect(bluetooth.transportType == .bluetooth)
        #expect(usb.transportType == .usb)
        #expect(other.transportType == .other)
    }

    @Test("AudioDevice Equatable includes transportType")
    func equatableTransportType() {
        let a = AudioDevice(id: 1, name: "Mic", transportType: .builtIn)
        let b = AudioDevice(id: 1, name: "Mic", transportType: .builtIn)
        let c = AudioDevice(id: 1, name: "Mic", transportType: .usb)

        #expect(a == b)
        #expect(a != c)
    }

    @Test("Built-in mic reports far-field proximity")
    func micProximityBuiltIn() {
        let device = AudioDevice(id: 1, name: "MacBook Pro Microphone", transportType: .builtIn)
        #expect(device.micProximity == .farField)
    }

    @Test("Bluetooth mic reports near-field proximity")
    func micProximityBluetooth() {
        let device = AudioDevice(id: 2, name: "AirPods", transportType: .bluetooth)
        #expect(device.micProximity == .nearField)
    }

    @Test("USB mic reports far-field proximity")
    func micProximityUSB() {
        let device = AudioDevice(id: 3, name: "Yeti", transportType: .usb)
        #expect(device.micProximity == .farField)
    }

    @Test("Other/unknown device defaults to far-field proximity")
    func micProximityOther() {
        let device = AudioDevice(id: 4, name: "Virtual", transportType: .other)
        #expect(device.micProximity == .farField)
    }

    @Test("MicProximity rawValue matches API field names")
    func micProximityRawValues() {
        #expect(MicProximity.nearField.rawValue == "near_field")
        #expect(MicProximity.farField.rawValue == "far_field")
    }
}

@Suite("MockAudioDeviceProvider")
struct MockAudioDeviceProviderTests {

    @Test("Default devices include built-in and external")
    func defaultDevices() async {
        let provider = MockAudioDeviceProvider()
        let devices = await provider.availableDevices()

        #expect(devices.count == 2)
        #expect(devices[0].name == "MacBook Pro Microphone")
        #expect(devices[0].isDefault == true)
        #expect(devices[1].name == "External USB Microphone")
        #expect(devices[1].isDefault == false)
    }

    @Test("Current device returns the default device initially")
    func currentDeviceDefault() async {
        let provider = MockAudioDeviceProvider()
        let current = await provider.currentDevice()

        #expect(current != nil)
        #expect(current?.name == "MacBook Pro Microphone")
        #expect(current?.isDefault == true)
    }

    @Test("Current device falls back to first when none is default")
    func currentDeviceFallback() async {
        let devices = [
            AudioDevice(id: 10, name: "Mic A"),
            AudioDevice(id: 11, name: "Mic B"),
        ]
        let provider = MockAudioDeviceProvider(devices: devices)
        let current = await provider.currentDevice()

        #expect(current != nil)
        #expect(current?.name == "Mic A")
    }

    @Test("Current device returns nil when no devices exist")
    func currentDeviceEmpty() async {
        let provider = MockAudioDeviceProvider(devices: [])
        let current = await provider.currentDevice()

        #expect(current == nil)
    }

    @Test("Select device changes current device")
    func selectDevice() async throws {
        let provider = MockAudioDeviceProvider()

        try await provider.selectDevice(id: 2)

        let current = await provider.currentDevice()
        #expect(current?.name == "External USB Microphone")
        #expect(provider.selectCallCount == 1)
        #expect(provider.lastSelectedDeviceID == 2)
    }

    @Test("Select device throws for unknown device ID")
    func selectUnknownDevice() async {
        let provider = MockAudioDeviceProvider()

        do {
            try await provider.selectDevice(id: 999)
            Issue.record("Expected error for unknown device ID")
        } catch let error as MockAudioDeviceError {
            #expect(error == .deviceNotFound(999))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(provider.selectCallCount == 1)
    }

    @Test("Select device throws stubbed error when configured")
    func selectStubbedError() async {
        let provider = MockAudioDeviceProvider()

        struct TestError: Error {}
        provider.stubbedSelectError = TestError()

        do {
            try await provider.selectDevice(id: 1)
            Issue.record("Expected stubbed error")
        } catch is TestError {
            // Expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("setDevices replaces the device list")
    func setDevices() async {
        let provider = MockAudioDeviceProvider()

        let newDevices = [
            AudioDevice(id: 100, name: "New Mic", isDefault: true)
        ]
        provider.setDevices(newDevices)

        let devices = await provider.availableDevices()
        #expect(devices.count == 1)
        #expect(devices[0].name == "New Mic")
    }

    @Test("Select persists across device list queries")
    func selectPersists() async throws {
        let provider = MockAudioDeviceProvider()

        try await provider.selectDevice(id: 2)

        // Query devices, then check current is still the selected one
        let devices = await provider.availableDevices()
        #expect(devices.count == 2)

        let current = await provider.currentDevice()
        #expect(current?.id == 2)
    }

    @Test("Multiple select calls track the last selection")
    func multipleSelects() async throws {
        let provider = MockAudioDeviceProvider()

        try await provider.selectDevice(id: 2)
        try await provider.selectDevice(id: 1)

        #expect(provider.selectCallCount == 2)
        #expect(provider.lastSelectedDeviceID == 1)

        let current = await provider.currentDevice()
        #expect(current?.id == 1)
    }

    @Test("Custom initial devices are preserved")
    func customInitDevices() async {
        let custom = [
            AudioDevice(id: 50, name: "USB Condenser", isDefault: true),
            AudioDevice(id: 51, name: "Bluetooth Headset"),
            AudioDevice(id: 52, name: "Virtual Cable"),
        ]
        let provider = MockAudioDeviceProvider(devices: custom)
        let devices = await provider.availableDevices()

        #expect(devices.count == 3)
        #expect(devices[0].name == "USB Condenser")
        #expect(devices[1].name == "Bluetooth Headset")
        #expect(devices[2].name == "Virtual Cable")
    }

    @Test("Provider conforms to AudioDeviceProviding")
    func protocolConformance() {
        let provider = MockAudioDeviceProvider()
        let _: any AudioDeviceProviding = provider
    }
}
