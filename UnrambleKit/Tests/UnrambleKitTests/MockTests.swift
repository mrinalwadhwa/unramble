import Foundation
import Testing

@testable import UnrambleKit

@Suite("Mock implementations")
struct MockTests {

    // MARK: - MockAudioProvider

    @Test("MockAudioProvider starts and stops recording")
    func audioProviderRecordingLifecycle() async throws {
        let provider = MockAudioProvider()

        #expect(!provider.isRecording)
        #expect(provider.startCallCount == 0)
        #expect(provider.stopCallCount == 0)

        try await provider.startRecording()
        #expect(provider.isRecording)
        #expect(provider.startCallCount == 1)

        let buffer = try await provider.stopRecording()
        #expect(!provider.isRecording)
        #expect(provider.stopCallCount == 1)
        #expect(buffer.sampleRate == 16000)
        #expect(buffer.channels == 1)
        #expect(buffer.duration == 1.0)
    }

    @Test("MockAudioProvider returns custom stubbed buffer")
    func audioProviderCustomBuffer() async throws {
        let custom = AudioBuffer(
            data: Data([1, 2, 3]), duration: 0.5, sampleRate: 44100, channels: 2)
        let provider = MockAudioProvider(stubbedBuffer: custom)

        try await provider.startRecording()
        let buffer = try await provider.stopRecording()

        #expect(buffer.sampleRate == 44100)
        #expect(buffer.channels == 2)
        #expect(buffer.duration == 0.5)
        #expect(buffer.data == Data([1, 2, 3]))
    }

    // MARK: - MockAppContextProvider

    @Test("MockAppContextProvider returns stub context")
    func appContextProviderReturnsStub() async {
        let provider = MockAppContextProvider()
        #expect(provider.readContextCallCount == 0)

        let context = await provider.readContext()
        #expect(provider.readContextCallCount == 1)
        #expect(context.bundleID == "com.apple.TextEdit")
        #expect(context.appName == "TextEdit")
        #expect(context.windowTitle == "Untitled")
    }

    @Test("MockAppContextProvider returns custom context")
    func appContextProviderCustomContext() async {
        let custom = AppContext(
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: "#general",
            focusedFieldContent: "typing here..."
        )
        let provider = MockAppContextProvider(context: custom)

        let context = await provider.readContext()
        #expect(context.bundleID == "com.tinyspeck.slackmacgap")
        #expect(context.focusedFieldContent == "typing here...")
    }

    @Test("MockAppContextProvider allows changing stub between calls")
    func appContextProviderMutableStub() async {
        let provider = MockAppContextProvider()

        let first = await provider.readContext()
        #expect(first.appName == "TextEdit")

        provider.stubbedContext = AppContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Example",
            browserURL: "https://example.com"
        )

        let second = await provider.readContext()
        #expect(second.appName == "Safari")
        #expect(second.browserURL == "https://example.com")
        #expect(provider.readContextCallCount == 2)
    }

    // MARK: - MockTextInjector

    @Test("MockTextInjector records injections")
    func textInjectorRecordsInjections() async throws {
        let injector = MockTextInjector()
        #expect(injector.injectionCount == 0)
        #expect(injector.lastInjectedText == nil)

        let context = AppContext.stub
        try await injector.inject(text: "Hello world", into: context)

        #expect(injector.injectionCount == 1)
        #expect(injector.lastInjectedText == "Hello world")

        try await injector.inject(text: "Second injection", into: context)
        #expect(injector.injectionCount == 2)
        #expect(injector.lastInjectedText == "Second injection")
    }

    @Test("MockTextInjector reset clears history")
    func textInjectorReset() async throws {
        let injector = MockTextInjector()
        try await injector.inject(text: "test", into: .stub)
        #expect(injector.injectionCount == 1)

        injector.reset()
        #expect(injector.injectionCount == 0)
        #expect(injector.lastInjectedText == nil)
    }

    // MARK: - MockHotkeyProvider

    @Test("MockHotkeyProvider register and unregister lifecycle")
    func hotkeyProviderLifecycle() throws {
        let provider = MockHotkeyProvider()
        #expect(!provider.isRegistered)

        nonisolated(unsafe) var events: [HotkeyEvent] = []
        try provider.register { event in
            events.append(event)
        }
        #expect(provider.isRegistered)

        provider.simulatePress()
        provider.simulateRelease()
        #expect(events == [.pressed, .released])

        provider.unregister()
        #expect(!provider.isRegistered)

        // Events should not be delivered after unregister
        provider.simulatePress()
        #expect(events.count == 2)
    }

    @Test("MockHotkeyProvider replaces callback on re-register")
    func hotkeyProviderReplaceCallback() throws {
        let provider = MockHotkeyProvider()
        nonisolated(unsafe) var firstEvents: [HotkeyEvent] = []
        nonisolated(unsafe) var secondEvents: [HotkeyEvent] = []

        try provider.register { event in firstEvents.append(event) }
        provider.simulatePress()
        #expect(firstEvents == [.pressed])

        try provider.register { event in secondEvents.append(event) }
        provider.simulatePress()

        // First callback should not receive new events
        #expect(firstEvents == [.pressed])
        #expect(secondEvents == [.pressed])
    }

    // MARK: - MockPermissionProvider

    @Test("MockPermissionProvider defaults to granted")
    func permissionProviderDefaults() {
        let provider = MockPermissionProvider()
        #expect(provider.checkMicrophone() == .granted)
        #expect(provider.checkAccessibility() == .granted)
    }

    @Test("MockPermissionProvider microphone request grants when not determined")
    func permissionProviderMicRequest() async {
        let provider = MockPermissionProvider(microphoneState: .notDetermined)
        #expect(provider.checkMicrophone() == .notDetermined)

        let result = await provider.requestMicrophone()
        #expect(result == .granted)
        #expect(provider.checkMicrophone() == .granted)
    }

    @Test("MockPermissionProvider microphone request preserves denied state")
    func permissionProviderMicDenied() async {
        let provider = MockPermissionProvider(microphoneState: .denied)

        let result = await provider.requestMicrophone()
        #expect(result == .denied)
    }

    @Test("MockPermissionProvider tracks accessibility settings opened")
    func permissionProviderOpenSettings() {
        let provider = MockPermissionProvider()
        #expect(!provider.didOpenAccessibilitySettings)

        provider.openAccessibilitySettings()
        #expect(provider.didOpenAccessibilitySettings)
    }

    // MARK: - AppContext

    @Test("AppContext.empty has blank fields")
    func appContextEmpty() {
        let context = AppContext.empty
        #expect(context.bundleID == "")
        #expect(context.appName == "")
        #expect(context.windowTitle == "")
        #expect(context.browserURL == nil)
        #expect(context.focusedFieldContent == nil)
        #expect(context.selectedText == nil)
        #expect(context.cursorPosition == nil)
    }

    @Test("AppContext.stub has populated fields")
    func appContextStub() {
        let context = AppContext.stub
        #expect(!context.bundleID.isEmpty)
        #expect(!context.appName.isEmpty)
        #expect(context.focusedFieldContent != nil)
    }

    // MARK: - AudioBuffer

    @Test("AudioBuffer.empty has zero duration and empty data")
    func audioBufferEmpty() {
        let buffer = AudioBuffer.empty
        #expect(buffer.data.isEmpty)
        #expect(buffer.duration == 0)
        #expect(buffer.sampleRate == 16000)
        #expect(buffer.channels == 1)
        #expect(buffer.bitsPerSample == 16)
    }

    @Test("AudioBuffer uses sensible defaults")
    func audioBufferDefaults() {
        let buffer = AudioBuffer(data: Data([0, 1, 2]), duration: 0.1)
        #expect(buffer.sampleRate == 16000)
        #expect(buffer.channels == 1)
        #expect(buffer.bitsPerSample == 16)
    }
}
