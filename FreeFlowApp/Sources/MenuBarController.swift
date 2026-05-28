import AppKit
import FreeFlowKit
import Sparkle

/// Build and manage the menu bar status item, icon, and dropdown menu.
///
/// Observes `RecordingCoordinator.stateStream` to swap the status item icon.
/// Builds a rich menu with paste-last-transcript, microphone selection,
/// status indicator, and quit. Menu items that depend on async state
/// (transcript availability, device list) are refreshed each time the
/// menu opens via `NSMenuDelegate`.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private weak var statusItem: NSStatusItem?
    private var observationTask: Task<Void, Never>?

    // MARK: - Dependencies

    private weak var coordinator: RecordingCoordinator?
    private weak var pipeline: DictationPipeline?
    private var transcriptBuffer: TranscriptBuffer?
    private var textInjector: (any TextInjecting)?
    private var audioDeviceProvider: (any AudioDeviceProviding)?
    private var updaterService: UpdaterService?
    private var micDiagnosticStore: MicDiagnosticStore?
    private var shortcuts: ShortcutConfiguration = .default

    /// Callback invoked when Settings menu item is clicked.
    var onOpenSettings: (() -> Void)?

    /// Callback invoked when the user clicks "Reset API Key".
    var onResetAPIKey: (() -> Void)?

    /// Callback invoked when the user toggles private mode.
    var onTogglePrivateMode: (() -> Void)?

    // MARK: - Onboarding mode

    /// When true, the menu shows a minimal onboarding hint instead of
    /// the full operational menu.
    private var onboardingMode: Bool = false

    /// Callback invoked when the user clicks "Open Setup…" in the
    /// onboarding menu. The AppDelegate wires this to re-present the
    /// onboarding window.
    var onReopenOnboarding: (() -> Void)?

    // MARK: - Menu items that need dynamic updates

    private var pasteItem: NSMenuItem?
    private var privateModeItem: NSMenuItem?
    private var privateModeStatusItem: NSMenuItem?
    private var micSubmenuItem: NSMenuItem?
    private var languageSubmenuItem: NSMenuItem?
    private var checkForUpdatesItem: NSMenuItem?

    // MARK: - State tracking

    private var currentRecordingState: RecordingState = .idle
    private var hotkeyRegistered: Bool = false

    // MARK: - Lifecycle

    /// Configure and begin observing state to drive the status item.
    ///
    /// - Parameters:
    ///   - statusItem: The menu bar status item to manage.
    ///   - coordinator: The recording coordinator to observe.
    ///   - transcriptBuffer: The buffer holding the last transcript for re-paste.
    ///   - textInjector: The injector used to re-paste transcripts.
    ///   - audioDeviceProvider: The provider for mic enumeration and selection.
    ///   - shortcuts: The shortcut configuration for display hints.
    ///   - hotkeyRegistered: Whether the global hotkey registered successfully.
    func start(
        statusItem: NSStatusItem,
        coordinator: RecordingCoordinator,
        pipeline: DictationPipeline? = nil,
        transcriptBuffer: TranscriptBuffer? = nil,
        textInjector: (any TextInjecting)? = nil,
        audioDeviceProvider: (any AudioDeviceProviding)? = nil,
        updaterService: UpdaterService? = nil,
        micDiagnosticStore: MicDiagnosticStore? = nil,
        shortcuts: ShortcutConfiguration = .default,
        hotkeyRegistered: Bool = false
    ) {
        self.statusItem = statusItem
        self.coordinator = coordinator
        self.pipeline = pipeline
        self.transcriptBuffer = transcriptBuffer
        self.textInjector = textInjector
        self.audioDeviceProvider = audioDeviceProvider
        self.updaterService = updaterService
        self.micDiagnosticStore = micDiagnosticStore
        self.shortcuts = shortcuts
        self.hotkeyRegistered = hotkeyRegistered

        buildMenu(for: statusItem)
        applyIcon(for: .idle)

        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await state in await coordinator.stateStream {
                guard !Task.isCancelled else { break }
                self?.currentRecordingState = state
                self?.applyIcon(for: state)
            }
        }
    }

    /// Stop observing and reset the icon to idle.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        applyIcon(for: .idle)
    }

    /// Update whether the hotkey is registered.
    func setHotkeyRegistered(_ registered: Bool) {
        hotkeyRegistered = registered
    }

    /// Switch to onboarding mode: show a minimal menu with a setup hint.
    func setOnboardingMode(_ enabled: Bool) {
        onboardingMode = enabled
        guard let statusItem else { return }
        if enabled {
            buildOnboardingMenu(for: statusItem)
        } else {
            buildMenu(for: statusItem)
        }
    }

    // MARK: - Menu construction

    private func buildOnboardingMenu(for statusItem: NSStatusItem) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let hint = NSMenuItem(
            title: "Finish setting up FreeFlow",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        hint.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(hint)

        menu.addItem(.separator())

        let openSetup = NSMenuItem(
            title: "Open Setup…",
            action: #selector(reopenOnboarding),
            keyEquivalent: ""
        )
        openSetup.target = self
        openSetup.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(openSetup)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit FreeFlow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func buildMenu(for statusItem: NSStatusItem) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // --- Private mode toggle (macOS 26+ only) ---

        if DictationMode.isLocalAvailable {
            let privateMode = NSMenuItem(
                title: "Private Mode",
                action: #selector(togglePrivateModeAction),
                keyEquivalent: "p"
            )
            privateMode.keyEquivalentModifierMask = [.control, .option]
            privateMode.target = self
            privateMode.image = NSImage(
                systemSymbolName: "lock.shield",
                accessibilityDescription: nil)
            if Settings.shared.dictationMode == .local {
                privateMode.state = .on
            }
            menu.addItem(privateMode)
            privateModeItem = privateMode

            let modeStatus = NSMenuItem(
                title: Settings.shared.dictationMode == .local
                    ? "Transcribing on this Mac"
                    : "Transcribing in the cloud",
                action: nil,
                keyEquivalent: ""
            )
            modeStatus.isEnabled = false
            menu.addItem(modeStatus)
            privateModeStatusItem = modeStatus

            menu.addItem(.separator())
        }

        // --- Primary actions ---

        let paste = NSMenuItem(
            title: "Paste Last Dictation",
            action: #selector(pasteLastTranscript),
            keyEquivalent: ""
        )
        // Key equivalent is set dynamically in refreshPasteItem()
        // from the current paste shortcut binding in Settings.
        applyPasteKeyEquivalent(to: paste)
        paste.target = self
        paste.isEnabled = false
        paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(paste)
        pasteItem = paste

        menu.addItem(.separator())

        // --- Input ---

        let micSubmenu = NSMenu()
        let micItem = NSMenuItem(
            title: "Microphone",
            action: nil,
            keyEquivalent: ""
        )
        micItem.submenu = micSubmenu
        micItem.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        menu.addItem(micItem)
        micSubmenuItem = micItem

        let langSubmenu = NSMenu()
        let langItem = NSMenuItem(
            title: "Language",
            action: nil,
            keyEquivalent: ""
        )
        langItem.submenu = langSubmenu
        langItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(langItem)
        languageSubmenuItem = langItem

        menu.addItem(.separator())

        // --- Community ---

        let requestLang = NSMenuItem(
            title: "Add a Language…",
            action: #selector(openLanguageIssue),
            keyEquivalent: ""
        )
        requestLang.target = self
        requestLang.image = NSImage(
            systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(requestLang)

        let reportMic = NSMenuItem(
            title: "Contribute Mic Data…",
            action: #selector(contributeMicData),
            keyEquivalent: ""
        )
        reportMic.target = self
        reportMic.image = NSImage(
            systemSymbolName: "mic.badge.plus", accessibilityDescription: nil)
        menu.addItem(reportMic)

        let reportIssue = NSMenuItem(
            title: "Report an Issue…",
            action: #selector(reportAnIssue),
            keyEquivalent: ""
        )
        reportIssue.target = self
        reportIssue.image = NSImage(
            systemSymbolName: "exclamationmark.bubble", accessibilityDescription: nil)
        menu.addItem(reportIssue)

        menu.addItem(.separator())

        // --- App ---

        let about = NSMenuItem(
            title: "About FreeFlow",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        about.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        menu.addItem(about)

        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesAction),
            keyEquivalent: ""
        )
        checkForUpdates.target = self
        checkForUpdates.isEnabled = updaterService?.canCheckForUpdates ?? false
        checkForUpdates.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(checkForUpdates)
        checkForUpdatesItem = checkForUpdates

        let settings = NSMenuItem(
            title: "Preferences…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit FreeFlow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    /// Refresh dynamic menu items each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        refreshPasteItem()
        refreshMicSubmenu()
        refreshLanguageSubmenu()
        refreshCheckForUpdatesItem()
    }

    // MARK: - Dynamic refresh

    private func refreshPasteItem() {
        guard let pasteItem, let transcriptBuffer else {
            pasteItem?.isEnabled = false
            return
        }
        // Update the displayed key equivalent from the current binding
        // so changes made in Settings are reflected in the menu.
        applyPasteKeyEquivalent(to: pasteItem)
        // Check buffer availability synchronously via a detached task that
        // completes before the menu finishes opening. Since TranscriptBuffer
        // is an actor, we fire-and-forget with nonisolated(unsafe) capture.
        // For a menu open this is fast enough.
        let item = pasteItem
        Task {
            let has = await transcriptBuffer.hasTranscript
            item.isEnabled = has
        }
    }

    /// Apply the paste shortcut binding from Settings to a menu item's
    /// key equivalent. Maps the binding's modifier flags and key code
    /// to NSMenuItem's keyEquivalent and keyEquivalentModifierMask.
    private func applyPasteKeyEquivalent(to item: NSMenuItem) {
        let binding = Settings.shared.pasteShortcutBinding

        // Build modifier mask from the binding's flags.
        var mask: NSEvent.ModifierFlags = []
        if binding.hasControl { mask.insert(.control) }
        if binding.hasOption { mask.insert(.option) }
        if binding.hasShift { mask.insert(.shift) }
        if binding.hasCommand { mask.insert(.command) }
        item.keyEquivalentModifierMask = mask

        // Map the key code to a keyEquivalent string.
        // NSMenuItem expects a lowercase character for letter keys.
        let keyEquiv = keyEquivalentFromKeyCode(binding.keyCode)
        item.keyEquivalent = keyEquiv
    }

    /// Map a macOS virtual key code to an NSMenuItem key equivalent string.
    private func keyEquivalentFromKeyCode(_ keyCode: UInt16) -> String {
        switch keyCode {
        // Letters
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 31: return "o"
        case 32: return "u"
        case 34: return "i"
        case 35: return "p"
        case 37: return "l"
        case 38: return "j"
        case 40: return "k"
        case 45: return "n"
        case 46: return "m"
        // Digits
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        // Punctuation
        case 30: return "]"
        case 33: return "["
        case 39: return "'"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 47: return "."
        case 50: return "`"
        // Special keys
        case 36: return "\r"  // Return
        case 48: return "\t"  // Tab
        case 49: return " "  // Space
        case 51: return "\u{08}"  // Delete (backspace)
        case 53: return "\u{1b}"  // Escape
        // Arrow keys (using Unicode private use area as AppKit expects)
        case 123: return "\u{F702}"  // Left
        case 124: return "\u{F703}"  // Right
        case 125: return "\u{F701}"  // Down
        case 126: return "\u{F700}"  // Up
        // Function keys
        case 122: return "\u{F704}"  // F1
        case 120: return "\u{F705}"  // F2
        case 99: return "\u{F706}"  // F3
        case 118: return "\u{F707}"  // F4
        case 96: return "\u{F708}"  // F5
        case 97: return "\u{F709}"  // F6
        case 98: return "\u{F70A}"  // F7
        case 100: return "\u{F70B}"  // F8
        case 101: return "\u{F70C}"  // F9
        case 109: return "\u{F70D}"  // F10
        case 103: return "\u{F70E}"  // F11
        case 111: return "\u{F70F}"  // F12
        default: return ""
        }
    }

    private func refreshMicSubmenu() {
        guard let micSubmenuItem, let audioDeviceProvider else { return }
        let submenu = micSubmenuItem.submenu ?? NSMenu()
        micSubmenuItem.submenu = submenu

        Task {
            let devices = await audioDeviceProvider.availableDevices()
            let current = await audioDeviceProvider.currentDevice()
            let isAutoDetect = audioDeviceProvider.isAutoDetect

            submenu.removeAllItems()

            if devices.isEmpty {
                let none = NSMenuItem(
                    title: "No Input Devices",
                    action: nil,
                    keyEquivalent: ""
                )
                none.isEnabled = false
                submenu.addItem(none)
                return
            }

            // Auto-detect at the top.
            let defaultDevice = devices.first(where: { $0.isDefault })
            let defaultName: String
            if defaultDevice?.transportType == .builtIn {
                defaultName = "Built-in mic"
            } else {
                defaultName = defaultDevice?.name ?? "System Default"
            }
            let autoItem = NSMenuItem(
                title: "Auto-detect (\(defaultName))",
                action: #selector(selectAutoDetect(_:)),
                keyEquivalent: ""
            )
            autoItem.target = self
            autoItem.state = isAutoDetect ? .on : .off
            submenu.addItem(autoItem)

            submenu.addItem(.separator())

            // Explicit device options.
            for device in devices {
                var title: String
                if device.transportType == .builtIn {
                    title = "Built-in mic (recommended)"
                } else {
                    title = device.name
                }
                let item = NSMenuItem(
                    title: title,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = Int(device.id)
                item.state = (!isAutoDetect && device.id == current?.id) ? .on : .off
                submenu.addItem(item)
            }

            // Clamshell warning.
            if let current, current.transportType == .builtIn,
               audioDeviceProvider.isClamshellClosed
            {
                submenu.addItem(.separator())
                let warning = NSMenuItem(
                    title: "⚠ Lid closed — built-in mic may not work well",
                    action: nil,
                    keyEquivalent: ""
                )
                warning.isEnabled = false
                submenu.addItem(warning)
            }
        }
    }

    private func refreshLanguageSubmenu() {
        guard let languageSubmenuItem else { return }
        let submenu = languageSubmenuItem.submenu ?? NSMenu()
        languageSubmenuItem.submenu = submenu
        submenu.removeAllItems()

        let current = Settings.shared.language

        for setting in LanguageSetting.allCases {
            let item = NSMenuItem(
                title: setting.displayName,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = setting.rawValue
            item.state = (setting == current) ? .on : .off
            submenu.addItem(item)
        }
    }

    private func refreshCheckForUpdatesItem() {
        checkForUpdatesItem?.isEnabled = updaterService?.canCheckForUpdates ?? false
    }

    // MARK: - Actions

    @objc private func pasteLastTranscript() {
        guard let transcriptBuffer, let textInjector else {
            Log.debug("[MenuBar] Paste requested but buffer or injector not available")
            return
        }
        Task {
            guard let transcript = await transcriptBuffer.consume() else {
                Log.debug("[MenuBar] No transcript in buffer to paste")
                return
            }

            // Read context at the moment of paste for accurate injection.
            let context = AppContext.empty

            do {
                try await textInjector.inject(text: transcript, into: context)
                Log.debug("[MenuBar] Pasted last transcript (\(transcript.count) chars)")
            } catch {
                Log.debug("[MenuBar] Paste injection failed: \(error)")
                // Re-store the transcript so the user can try again.
                await transcriptBuffer.store(transcript)
            }

            // If the coordinator is in injectionFailed, reset to idle after
            // a successful paste.
            if let coordinator, await coordinator.state == .injectionFailed {
                await coordinator.reset()
            }
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
            let setting = LanguageSetting(rawValue: rawValue)
        else { return }

        Settings.shared.language = setting

        // Apply the language to the pipeline immediately.
        if let pipeline {
            Task {
                await pipeline.setLanguage(setting.languageCode)
            }
        }

        Log.debug("[MenuBar] Selected language: \(setting.displayName) (\(setting.rawValue))")
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let audioDeviceProvider else { return }
        let deviceID = UInt32(sender.tag)
        Task {
            do {
                try await audioDeviceProvider.selectDevice(id: deviceID)
                Log.debug("[MenuBar] Selected microphone: \(sender.title) (id: \(deviceID))")
            } catch {
                Log.debug("[MenuBar] Failed to select microphone: \(error)")
            }
        }
    }

    @objc private func selectAutoDetect(_ sender: NSMenuItem) {
        guard let audioDeviceProvider else { return }
        audioDeviceProvider.clearSelection()
        Log.debug("[MenuBar] Selected auto-detect")
    }

    @objc private func contributeMicData() {
        guard let store = micDiagnosticStore else { return }
        Task {
            let diagnostics = await store.formattedDiagnostics()
            let body = """
                > See [Microphone compatibility](https://github.com/mrinalwadhwa/freeflow/issues/2) for context on what this data is used for.

                **Mic and setup:**
                <!-- e.g. "Blue Yeti USB on MacBook Pro, desk distance" -->

                **What you observed:**
                <!-- e.g. "Whispers were transcribed fine but normal speech cut off early" -->

                **Diagnostics (auto-filled):**
                ```
                \(diagnostics)
                ```
                """
            var components = URLComponents(
                string: "https://github.com/mrinalwadhwa/freeflow/issues/new")!
            components.queryItems = [
                URLQueryItem(name: "title", value: "Mic data: "),
                URLQueryItem(name: "body", value: body),
                URLQueryItem(name: "labels", value: "mic"),
            ]
            if let url = components.url {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func reportAnIssue() {
        Task {
            let micDiagnostics: String? = await micDiagnosticStore?.formattedDiagnostics()
            guard let report = IssueDiagnostics.issueURL(micDiagnostics: micDiagnostics) else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.diagnostics, forType: .string)
            NSWorkspace.shared.open(report.url)
        }
    }

    @objc private func openLanguageIssue() {
        if let url = URL(string: "https://github.com/mrinalwadhwa/freeflow/issues/1") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdatesAction() {
        updaterService?.checkForUpdates()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reopenOnboarding() {
        onReopenOnboarding?()
    }

    @objc private func togglePrivateModeAction() {
        onTogglePrivateMode?()
    }

    /// Update the private mode menu item checkmark and status text.
    func setPrivateMode(_ isPrivate: Bool) {
        privateModeItem?.state = isPrivate ? .on : .off
        privateModeStatusItem?.title = isPrivate
            ? "Transcribing on this Mac"
            : "Transcribing in the cloud"
    }

    @objc private func resetAPIKeyAction() {
        let alert = NSAlert()
        alert.messageText = "Reset API Key?"
        alert.informativeText =
            "This removes the stored OpenAI API key and returns to setup. "
            + "Dictation will be unavailable until a new key is entered."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            onResetAPIKey?()
        }
    }

    // MARK: - Icon mapping

    private func applyIcon(for state: RecordingState) {
        // Static waveform icon for all states. The HUD overlay communicates
        // recording/processing state; the menu bar icon stays simple.
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "FreeFlow"
        )
    }

    deinit {
        observationTask?.cancel()
    }
}
