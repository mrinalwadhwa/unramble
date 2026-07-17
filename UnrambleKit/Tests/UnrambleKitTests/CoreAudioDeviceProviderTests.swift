import Foundation
import Testing

@testable import UnrambleKit

@Suite("CoreAudioDeviceProvider")
struct CoreAudioDeviceProviderTests {

    @Test("Conforms to AudioDeviceProviding")
    func protocolConformance() {
        let provider = CoreAudioDeviceProvider()
        let _: any AudioDeviceProviding = provider
    }

    @Test("Available devices have valid names and IDs")
    func availableDevices() async {
        let provider = CoreAudioDeviceProvider()
        let devices = await provider.availableDevices()

        // Headless machines and VMs may have no input devices.
        guard !devices.isEmpty else { return }

        for device in devices {
            #expect(!device.name.isEmpty, "Device name should not be empty")
            #expect(device.id != 0, "Device ID should not be zero")
        }
    }

    @Test("Exactly one device is marked as default when devices exist")
    func exactlyOneDefault() async {
        let provider = CoreAudioDeviceProvider()
        let devices = await provider.availableDevices()

        guard !devices.isEmpty else { return }

        let defaults = devices.filter { $0.isDefault }
        #expect(
            defaults.count == 1, "Expected exactly one default input device, got \(defaults.count)")
    }

    @Test("Current device returns the default when no selection is made")
    func currentDeviceDefault() async {
        let provider = CoreAudioDeviceProvider()
        let devices = await provider.availableDevices()

        guard !devices.isEmpty else { return }

        let current = await provider.currentDevice()
        #expect(current != nil, "Expected a current device")
        #expect(
            current?.isDefault == true,
            "Current device should be the default when nothing is selected")
    }

    @Test("Select device changes current device")
    func selectDevice() async throws {
        let provider = CoreAudioDeviceProvider()
        let devices = await provider.availableDevices()

        guard let target = devices.first else { return }

        try await provider.selectDevice(id: target.id)

        let current = await provider.currentDevice()
        #expect(current?.id == target.id, "Current device should match the selected device")
    }

    @Test("Select non-existent device throws deviceNotFound")
    func selectNonExistentDevice() async {
        let provider = CoreAudioDeviceProvider()

        do {
            try await provider.selectDevice(id: 999_999)
            Issue.record("Expected error for non-existent device ID")
        } catch let error as CoreAudioDeviceError {
            if case .deviceNotFound(let id) = error {
                #expect(id == 999_999)
            } else {
                Issue.record("Expected deviceNotFound, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Clear selection reverts to system default")
    func clearSelection() async throws {
        let provider = CoreAudioDeviceProvider()
        let devices = await provider.availableDevices()

        guard let nonDefault = devices.first(where: { !$0.isDefault }) else {
            // Only one device on this machine; skip this test.
            return
        }

        try await provider.selectDevice(id: nonDefault.id)
        let afterSelect = await provider.currentDevice()
        #expect(afterSelect?.id == nonDefault.id)

        provider.clearSelection()
        let afterClear = await provider.currentDevice()
        #expect(
            afterClear?.isDefault == true,
            "After clearing selection, current device should be the default")
    }

    @Test("selectedDeviceID reflects selection state")
    func selectedDeviceIDProperty() async throws {
        let provider = CoreAudioDeviceProvider()
        #expect(provider.selectedDeviceID == nil, "Initially no device should be selected")

        let devices = await provider.availableDevices()
        // Pick a non-default device so selectDevice doesn't clear
        // the selection (selecting the system default is a no-op).
        guard let device = devices.first(where: { !$0.isDefault }) ?? devices.first else { return }

        try await provider.selectDevice(id: device.id)
        #expect(provider.selectedDeviceID == device.id)

        provider.clearSelection()
        #expect(provider.selectedDeviceID == nil)
    }

    @Test("Device IDs are unique")
    func uniqueDeviceIDs() async {
        let provider = CoreAudioDeviceProvider()
        let devices = await provider.availableDevices()

        let ids = devices.map { $0.id }
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count, "Device IDs should be unique")
    }

    @Test("Multiple providers see the same devices")
    func multipleProviders() async {
        let providerA = CoreAudioDeviceProvider()
        let providerB = CoreAudioDeviceProvider()

        let devicesA = await providerA.availableDevices()
        let devicesB = await providerB.availableDevices()

        #expect(devicesA == devicesB, "Two providers should enumerate the same devices")
    }

    @Test("Selecting a device on one provider does not affect another")
    func selectionIsolation() async throws {
        let providerA = CoreAudioDeviceProvider()
        let providerB = CoreAudioDeviceProvider()

        let devices = await providerA.availableDevices()
        // Pick a non-default device so selectDevice doesn't clear
        // the selection (selecting the system default is a no-op).
        guard let device = devices.first(where: { !$0.isDefault }) ?? devices.first else { return }

        try await providerA.selectDevice(id: device.id)
        #expect(providerA.selectedDeviceID == device.id)
        #expect(providerB.selectedDeviceID == nil, "Selection should not leak across providers")
    }
}
