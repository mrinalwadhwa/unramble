import Foundation
import Testing

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

@testable import FreeFlowKit

@Suite("CGEventTapHotkeyProvider")
struct CGEventTapHotkeyProviderTests {

    @Test("Unregister clears the retained callback-context pointer")
    func unregisterClearsCallbackContextPointer() {
        let provider = CGEventTapHotkeyProvider()

        // Before registration, no retained pointer exists.
        #expect(provider.retainedCallbackContextPointer == nil)

        // Try to register. This will fail without accessibility permission,
        // which is expected in CI/test environments.
        do {
            try provider.register { _ in }
            // Registration succeeded — a retained pointer should exist.
            #expect(provider.retainedCallbackContextPointer != nil)

            provider.unregister()

            // After unregister, the retained pointer must be released.
            #expect(
                provider.retainedCallbackContextPointer == nil,
                "tearDownTap must release the retained callback context")
        } catch {
            // Accessibility not granted — tap creation failed.
            // Verify no pointer was leaked.
            #expect(provider.retainedCallbackContextPointer == nil)
        }
    }

    @Test("Double unregister does not crash")
    func doubleUnregister() {
        let provider = CGEventTapHotkeyProvider()
        try? provider.register { _ in }
        provider.unregister()
        provider.unregister()
        // No crash = success.
    }

    @Test("Tap thread retains its callback context while running")
    func tapThreadRetainsCallbackContextWhileRunning() {
        let operationStarted = DispatchSemaphore(value: 0)
        let finishOperation = DispatchSemaphore(value: 0)
        var probe: CallbackContextLifetimeProbe? = .init()
        weak let weakProbe = probe
        let rawPointer = Unmanaged.passRetained(probe!).toOpaque()
        let thread = CGEventTapHotkeyProvider.makeCallbackContextThread(
            retaining: probe!
        ) {
            operationStarted.signal()
            finishOperation.wait()
        }
        probe = nil

        thread.start()
        let started = operationStarted.wait(timeout: .now() + 1)
        Unmanaged<CallbackContextLifetimeProbe>.fromOpaque(rawPointer)
            .release()

        #expect(started == .success)
        #expect(
            weakProbe != nil,
            "The run-loop thread must outlive teardown's raw-pointer release")

        finishOperation.signal()
        let deadline = Date().addingTimeInterval(1)
        while !thread.isFinished, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(thread.isFinished)
    }

    #if canImport(ApplicationServices)
        @Test("Duplicate and autorepeat key-down events emit one press")
        func duplicateAndAutorepeatKeyDownEmitOnce() throws {
            let recorder = HotkeyEventRecorder()
            let provider = CGEventTapHotkeyProvider(
                testing: Self.modeShortcut
            ) { event, _ in
                recorder.append(event)
            }

            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: true),
                isKeyDown: true)
            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: true),
                isKeyDown: true)

            #expect(recorder.events == [.pressed])

            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: false, flags: []),
                isKeyDown: false)
            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: true, isAutorepeat: true),
                isKeyDown: true)

            #expect(
                recorder.events == [.pressed, .released],
                "An autorepeat must not begin a new physical press")
        }

        @Test("Key-up without modifiers rearms the next physical press")
        func modifierReleasedBeforeKeyUpRearmsNextPress() throws {
            let recorder = HotkeyEventRecorder()
            let provider = CGEventTapHotkeyProvider(
                testing: Self.modeShortcut
            ) { event, _ in
                recorder.append(event)
            }

            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: true),
                isKeyDown: true)
            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: false, flags: []),
                isKeyDown: false)
            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: true),
                isKeyDown: true)

            #expect(recorder.events == [.pressed, .released, .pressed])
        }

        @Test("A stale registration callback cannot arm its replacement")
        func staleRegistrationCannotArmReplacement() throws {
            let staleRecorder = HotkeyEventRecorder()
            let currentRecorder = HotkeyEventRecorder()
            let provider = CGEventTapHotkeyProvider(
                testing: Self.modeShortcut
            ) { event, _ in
                staleRecorder.append(event)
            }
            let staleGeneration = provider.registrationGenerationForTesting
            let currentGeneration = provider.replaceRegistrationForTesting(
                setting: Self.modeShortcut
            ) { event, _ in
                currentRecorder.append(event)
            }

            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: true),
                isKeyDown: true,
                registrationGeneration: staleGeneration)
            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: false, flags: []),
                isKeyDown: false,
                registrationGeneration: staleGeneration)

            #expect(staleRecorder.events.isEmpty)
            #expect(currentRecorder.events.isEmpty)

            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: true),
                isKeyDown: true,
                registrationGeneration: currentGeneration)
            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: false, flags: []),
                isKeyDown: false,
                registrationGeneration: currentGeneration)

            #expect(currentRecorder.events == [.pressed, .released])
        }

        @Test("A stale key-up cannot rearm a held replacement registration")
        func staleReleaseCannotRearmReplacement() throws {
            let recorder = HotkeyEventRecorder()
            let provider = CGEventTapHotkeyProvider(
                testing: Self.modeShortcut
            ) { _, _ in }
            let staleGeneration = provider.registrationGenerationForTesting
            let currentGeneration = provider.replaceRegistrationForTesting(
                setting: Self.modeShortcut
            ) { event, _ in
                recorder.append(event)
            }

            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: true),
                isKeyDown: true,
                registrationGeneration: currentGeneration)
            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: false, flags: []),
                isKeyDown: false,
                registrationGeneration: staleGeneration)
            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: true),
                isKeyDown: true,
                registrationGeneration: currentGeneration)
            provider.handleKeyEvent(
                try Self.keyEvent(keyDown: false, flags: []),
                isKeyDown: false,
                registrationGeneration: currentGeneration)

            #expect(recorder.events == [.pressed, .released])
        }

        @Test("A stale modifier callback cannot release held Right Option")
        func staleModifierCannotReleaseReplacement() throws {
            let recorder = HotkeyEventRecorder()
            let provider = CGEventTapHotkeyProvider(
                testing: .rightOption
            ) { _, _ in }
            let staleGeneration = provider.registrationGenerationForTesting
            let currentGeneration = provider.replaceRegistrationForTesting(
                setting: .rightOption
            ) { event, _ in
                recorder.append(event)
            }
            let rightOptionDown = try Self.flagsEvent(
                rawFlags: HotkeySetting.ModifierKey.rightOption.deviceFlag)
            let rightOptionUp = try Self.flagsEvent(rawFlags: 0)

            provider.handleFlagsChanged(
                rightOptionDown,
                registrationGeneration: currentGeneration)
            provider.handleFlagsChanged(
                rightOptionUp,
                registrationGeneration: staleGeneration)
            provider.handleFlagsChanged(
                rightOptionDown,
                registrationGeneration: currentGeneration)
            provider.handleFlagsChanged(
                rightOptionUp,
                registrationGeneration: currentGeneration)

            #expect(recorder.events == [.pressed, .released])
        }

        private static let modeShortcut = HotkeySetting.modifierPlusKey(
            modifierFlags: ShortcutBinding.controlFlag | ShortcutBinding.shiftFlag,
            keyCode: 46,
            keyName: "M")

        private static func keyEvent(
            keyDown: Bool,
            flags: CGEventFlags = [.maskControl, .maskShift],
            isAutorepeat: Bool = false
        ) throws -> CGEvent {
            let event = try #require(
                CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: 46,
                    keyDown: keyDown))
            event.flags = flags
            event.setIntegerValueField(
                .keyboardEventAutorepeat,
                value: isAutorepeat ? 1 : 0)
            return event
        }

        private static func flagsEvent(rawFlags: UInt64) throws -> CGEvent {
            let event = try #require(CGEvent(source: nil))
            event.flags = CGEventFlags(rawValue: rawFlags)
            return event
        }
    #endif
}

private final class HotkeyEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [HotkeyEvent] = []

    var events: [HotkeyEvent] {
        lock.withLock { storedEvents }
    }

    func append(_ event: HotkeyEvent) {
        lock.withLock { storedEvents.append(event) }
    }
}

private final class CallbackContextLifetimeProbe: @unchecked Sendable {}
