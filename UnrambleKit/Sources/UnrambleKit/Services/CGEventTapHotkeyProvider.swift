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

    private typealias TimestampedCallback =
        @Sendable (HotkeyEvent, UInt64) -> Void

    private let lock = NSLock()
    private var callback: TimestampedCallback?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var _isHotkeyDown = false
    private var nextRegistrationGeneration: UInt64 = 0
    private var activeRegistrationGeneration: UInt64?

    /// The raw ownership of the callback context passed to CGEventTap.
    /// The tap thread separately retains the context across active callbacks.
    /// Visible for testing retain-balance correctness.
    private(set) var retainedCallbackContextPointer: UnsafeMutableRawPointer?

    /// The current hotkey configuration.
    private var _hotkeySetting: HotkeySetting = .default

    public init() {}

    init(
        testing setting: HotkeySetting,
        callback: @escaping @Sendable (HotkeyEvent, UInt64) -> Void
    ) {
        nextRegistrationGeneration = 1
        activeRegistrationGeneration = 1
        _hotkeySetting = setting
        self.callback = callback
    }

    var registrationGenerationForTesting: UInt64 {
        lock.withLock {
            guard let activeRegistrationGeneration else {
                preconditionFailure("Testing registration is not active")
            }
            return activeRegistrationGeneration
        }
    }

    @discardableResult
    func replaceRegistrationForTesting(
        setting: HotkeySetting,
        callback: @escaping @Sendable (HotkeyEvent, UInt64) -> Void
    ) -> UInt64 {
        lock.withLock {
            invalidateRegistrationStateLocked()
            return beginRegistrationLocked(
                setting: setting,
                callback: callback)
        }
    }

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

        #if canImport(ApplicationServices)
            // Verify accessibility permission before attempting to create the tap.
            guard AXIsProcessTrusted() else {
                throw HotkeyRegistrationError.accessibilityNotGranted
            }

            let registrationGeneration = beginRegistrationLocked(
                setting: setting,
                callback: callback)

            // Determine which events to monitor based on hotkey type.
            var eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            if !setting.isModifierOnly {
                eventMask |= (1 << CGEventType.keyDown.rawValue)
                eventMask |= (1 << CGEventType.keyUp.rawValue)
            }

            // Each tap carries the generation it was created for. An old C
            // callback can therefore never read or mutate replacement state.
            let callbackContext = EventTapCallbackContext(
                provider: self,
                registrationGeneration: registrationGeneration)
            let contextPointer = Unmanaged.passRetained(callbackContext)
                .toOpaque()
            retainedCallbackContextPointer = contextPointer

            guard
                let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: eventMask,
                    callback: cgEventCallback,
                    userInfo: contextPointer
                )
            else {
                tearDownTap()
                throw HotkeyRegistrationError.tapCreationFailed
            }

            self.eventTap = tap

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source

            // Run the event tap on a dedicated background thread so it doesn't
            // block the main thread or depend on the caller's run loop.
            let thread = Self.makeCallbackContextThread(
                retaining: callbackContext
            ) { [weak self] in
                guard let source else { return }
                guard let rl = CFRunLoopGetCurrent() else { return }
                guard
                    self?.publishTapRunLoop(
                        rl,
                        registrationGeneration: registrationGeneration) == true
                else { return }
                CFRunLoopAddSource(rl, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                CFRunLoopRun()
            }
            thread.name = "app.unramble.hotkey"
            thread.qualityOfService = .userInteractive
            self.tapThread = thread
            thread.start()
        #else
            _hotkeySetting = setting
            throw HotkeyRegistrationError.tapCreationFailed
        #endif
    }

    public func unregister() {
        lock.lock()
        defer { lock.unlock() }
        tearDownTap()
    }

    // MARK: - Internal

    static func makeCallbackContextThread<Context: AnyObject & Sendable>(
        retaining context: Context,
        operation: @escaping @Sendable () -> Void
    ) -> Thread {
        Thread {
            // Invariant: event-tap userInfo outlives the run-loop callout,
            // even when teardown releases its raw ownership concurrently.
            withExtendedLifetime(context) {
                operation()
            }
        }
    }

    /// Re-enable the event tap if the system disabled it. Called from the
    /// CGEventTap C callback when a `.tapDisabledByTimeout` or
    /// `.tapDisabledByUserInput` event arrives.
    fileprivate func reEnableTap(registrationGeneration: UInt64) {
        let tap: CFMachPort? = lock.withLock {
            guard activeRegistrationGeneration == registrationGeneration else {
                return nil
            }
            return eventTap
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Handle a flags-changed event for modifier-only hotkeys.
    fileprivate func handleFlagsChanged(_ event: CGEvent) {
        guard let registrationGeneration = lock.withLock({
            activeRegistrationGeneration
        }) else { return }
        handleFlagsChanged(
            event,
            registrationGeneration: registrationGeneration)
    }

    func handleFlagsChanged(
        _ event: CGEvent,
        registrationGeneration: UInt64
    ) {
        let flags = event.flags.rawValue
        let emission: (TimestampedCallback, HotkeyEvent)? = lock.withLock {
            guard activeRegistrationGeneration == registrationGeneration,
                case .modifierOnly(let modifierKey) = _hotkeySetting,
                let callback
            else { return nil }

            let hotkeyPressed = (flags & modifierKey.deviceFlag) != 0
            guard hotkeyPressed != _isHotkeyDown else { return nil }
            _isHotkeyDown = hotkeyPressed
            return (callback, hotkeyPressed ? .pressed : .released)
        }

        if let (callback, hotkeyEvent) = emission {
            callback(
                hotkeyEvent,
                AudioCaptureReleaseFence.hostTime(
                    eventTimestampNanoseconds: event.timestamp))
        }
    }

    // Device-independent modifier flag mask (removes device-specific bits).
    // This is the same as NSEvent.ModifierFlags.deviceIndependentFlagsMask.
    private static let deviceIndependentFlagsMask: UInt64 = 0xFFFF_0000

    /// Handle a key event for modifier+key hotkeys.
    func handleKeyEvent(_ event: CGEvent, isKeyDown: Bool) {
        guard let registrationGeneration = lock.withLock({
            activeRegistrationGeneration
        }) else { return }
        handleKeyEvent(
            event,
            isKeyDown: isKeyDown,
            registrationGeneration: registrationGeneration)
    }

    func handleKeyEvent(
        _ event: CGEvent,
        isKeyDown: Bool,
        registrationGeneration: UInt64
    ) {
        if isKeyDown,
            event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        {
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // Mask to device-independent flags, then isolate the four standard
        // modifier bits (Control, Option, Shift, Command). This ignores
        // Caps Lock, Fn, NumericPad, and other flags that vary by keyboard.
        let standardModifierMask: UInt = 0x001E_0000
        let flags =
            UInt(event.flags.rawValue & Self.deviceIndependentFlagsMask) & standardModifierMask

        let emission: (TimestampedCallback, HotkeyEvent)? = lock.withLock {
            guard activeRegistrationGeneration == registrationGeneration,
                case .modifierPlusKey(
                    let expectedFlags,
                    let expectedKeyCode,
                    _
                ) = _hotkeySetting,
                let callback
            else { return nil }

            let keyMatches = keyCode == expectedKeyCode
            if isKeyDown {
                let modifiersMatch = flags
                    == (expectedFlags & standardModifierMask)
                guard keyMatches, modifiersMatch, !_isHotkeyDown else {
                    return nil
                }
                _isHotkeyDown = true
                return (callback, .pressed)
            }

            // Modifiers may be released before the physical key-up.
            guard keyMatches, _isHotkeyDown else { return nil }
            _isHotkeyDown = false
            return (callback, .released)
        }

        if let (callback, hotkeyEvent) = emission {
            callback(
                hotkeyEvent,
                AudioCaptureReleaseFence.hostTime(
                    eventTimestampNanoseconds: event.timestamp))
        }
    }

    private func beginRegistrationLocked(
        setting: HotkeySetting,
        callback: @escaping TimestampedCallback
    ) -> UInt64 {
        nextRegistrationGeneration &+= 1
        let generation = nextRegistrationGeneration
        activeRegistrationGeneration = generation
        _hotkeySetting = setting
        self.callback = callback
        _isHotkeyDown = false
        return generation
    }

    private func invalidateRegistrationStateLocked() {
        activeRegistrationGeneration = nil
        callback = nil
        _isHotkeyDown = false
    }

    private func publishTapRunLoop(
        _ runLoop: CFRunLoop,
        registrationGeneration: UInt64
    ) -> Bool {
        lock.withLock {
            guard activeRegistrationGeneration == registrationGeneration else {
                return false
            }
            tapRunLoop = runLoop
            return true
        }
    }

    /// Tear down the event tap and its run loop. Must be called with the lock held.
    private func tearDownTap() {
        invalidateRegistrationStateLocked()

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

        // Release the retained callback context now that the mach port is
        // invalidated. Its generation has already been fenced above.
        if let pointer = retainedCallbackContextPointer {
            Unmanaged<EventTapCallbackContext>.fromOpaque(pointer)
                .release()
            retainedCallbackContextPointer = nil
        }

        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
    }
}

// MARK: - CGEventTap C callback

private final class EventTapCallbackContext: @unchecked Sendable {
    weak var provider: CGEventTapHotkeyProvider?
    let registrationGeneration: UInt64

    init(
        provider: CGEventTapHotkeyProvider,
        registrationGeneration: UInt64
    ) {
        self.provider = provider
        self.registrationGeneration = registrationGeneration
    }
}

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

        let context = Unmanaged<EventTapCallbackContext>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        guard let provider = context.provider else {
            return Unmanaged.passUnretained(event)
        }
        let registrationGeneration = context.registrationGeneration

        switch type {
        case .flagsChanged:
            provider.handleFlagsChanged(
                event,
                registrationGeneration: registrationGeneration)
        case .keyDown:
            provider.handleKeyEvent(
                event,
                isKeyDown: true,
                registrationGeneration: registrationGeneration)
        case .keyUp:
            provider.handleKeyEvent(
                event,
                isKeyDown: false,
                registrationGeneration: registrationGeneration)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable the tap if the system disables it.
            provider.reEnableTap(
                registrationGeneration: registrationGeneration)
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
