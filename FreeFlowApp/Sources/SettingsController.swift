import AppKit
import FreeFlowKit

/// Coordinate the settings web page with native services.
///
/// Follows the same pattern as `OnboardingController`: owns a bridge
/// and a window, wires bridge actions to native service calls, and
/// pushes state back to the web page via bridge events.
///
/// The settings page is a self-contained HTML file shipped in the app
/// bundle. It communicates with native code via the `SettingsBridge`
/// message handler. All settings state is local to the app
/// (UserDefaults, Keychain) and does not require server auth.
@MainActor
final class SettingsController {

    private let bridge: SettingsBridge
    private var window: SettingsWindow?

    /// The audio device provider for mic selection, set by AppDelegate.
    var audioDeviceProvider: CoreAudioDeviceProvider?

    /// Shared owner of microphone preview demand, set by AppDelegate.
    var microphoneCaptureCoordinator: MicrophoneCaptureCoordinator?

    /// The dictation pipeline for applying language changes, set by AppDelegate.
    weak var pipeline: DictationPipeline?

    /// Callback invoked when the hotkey setting changes.
    /// The AppDelegate should use this to re-register the hotkey provider.
    var onHotkeyChanged: (() -> Void)?

    /// Callback invoked after the private-mode shortcut is accepted.
    /// The AppDelegate should use this to re-register its mode hotkey provider.
    var onModeShortcutChanged: (() -> Void)?

    /// Callback invoked when a different dictation mode is requested. The
    /// AppDelegate owns publication and persistence of the installed backend.
    var onDictationModeChanged: ((_ mode: DictationMode) -> Void)?

    /// Callback invoked when the user clicks Reset in settings.
    /// The AppDelegate should clear state and return to onboarding.
    var onResetApp: (() -> Void)?

    /// Device reads and writes are generation-fenced so an older bridge
    /// request cannot repaint the page after a newer selection.
    private var microphoneListTask: Task<Void, Never>?
    private var microphoneListGeneration: UInt64 = 0
    private var microphoneSelectionTask: Task<Void, Never>?
    private var microphoneSelectionGeneration: UInt64 = 0

    private var microphonePreviewClient: MicrophonePreviewClient?
    private var isPreviewWindowSessionActive = false
    private var isPreviewCaptureAvailable = false

    // MARK: - Initialization

    init() {
        self.bridge = SettingsBridge()

        setupBridgeHandlers()
    }

    // MARK: - Window management

    /// Show the settings window, creating it if necessary.
    ///
    /// Loads the bundled settings page from the app bundle. If the
    /// window already exists, it brings it to the front and reloads
    /// the page to refresh state.
    func showWindow() {
        isPreviewWindowSessionActive = true
        // Treat every page load as a new bridge session. An operation started
        // by the previous page must not publish into the reloaded page.
        invalidateMicrophoneDeviceTasks()

        if let existingWindow = window {
            // Reload bundled page to refresh state, then present.
            // The JS init() will send startMicPreview via the bridge
            // once the page loads, so we don't start it here — doing
            // both causes a race where the second stop/start kills
            // the first preview mid-stream.
            existingWindow.loadBundledSettings()
            existingWindow.present()
            return
        }

        let win = SettingsWindow(bridge: bridge)
        bridge.webView = win.webView
        win.onClose = { [weak self] in
            guard let self else { return }
            self.isPreviewWindowSessionActive = false
            self.invalidateMicrophoneDeviceTasks()
            self.stopMicPreviewSync()
        }
        window = win

        win.loadBundledSettings()
        win.present()
    }

    /// Close the settings window and stop mic preview.
    func closeWindow() {
        isPreviewWindowSessionActive = false
        invalidateMicrophoneDeviceTasks()
        stopMicPreviewSync()
        window?.orderOut(nil)
    }

    /// Whether the settings window is currently visible.
    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Bridge wiring

    private func setupBridgeHandlers() {
        bridge.onGetSettings = { [weak self] in
            self?.handleGetSettings()
        }

        bridge.onSetSoundFeedback = { [weak self] enabled in
            self?.handleSetSoundFeedback(enabled: enabled)
        }

        bridge.onSetShortcut = { [weak self] shortcut, data in
            self?.handleSetShortcut(shortcut: shortcut, data: data)
        }

        bridge.onSetLanguage = { [weak self] code in
            self?.handleSetLanguage(code: code)
        }

        bridge.onSetDictationMode = { [weak self] mode in
            self?.handleSetDictationMode(mode: mode)
        }

        bridge.onListMicrophones = { [weak self] in
            self?.handleListMicrophones()
        }

        bridge.onSelectMicrophone = { [weak self] id in
            self?.handleSelectMicrophone(id: id)
        }

        bridge.onStartMicPreview = { [weak self] in
            self?.handleStartMicPreview()
        }

        bridge.onStopMicPreview = { [weak self] in
            self?.handleStopMicPreview()
        }

        bridge.onResetApp = { [weak self] in
            self?.handleResetApp()
        }

        bridge.onCloseSettings = { [weak self] in
            self?.closeWindow()
        }
    }

    // MARK: - Action: getSettings

    private func handleGetSettings() {
        pushCurrentSettingsState()
        bridge.pushSettingsIcons()
    }

    private func pushCurrentSettingsState() {
        let soundEnabled = Settings.shared.soundFeedbackEnabled
        let language = Settings.shared.language.rawValue

        // Build the full language list for the dropdown.
        let languages: [[String: String]] = LanguageSetting.allCases.map { setting in
            ["code": setting.rawValue, "name": setting.displayName]
        }

        // Build shortcut labels for all four keyboard shortcuts.
        let dictateLabel = Settings.shared.hotkeySetting.displayName
        let handsfreeLabel = Settings.shared.handsfreeShortcutLabel
        let pasteLabel = Settings.shared.pasteShortcutLabel
        let cancelLabel = Settings.shared.cancelShortcutLabel
        let privateModeLabel = Settings.shared.privateModeShortcutLabel

        bridge.pushSettingsState(
            soundFeedback: soundEnabled,
            shortcuts: [
                "dictate": dictateLabel,
                "handsfree": handsfreeLabel,
                "paste": pasteLabel,
                "cancel": cancelLabel,
                "privateMode": privateModeLabel,
            ],
            language: language,
            languages: languages
        )
    }

    // MARK: - Action: setSoundFeedback

    private func handleSetSoundFeedback(enabled: Bool) {
        Settings.shared.soundFeedbackEnabled = enabled
    }

    // MARK: - Action: setShortcut

    private func handleSetShortcut(shortcut: String, data: [String: Any]) {
        let label = data["label"] as? String ?? ""
        let type = data["type"] as? String ?? ""
        let settings = Settings.shared

        switch shortcut {
        case "dictate":
            let proposed: HotkeySetting
            if type == "modifier", let modId = data["modifierId"] as? String,
                let modifier = HotkeySetting.ModifierKey(rawValue: modId)
            {
                proposed = .modifierOnly(modifier)
            } else if type == "combo" {
                guard let keyCode = keyCodeFromData(data) else {
                    pushCurrentSettingsState()
                    return
                }
                let flags = modifierFlagsFromData(data)
                let keyName = keyNameFromData(data)
                proposed = .modifierPlusKey(
                    modifierFlags: flags, keyCode: keyCode, keyName: keyName)
            } else {
                // Multi-modifier-only shortcuts are not supported for
                // hold-to-talk dictation. Reject malformed bridge data too.
                #if DEBUG
                    Log.debug(
                        "[SettingsController] Rejecting unsupported '\(type)' type for dictate shortcut (label: \(label))"
                    )
                #endif
                pushCurrentSettingsState()
                return
            }

            let previous = settings.hotkeySetting
            settings.hotkeySetting = proposed
            guard settings.hotkeySetting == proposed else {
                pushCurrentSettingsState()
                return
            }
            if previous != proposed {
                onHotkeyChanged?()
            }

        case "handsfree":
            guard let binding = shortcutBindingFromData(data, label: label) else {
                pushCurrentSettingsState()
                return
            }
            settings.handsfreeShortcutBinding = binding
            guard settings.handsfreeShortcutBinding == binding else {
                pushCurrentSettingsState()
                return
            }

        case "paste":
            guard let binding = shortcutBindingFromData(data, label: label) else {
                pushCurrentSettingsState()
                return
            }
            settings.pasteShortcutBinding = binding
            guard settings.pasteShortcutBinding == binding else {
                pushCurrentSettingsState()
                return
            }

        case "cancel":
            guard let binding = shortcutBindingFromData(data, label: label) else {
                pushCurrentSettingsState()
                return
            }
            settings.cancelShortcutBinding = binding
            guard settings.cancelShortcutBinding == binding else {
                pushCurrentSettingsState()
                return
            }

        case "privateMode":
            guard let binding = shortcutBindingFromData(data, label: label) else {
                pushCurrentSettingsState()
                return
            }
            let previous = settings.privateModeShortcutBinding
            settings.privateModeShortcutBinding = binding
            guard settings.privateModeShortcutBinding == binding else {
                pushCurrentSettingsState()
                return
            }
            if previous != binding {
                onModeShortcutChanged?()
            }

        default:
            break
        }
    }

    /// Build a `ShortcutBinding` from bridge shortcut data.
    ///
    /// For combo shortcuts (modifier + key), extracts modifier flags and
    /// key code. For modifier-only shortcuts, stores the modifier flags
    /// with key code 0.
    private func shortcutBindingFromData(
        _ data: [String: Any],
        label: String
    ) -> ShortcutBinding? {
        let type = data["type"] as? String ?? ""
        switch type {
        case "combo":
            guard let keyCode = keyCodeFromData(data) else { return nil }
            return ShortcutBinding(
                kind: .key,
                modifierFlags: modifierFlagsFromData(data),
                keyCode: keyCode,
                label: label)
        case "modifier":
            guard let modifierID = data["modifierId"] as? String,
                let modifier = HotkeySetting.ModifierKey(rawValue: modifierID)
            else { return nil }
            return ShortcutBinding(
                kind: .modifierOnly,
                modifierFlags: modifier.standardFlag,
                keyCode: 0,
                label: label)
        case "modifiers":
            return ShortcutBinding(
                kind: .modifierOnly,
                modifierFlags: modifierFlagsFromData(data),
                keyCode: 0,
                label: label)
        default:
            return nil
        }
    }

    /// Build device-independent modifier flags from bridge shortcut data.
    private func modifierFlagsFromData(_ data: [String: Any]) -> UInt {
        var flags: UInt = 0
        if data["ctrlKey"] as? Bool == true { flags |= 0x0004_0000 }
        if data["altKey"] as? Bool == true { flags |= 0x0008_0000 }
        if data["shiftKey"] as? Bool == true { flags |= 0x0002_0000 }
        if data["metaKey"] as? Bool == true { flags |= 0x0010_0000 }
        return flags
    }

    /// Extract a virtual key code from the bridge data's `code` field.
    /// Maps common KeyboardEvent.code values to macOS virtual key codes.
    private func keyCodeFromData(_ data: [String: Any]) -> UInt16? {
        guard let code = data["code"] as? String else { return nil }
        // Mappings from KeyboardEvent.code to macOS virtual key codes.
        // Must cover every key the JS recorder's CODE_TO_KEY_NAME map
        // can produce. Unknown codes are rejected so they cannot alias
        // the physical A key, whose virtual key code is legitimately 0.
        let map: [String: UInt16] = [
            // Letters
            "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4,
            "KeyG": 5, "KeyZ": 6, "KeyX": 7, "KeyC": 8, "KeyV": 9,
            "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14, "KeyR": 15,
            "KeyY": 16, "KeyT": 17, "KeyO": 31, "KeyU": 32, "KeyI": 34,
            "KeyP": 35, "KeyL": 37, "KeyJ": 38, "KeyK": 40, "KeyN": 45,
            "KeyM": 46,
            // Digits
            "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21,
            "Digit5": 23, "Digit6": 22, "Digit7": 26, "Digit8": 28,
            "Digit9": 25, "Digit0": 29,
            // Punctuation and symbols
            "Minus": 27, "Equal": 24, "BracketLeft": 33, "BracketRight": 30,
            "Backslash": 42, "Semicolon": 41, "Quote": 39, "Comma": 43,
            "Period": 47, "Slash": 44, "Backquote": 50,
            // Whitespace and editing
            "Space": 49, "Tab": 48, "Enter": 36, "Backspace": 51,
            "Delete": 117, "Escape": 53,
            // Arrow keys
            "ArrowUp": 126, "ArrowDown": 125, "ArrowLeft": 123, "ArrowRight": 124,
            // Navigation
            "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
            // Function keys
            "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
            "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
            "F13": 105, "F14": 107, "F15": 113, "F16": 106, "F17": 64,
            "F18": 79, "F19": 80, "F20": 90,
            // Numpad
            "NumpadEnter": 76, "NumpadAdd": 69, "NumpadSubtract": 78,
            "NumpadMultiply": 67, "NumpadDivide": 75, "NumpadDecimal": 65,
            "Numpad0": 82, "Numpad1": 83, "Numpad2": 84, "Numpad3": 85,
            "Numpad4": 86, "Numpad5": 87, "Numpad6": 88, "Numpad7": 89,
            "Numpad8": 91, "Numpad9": 92,
        ]
        return map[code]
    }

    /// Extract a human-readable key name from bridge data.
    private func keyNameFromData(_ data: [String: Any]) -> String {
        guard let key = data["key"] as? String else { return "" }
        if key.count == 1 { return key.uppercased() }
        let names: [String: String] = [
            "Escape": "Escape", "Tab": "Tab", "Backspace": "Delete",
            "Delete": "Forward Delete", "Enter": "Return", " ": "Space",
            "ArrowUp": "↑", "ArrowDown": "↓", "ArrowLeft": "←", "ArrowRight": "→",
        ]
        return names[key] ?? key
    }

    // MARK: - Action: resetApp

    private func handleResetApp() {
        let alert = NSAlert()
        alert.messageText = "Reset FreeFlow?"
        alert.informativeText =
            "This will clear all settings, shortcuts, and your API key, and return to setup."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Settings.shared.resetAll()
        closeWindow()
        onResetApp?()
    }

    // MARK: - Action: setLanguage

    private func handleSetLanguage(code: String) {
        guard let setting = LanguageSetting(rawValue: code) else { return }
        Settings.shared.language = setting

        if let pipeline {
            Task {
                await pipeline.setLanguage(setting.languageCode)
            }
        }
    }

    // MARK: - Action: setDictationMode

    private func handleSetDictationMode(mode: String) {
        guard let newMode = DictationMode(rawValue: mode) else { return }
        guard newMode != Settings.shared.dictationMode else { return }
        onDictationModeChanged?(newMode)
        // Keep optimistic web UI tied to the still-effective persisted mode.
        pushCurrentSettingsState()
    }

    // MARK: - Action: listMicrophones

    private func handleListMicrophones() {
        guard let audioDeviceProvider else { return }
        microphoneListGeneration &+= 1
        let generation = microphoneListGeneration
        microphoneListTask?.cancel()
        microphoneListTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let devices = await audioDeviceProvider.availableDevices()
            guard !Task.isCancelled else { return }
            let current = await audioDeviceProvider.currentDevice()
            guard !Task.isCancelled,
                let self,
                generation == self.microphoneListGeneration
            else { return }
            let isAutoDetect = audioDeviceProvider.isAutoDetect

            // Build display names matching the menu bar.
            let defaultDevice = devices.first(where: { $0.isDefault })
            let defaultLabel = defaultDevice?.transportType == .builtIn
                ? "Built-in mic" : (defaultDevice?.name ?? "System Default")

            var deviceList: [[String: Any]] = [[
                "id": 0,
                "name": "Auto-detect (\(defaultLabel))",
                "isSelected": isAutoDetect,
            ]]

            for device in devices {
                let name = device.transportType == .builtIn
                    ? "Built-in mic (recommended)" : device.name
                deviceList.append([
                    "id": device.id,
                    "name": name,
                    "isSelected": !isAutoDetect && device.id == current?.id,
                ])
            }

            bridge.pushMicrophoneList(
                devices: deviceList,
                currentId: isAutoDetect ? 0 : current?.id
            )
            microphoneListTask = nil
        }
    }

    // MARK: - Action: selectMicrophone

    private func handleSelectMicrophone(id: UInt32) {
        guard let microphoneCaptureCoordinator else { return }
        microphoneListGeneration &+= 1
        microphoneListTask?.cancel()
        microphoneListTask = nil
        microphoneSelectionGeneration &+= 1
        let generation = microphoneSelectionGeneration
        microphoneSelectionTask?.cancel()
        microphoneSelectionTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await microphoneCaptureCoordinator.selectDevice(
                    id: id == 0 ? nil : id)
                guard !Task.isCancelled,
                    let self,
                    generation == self.microphoneSelectionGeneration
                else { return }
                self.bridge.pushMicrophoneSelected(id: id)
            } catch {
                guard !Task.isCancelled,
                    let self,
                    generation == self.microphoneSelectionGeneration
                else {
                    return
                }
                #if DEBUG
                    Log.debug("[SettingsController] selectMicrophone failed: \(error)")
                #endif
            }
            guard !Task.isCancelled,
                let self,
                generation == self.microphoneSelectionGeneration
            else { return }
            self.microphoneSelectionTask = nil
            self.pushMicPreviewAvailability(self.isPreviewCaptureAvailable)
            // The provider is authoritative on both success and failure. A
            // reload also rolls back the dropdown after an external request
            // supersedes this one in the shared coordinator.
            self.handleListMicrophones()
        }
    }

    private func invalidateMicrophoneDeviceTasks() {
        microphoneListGeneration &+= 1
        microphoneListTask?.cancel()
        microphoneListTask = nil

        microphoneSelectionGeneration &+= 1
        microphoneSelectionTask?.cancel()
        microphoneSelectionTask = nil
    }

    // MARK: - Action: startMicPreview

    private func handleStartMicPreview() {
        guard isPreviewWindowSessionActive,
            let microphoneCaptureCoordinator
        else { return }

        let client: MicrophonePreviewClient
        if let microphonePreviewClient {
            client = microphonePreviewClient
        } else {
            client = MicrophonePreviewClient(
                coordinator: microphoneCaptureCoordinator)
            microphonePreviewClient = client
        }
        client.start(
            isEligible: { [weak self] in
                self?.isPreviewWindowSessionActive == true
            },
            onAudioLevel: { [weak self] level in
                self?.bridge.pushAudioLevel(level: level)
            },
            onAvailability: { [weak self] isAvailable in
                self?.pushMicPreviewAvailability(isAvailable)
            })
    }

    private func pushMicPreviewAvailability(_ isAvailable: Bool) {
        isPreviewCaptureAvailable = isAvailable
        bridge.pushEvent(
            name: "micPreviewAvailability",
            data: ["available": isAvailable])
    }

    // MARK: - Action: stopMicPreview

    private func handleStopMicPreview() {
        stopMicPreviewSync()
    }

    private func stopMicPreviewSync() {
        guard let microphonePreviewClient else {
            pushMicPreviewAvailability(false)
            return
        }
        microphonePreviewClient.stop()
    }

}
