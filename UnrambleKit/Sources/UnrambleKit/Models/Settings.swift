import Foundation

/// Centralized app settings with UserDefaults persistence.
///
/// Settings provides a single point of access for all user-configurable
/// options. Each setting is persisted immediately on write and read
/// fresh from UserDefaults on access, ensuring consistency across the app.
///
/// Individual reads and writes are thread-safe via UserDefaults.
/// Compound setters (e.g. binding + label) are not atomic — concurrent
/// writes from different threads could interleave. In practice all
/// writes come from the main thread via UI interactions.
public final class Settings: @unchecked Sendable {

    /// Shared singleton instance.
    public static let shared = Settings()

    private let defaults: UserDefaults

    // MARK: - Keys

    private enum Key: String, CaseIterable {
        case soundFeedbackEnabled = "soundFeedbackEnabled"
        case hotkeyConfiguration = "hotkeyConfiguration"
        case selectedLanguage = "selectedLanguage"
        case dictationMode = "dictationMode"
        case hasCompletedOnboarding = "hasCompletedOnboarding"
        case handsfreeShortcutLabel = "handsfreeShortcutLabel"
        case pasteShortcutLabel = "pasteShortcutLabel"
        case cancelShortcutLabel = "cancelShortcutLabel"
        case handsfreeShortcutBinding = "handsfreeShortcutBinding"
        case pasteShortcutBinding = "pasteShortcutBinding"
        case cancelShortcutBinding = "cancelShortcutBinding"
        case incognitoModeShortcutLabel = "incognitoModeShortcutLabel"
        case incognitoModeShortcutBinding = "incognitoModeShortcutBinding"
    }

    // MARK: - Init

    private convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Register default values for settings that need them.
        defaults.register(defaults: [
            Key.soundFeedbackEnabled.rawValue: true
        ])
        migrateFormerModeShortcutKeys()
    }

    // MARK: - Migration

    /// Copy a mode shortcut stored under the former keys to the current keys.
    ///
    /// The on-device dictation toggle changed its persisted key names. Move a
    /// value a user stored under the former keys once, so a custom shortcut and
    /// label survive, then remove the former keys so a later reset cannot
    /// resurrect them.
    private func migrateFormerModeShortcutKeys() {
        let formerBindingKey = "privateModeShortcutBinding"
        let formerLabelKey = "privateModeShortcutLabel"
        if defaults.data(forKey: Key.incognitoModeShortcutBinding.rawValue) == nil,
            let formerBinding = defaults.data(forKey: formerBindingKey)
        {
            defaults.set(
                formerBinding, forKey: Key.incognitoModeShortcutBinding.rawValue)
        }
        if defaults.string(forKey: Key.incognitoModeShortcutLabel.rawValue) == nil,
            let formerLabel = defaults.string(forKey: formerLabelKey)
        {
            defaults.set(
                formerLabel, forKey: Key.incognitoModeShortcutLabel.rawValue)
        }
        defaults.removeObject(forKey: formerBindingKey)
        defaults.removeObject(forKey: formerLabelKey)
    }

    // MARK: - Sound Feedback

    /// Whether sound feedback (start/stop cues) is enabled.
    /// Defaults to `true` on first launch.
    public var soundFeedbackEnabled: Bool {
        get {
            defaults.bool(forKey: Key.soundFeedbackEnabled.rawValue)
        }
        set {
            defaults.set(newValue, forKey: Key.soundFeedbackEnabled.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.soundFeedbackEnabled.rawValue]
            )
        }
    }

    // MARK: - Hotkey

    /// The configured dictation hotkey.
    /// Defaults to Right Option.
    public var hotkeySetting: HotkeySetting {
        get {
            guard let data = defaults.data(forKey: Key.hotkeyConfiguration.rawValue),
                let setting = try? JSONDecoder().decode(HotkeySetting.self, from: data)
            else {
                return .default
            }
            return setting
        }
        set {
            let retainedModeBinding = incognitoModeShortcutBinding
            guard
                modeShortcutPolicy(dictation: newValue)
                    .validate(retainedModeBinding) == nil
            else { return }
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.hotkeyConfiguration.rawValue)
                NotificationCenter.default.post(
                    name: .settingsDidChange,
                    object: self,
                    userInfo: ["key": Key.hotkeyConfiguration.rawValue]
                )
            }
        }
    }

    // MARK: - Language

    /// The selected dictation language.
    /// Defaults to the macOS preferred language if supported, otherwise English.
    public var language: LanguageSetting {
        get {
            if let stored = defaults.string(forKey: Key.selectedLanguage.rawValue),
                let setting = LanguageSetting(rawValue: stored)
            {
                return setting
            }
            return LanguageSetting.settingFromSystemLocale() ?? .english
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.selectedLanguage.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.selectedLanguage.rawValue]
            )
        }
    }

    // MARK: - Dictation Mode

    /// Whether dictation uses cloud APIs or on-device processing.
    /// Defaults to cloud.
    public var dictationMode: DictationMode {
        get {
            if let stored = defaults.string(forKey: Key.dictationMode.rawValue),
                let mode = DictationMode(rawValue: stored)
            {
                return mode
            }
            return .cloud
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.dictationMode.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.dictationMode.rawValue]
            )
        }
    }

    // MARK: - Onboarding

    /// Whether the user reached the end of the onboarding flow.
    /// Defaults to `false` until onboarding completes.
    public var hasCompletedOnboarding: Bool {
        get {
            defaults.bool(forKey: Key.hasCompletedOnboarding.rawValue)
        }
        set {
            defaults.set(
                newValue, forKey: Key.hasCompletedOnboarding.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.hasCompletedOnboarding.rawValue]
            )
        }
    }

    // MARK: - Shortcut Labels

    /// Display label for the hands-free mode shortcut.
    /// Defaults to "⌃⌥H" (Control+Option+H).
    public var handsfreeShortcutLabel: String {
        get {
            defaults.string(forKey: Key.handsfreeShortcutLabel.rawValue)
                ?? handsfreeShortcutBinding.label
        }
        set {
            defaults.set(newValue, forKey: Key.handsfreeShortcutLabel.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.handsfreeShortcutLabel.rawValue]
            )
        }
    }

    /// Display label for the paste-last-transcript shortcut.
    /// Defaults to "⌃⌥V" (Control+Option+V).
    public var pasteShortcutLabel: String {
        get {
            defaults.string(forKey: Key.pasteShortcutLabel.rawValue)
                ?? pasteShortcutBinding.label
        }
        set {
            defaults.set(newValue, forKey: Key.pasteShortcutLabel.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.pasteShortcutLabel.rawValue]
            )
        }
    }

    /// Display label for the cancel shortcut.
    /// Defaults to "Escape".
    public var cancelShortcutLabel: String {
        get {
            defaults.string(forKey: Key.cancelShortcutLabel.rawValue)
                ?? cancelShortcutBinding.label
        }
        set {
            defaults.set(newValue, forKey: Key.cancelShortcutLabel.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.cancelShortcutLabel.rawValue]
            )
        }
    }

    // MARK: - Shortcut Bindings

    /// The key binding for the hands-free mode shortcut.
    /// Defaults to ⌃⌥H (Control+Option+H, key code 4).
    public var handsfreeShortcutBinding: ShortcutBinding {
        get {
            guard let data = defaults.data(forKey: Key.handsfreeShortcutBinding.rawValue),
                let binding = try? JSONDecoder().decode(ShortcutBinding.self, from: data)
            else {
                return .defaultHandsfree
            }
            return binding
        }
        set {
            let retainedModeBinding = incognitoModeShortcutBinding
            guard
                modeShortcutPolicy(handsfree: newValue)
                    .validate(retainedModeBinding) == nil
            else { return }
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.handsfreeShortcutBinding.rawValue)
                // Also update the label to stay in sync.
                handsfreeShortcutLabel = newValue.label
            }
        }
    }

    /// The key binding for the paste-last-transcript shortcut.
    /// Defaults to ⌃⌥V (Control+Option+V, key code 9).
    public var pasteShortcutBinding: ShortcutBinding {
        get {
            guard let data = defaults.data(forKey: Key.pasteShortcutBinding.rawValue),
                let binding = try? JSONDecoder().decode(ShortcutBinding.self, from: data)
            else {
                return .defaultPaste
            }
            return binding
        }
        set {
            let retainedModeBinding = incognitoModeShortcutBinding
            guard
                modeShortcutPolicy(paste: newValue)
                    .validate(retainedModeBinding) == nil
            else { return }
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.pasteShortcutBinding.rawValue)
                // Also update the label to stay in sync.
                pasteShortcutLabel = newValue.label
            }
        }
    }

    /// The key binding for the cancel shortcut.
    /// Defaults to Escape (no modifiers, key code 53).
    public var cancelShortcutBinding: ShortcutBinding {
        get {
            guard let data = defaults.data(forKey: Key.cancelShortcutBinding.rawValue),
                let binding = try? JSONDecoder().decode(ShortcutBinding.self, from: data)
            else {
                return .defaultCancel
            }
            return binding
        }
        set {
            let retainedModeBinding = incognitoModeShortcutBinding
            guard
                modeShortcutPolicy(cancel: newValue)
                    .validate(retainedModeBinding) == nil
            else { return }
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.cancelShortcutBinding.rawValue)
                // Also update the label to stay in sync.
                cancelShortcutLabel = newValue.label
            }
        }
    }

    /// The display label for the incognito mode shortcut.
    public var incognitoModeShortcutLabel: String {
        get {
            let bindingLabel = incognitoModeShortcutBinding.label
            if defaults.string(forKey: Key.incognitoModeShortcutLabel.rawValue)
                != bindingLabel
            {
                defaults.set(
                    bindingLabel,
                    forKey: Key.incognitoModeShortcutLabel.rawValue)
            }
            return bindingLabel
        }
        set {
            defaults.set(newValue, forKey: Key.incognitoModeShortcutLabel.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.incognitoModeShortcutLabel.rawValue]
            )
        }
    }

    /// The key binding for the incognito mode toggle shortcut.
    /// Defaults to ⌃⇧M (Control+Shift+M, key code 46).
    public var incognitoModeShortcutBinding: ShortcutBinding {
        get {
            guard let data = defaults.data(forKey: Key.incognitoModeShortcutBinding.rawValue),
                let binding = try? JSONDecoder().decode(ShortcutBinding.self, from: data)
            else {
                let repaired = compatibleDefaultIncognitoModeShortcut
                persistIncognitoModeShortcut(repaired)
                return repaired
            }
            if binding == .legacyDefaultIncognitoMode {
                let repaired = compatibleDefaultIncognitoModeShortcut
                persistIncognitoModeShortcut(repaired)
                return repaired
            }
            guard modeShortcutPolicy.validate(binding) == nil else {
                let repaired = compatibleDefaultIncognitoModeShortcut
                persistIncognitoModeShortcut(repaired)
                return repaired
            }
            return binding
        }
        set {
            guard modeShortcutPolicy.validate(newValue) == nil else { return }
            persistIncognitoModeShortcut(newValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.incognitoModeShortcutBinding.rawValue]
            )
        }
    }

    private var modeShortcutPolicy: ModeShortcutPolicy {
        modeShortcutPolicy()
    }

    /// Prefer Control+Shift+M, but preserve an older dictation trigger when
    /// that chord would be ambiguous. With one dictation command and three
    /// other exact commands, at least one modifier subset for M is available.
    private var compatibleDefaultIncognitoModeShortcut: ShortcutBinding {
        let modifierCandidates: [UInt] = [
            ShortcutBinding.controlFlag | ShortcutBinding.shiftFlag,
            ShortcutBinding.controlFlag | ShortcutBinding.optionFlag,
            ShortcutBinding.optionFlag | ShortcutBinding.shiftFlag,
            ShortcutBinding.controlFlag | ShortcutBinding.commandFlag,
            ShortcutBinding.optionFlag | ShortcutBinding.commandFlag,
            ShortcutBinding.shiftFlag | ShortcutBinding.commandFlag,
            ShortcutBinding.controlFlag | ShortcutBinding.optionFlag
                | ShortcutBinding.shiftFlag,
            ShortcutBinding.controlFlag | ShortcutBinding.optionFlag
                | ShortcutBinding.commandFlag,
            ShortcutBinding.controlFlag | ShortcutBinding.shiftFlag
                | ShortcutBinding.commandFlag,
            ShortcutBinding.optionFlag | ShortcutBinding.shiftFlag
                | ShortcutBinding.commandFlag,
            ShortcutBinding.standardModifierMask,
        ]

        for flags in modifierCandidates {
            let binding = ShortcutBinding(
                modifierFlags: flags,
                keyCode: 46,
                label: modeShortcutLabel(modifierFlags: flags))
            if modeShortcutPolicy.validate(binding) == nil {
                return binding
            }
        }

        preconditionFailure("No valid incognito-mode shortcut candidate")
    }

    private func modeShortcutLabel(modifierFlags: UInt) -> String {
        var label = ""
        if modifierFlags & ShortcutBinding.controlFlag != 0 { label += "⌃" }
        if modifierFlags & ShortcutBinding.optionFlag != 0 { label += "⌥" }
        if modifierFlags & ShortcutBinding.shiftFlag != 0 { label += "⇧" }
        if modifierFlags & ShortcutBinding.commandFlag != 0 { label += "⌘" }
        return label + "M"
    }

    private func modeShortcutPolicy(
        dictation: HotkeySetting? = nil,
        handsfree: ShortcutBinding? = nil,
        paste: ShortcutBinding? = nil,
        cancel: ShortcutBinding? = nil
    ) -> ModeShortcutPolicy {
        ModeShortcutPolicy(
            dictation: dictation ?? hotkeySetting,
            handsfree: handsfree ?? handsfreeShortcutBinding,
            paste: paste ?? pasteShortcutBinding,
            cancel: cancel ?? cancelShortcutBinding)
    }

    private func persistIncognitoModeShortcut(_ binding: ShortcutBinding) {
        if let data = try? JSONEncoder().encode(binding) {
            defaults.set(data, forKey: Key.incognitoModeShortcutBinding.rawValue)
        }
        defaults.set(binding.label, forKey: Key.incognitoModeShortcutLabel.rawValue)
    }

    // MARK: - Reset

    /// Remove all persisted settings, restoring defaults.
    public func resetAll() {
        for key in Key.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }
        NotificationCenter.default.post(
            name: .settingsDidChange,
            object: self,
            userInfo: ["key": "resetAll"]
        )
    }

    // MARK: - Observation

    /// Add an observer for settings changes.
    ///
    /// - Parameters:
    ///   - observer: The object to register as observer.
    ///   - selector: The selector to call when settings change.
    public func addObserver(_ observer: Any, selector: Selector) {
        NotificationCenter.default.addObserver(
            observer,
            selector: selector,
            name: .settingsDidChange,
            object: self
        )
    }

    /// Remove a settings observer.
    public func removeObserver(_ observer: Any) {
        NotificationCenter.default.removeObserver(
            observer,
            name: .settingsDidChange,
            object: self
        )
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when any setting changes. The `userInfo` dictionary contains
    /// a "key" entry with the raw string key of the changed setting.
    public static let settingsDidChange = Notification.Name("SettingsDidChange")
}
