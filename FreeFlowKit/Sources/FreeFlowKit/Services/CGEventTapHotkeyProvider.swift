import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

#if canImport(Carbon)
    import Carbon.HIToolbox
#endif

/// Register a global hotkey listener via CGEventTap.
///
/// Creates a passive CGEventTap that monitors `.flagsChanged` events
/// system-wide. When the configured hotkey is pressed or released, the
/// registered callback fires with `.pressed` or `.released`.
///
/// Supports two hotkey modes:
/// - Modifier-only keys (e.g., Right Option, Right Command)
/// - Modifier + key combinations (e.g., Cmd+Shift+D)
///
/// Requires the app to be trusted for accessibility (`AXIsProcessTrusted`).
public final class CGEventTapHotkeyProvider: HotkeyProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var callback: (@Sendable (HotkeyEvent, UInt64) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var _isHotkeyDown = false

    /// The retained self-pointer passed to the CGEventTap callback.
    /// Stored so `tearDownTap` can release it, preventing a dangling
    /// pointer if the provider is deallocated while events are in flight.
    /// Visible for testing retain-balance correctness.
    private(set) var retainedSelfPointer: UnsafeMutableRawPointer?

    /// The current hotkey configuration.
    private var _hotkeySetting: HotkeySetting = .default

    public init() {}

    deinit {
        unregister()
    }

    // MARK: - Configuration

    /// The current hotkey setting. Read-only; use `register(with:callback:)`
    /// to change the hotkey.
    public var hotkeySetting: HotkeySetting {
        lock.withLock { _hotkeySetting }
    }

    // MARK: - HotkeyProviding

    /// Register a global hotkey listener with the default (persisted) hotkey.
    public func register(callback: @escaping @Sendable (HotkeyEvent) -> Void) throws {
        try registerTimestamped { event, _ in callback(event) }
    }

    public func registerTimestamped(
        callback: @escaping @Sendable (HotkeyEvent, UInt64) -> Void
    ) throws {
        try registerTimestamped(
            with: Settings.shared.hotkeySetting,
            callback: callback)
    }

    /// Register a global hotkey listener with a specific hotkey configuration.
    ///
    /// - Parameters:
    ///   - setting: The hotkey configuration to use.
    ///   - callback: Called with `.pressed` on key-down and `.released` on key-up.
    /// - Throws: If the event tap cannot be created (e.g. accessibility permission not granted).
    public func register(
        with setting: HotkeySetting,
        callback: @escaping @Sendable (HotkeyEvent) -> Void
    ) throws {
        try registerTimestamped(with: setting) { event, _ in callback(event) }
    }

    private func registerTimestamped(
        with setting: HotkeySetting,
        callback: @escaping @Sendable (HotkeyEvent, UInt64) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        // Remove any existing tap before creating a new one.
        tearDownTap()

        self._hotkeySetting = setting
        self.callback = callback
        self._isHotkeyDown = false

        #if canImport(ApplicationServices)
            // Verify accessibility permission before attempting to create the tap.
            guard AXIsProcessTrusted() else {
                throw HotkeyRegistrationError.accessibilityNotGranted
            }

            // Determine which events to monitor based on hotkey type.
            var eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            if !setting.isModifierOnly {
                eventMask |= (1 << CGEventType.keyDown.rawValue)
                eventMask |= (1 << CGEventType.keyUp.rawValue)
            }

            // Retain self so the C callback always has a valid pointer,
            // even if events are in flight when tearDownTap runs.
            // The balancing release happens in tearDownTap.
            let selfPointer = Unmanaged.passRetained(self).toOpaque()
            self.retainedSelfPointer = selfPointer

            guard
                let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: eventMask,
                    callback: cgEventCallback,
                    userInfo: selfPointer
                )
            else {
                throw HotkeyRegistrationError.tapCreationFailed
            }

            self.eventTap = tap

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source

            // Run the event tap on a dedicated background thread so it doesn't
            // block the main thread or depend on the caller's run loop.
            let thread = Thread { [weak self] in
                guard let self, let source else { return }
                let rl = CFRunLoopGetCurrent()
                self.lock.lock()
                self.tapRunLoop = rl
                self.lock.unlock()
                CFRunLoopAddSource(rl, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                CFRunLoopRun()
            }
            thread.name = "app.freeflow.hotkey"
            thread.qualityOfService = .userInteractive
            self.tapThread = thread
            thread.start()
        #else
            throw HotkeyRegistrationError.tapCreationFailed
        #endif
    }

    public func unregister() {
        lock.lock()
        defer { lock.unlock() }
        tearDownTap()
    }

    // MARK: - Internal

    /// Re-enable the event tap if the system disabled it. Called from the
    /// CGEventTap C callback when a `.tapDisabledByTimeout` or
    /// `.tapDisabledByUserInput` event arrives.
    fileprivate func reEnableTap() {
        lock.lock()
        let tap = eventTap
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Handle a flags-changed event for modifier-only hotkeys.
    fileprivate func handleFlagsChanged(_ event: CGEvent) {
        lock.lock()
        let setting = _hotkeySetting
        let wasDown = _isHotkeyDown
        let cb = callback
        lock.unlock()

        // Only handle modifier-only hotkeys here.
        guard case .modifierOnly(let modifierKey) = setting else {
            return
        }

        let flags = event.flags.rawValue
        let deviceFlag = modifierKey.deviceFlag

        // Check the device-dependent flags for the specific modifier.
        let hotkeyPressed = (flags & deviceFlag) != 0

        if hotkeyPressed && !wasDown {
            lock.lock()
            _isHotkeyDown = true
            lock.unlock()
            cb?(
                .pressed,
                AudioCaptureReleaseFence.hostTime(
                    eventTimestampNanoseconds: event.timestamp))
        } else if !hotkeyPressed && wasDown {
            lock.lock()
            _isHotkeyDown = false
            lock.unlock()
            cb?(
                .released,
                AudioCaptureReleaseFence.hostTime(
                    eventTimestampNanoseconds: event.timestamp))
        }
    }

    // Device-independent modifier flag mask (removes device-specific bits).
    // This is the same as NSEvent.ModifierFlags.deviceIndependentFlagsMask.
    private static let deviceIndependentFlagsMask: UInt64 = 0xFFFF_0000

    /// Handle a key event for modifier+key hotkeys.
    fileprivate func handleKeyEvent(_ event: CGEvent, isKeyDown: Bool) {
        lock.lock()
        let setting = _hotkeySetting
        let wasDown = _isHotkeyDown
        let cb = callback
        lock.unlock()

        // Only handle modifier+key hotkeys here.
        guard case .modifierPlusKey(let expectedFlags, let expectedKeyCode, _) = setting
        else {
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // Mask to device-independent flags, then isolate the four standard
        // modifier bits (Control, Option, Shift, Command). This ignores
        // Caps Lock, Fn, NumericPad, and other flags that vary by keyboard.
        let standardModifierMask: UInt = 0x001E_0000
        let flags =
            UInt(event.flags.rawValue & Self.deviceIndependentFlagsMask) & standardModifierMask

        // Check if this is the configured key with exactly the right modifiers.
        // Using exact match so that ⌃/ does not fire when ⌃⌥/ is pressed.
        let keyMatches = keyCode == expectedKeyCode
        let modifiersMatch = flags == (expectedFlags & standardModifierMask)

        if isKeyDown && keyMatches && modifiersMatch && !wasDown {
            lock.lock()
            _isHotkeyDown = true
            lock.unlock()
            cb?(
                .pressed,
                AudioCaptureReleaseFence.hostTime(
                    eventTimestampNanoseconds: event.timestamp))
        } else if !isKeyDown && wasDown {
            // On key up, only check the key code (modifiers may have been released).
            if keyMatches {
                lock.lock()
                _isHotkeyDown = false
                lock.unlock()
                cb?(
                    .released,
                    AudioCaptureReleaseFence.hostTime(
                        eventTimestampNanoseconds: event.timestamp))
            }
        }
    }

    /// Tear down the event tap and its run loop. Must be called with the lock held.
    private func tearDownTap() {
        callback = nil
        _isHotkeyDown = false

        #if canImport(ApplicationServices)
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
        #endif

        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }

        if let source = runLoopSource, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, source, .commonModes)
        }

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        // Release the retained self-pointer now that the mach port is
        // invalidated and no more callbacks can fire.
        if let pointer = retainedSelfPointer {
            Unmanaged<CGEventTapHotkeyProvider>.fromOpaque(pointer)
                .release()
            retainedSelfPointer = nil
        }

        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
    }
}

// MARK: - CGEventTap C callback

#if canImport(ApplicationServices)
    /// The C-compatible callback invoked by the CGEventTap.
    ///
    /// Extracts the `CGEventTapHotkeyProvider` instance from `userInfo` and
    /// forwards events to the appropriate handler based on type.
    private func cgEventCallback(
        proxy _: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent,
        userInfo: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let provider = Unmanaged<CGEventTapHotkeyProvider>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        switch type {
        case .flagsChanged:
            provider.handleFlagsChanged(event)
        case .keyDown:
            provider.handleKeyEvent(event, isKeyDown: true)
        case .keyUp:
            provider.handleKeyEvent(event, isKeyDown: false)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable the tap if the system disables it.
            provider.reEnableTap()
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
#endif

// MARK: - Errors

/// Errors that can occur when registering the global hotkey.
public enum HotkeyRegistrationError: Error, Sendable, CustomStringConvertible {
    /// The app is not trusted for accessibility. The user must grant access
    /// in System Settings > Privacy & Security > Accessibility.
    case accessibilityNotGranted
    /// Failed to create the CGEventTap. This can happen if another process
    /// has exclusive control or the system is in a restricted state.
    case tapCreationFailed

    public var description: String {
        switch self {
        case .accessibilityNotGranted:
            return
                "Accessibility permission not granted. Open System Settings > Privacy & Security > Accessibility."
        case .tapCreationFailed:
            return "Failed to create global event tap"
        }
    }
}
