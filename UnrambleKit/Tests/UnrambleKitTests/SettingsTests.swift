import Foundation
import Testing

@testable import UnrambleKit

@Suite("Settings", .serialized)
struct SettingsTests {

    // Tests read/write via Settings.shared which uses the standard
    // UserDefaults domain. The suite is serialized to prevent concurrent
    // test runs from interfering with each other. Each test that changes
    // a setting restores the default at the end.

    // MARK: - Sound Feedback

    @Test("Sound feedback defaults to true")
    func soundFeedbackDefault() {
        // Remove any persisted value so we get the registered default.
        UserDefaults.standard.removeObject(forKey: "soundFeedbackEnabled")
        let settings = Settings.shared
        #expect(settings.soundFeedbackEnabled == true)
    }

    @Test("Sound feedback can be set to false")
    func soundFeedbackSetFalse() {
        let settings = Settings.shared
        settings.soundFeedbackEnabled = false
        #expect(settings.soundFeedbackEnabled == false)

        // Restore default.
        settings.soundFeedbackEnabled = true
    }

    @Test("Sound feedback can be toggled back to true")
    func soundFeedbackToggle() {
        let settings = Settings.shared
        settings.soundFeedbackEnabled = false
        #expect(settings.soundFeedbackEnabled == false)

        settings.soundFeedbackEnabled = true
        #expect(settings.soundFeedbackEnabled == true)
    }

    @Test("Sound feedback persists through UserDefaults")
    func soundFeedbackPersistence() {
        let settings = Settings.shared
        settings.soundFeedbackEnabled = false

        // Read directly from UserDefaults to confirm persistence.
        let stored = UserDefaults.standard.bool(forKey: "soundFeedbackEnabled")
        #expect(stored == false)

        // Restore default.
        settings.soundFeedbackEnabled = true
    }

    // MARK: - Hotkey Setting

    @Test("Hotkey defaults to Right Option")
    func hotkeyDefault() {
        // Remove any persisted value so we get the default.
        UserDefaults.standard.removeObject(forKey: "hotkeyConfiguration")
        let settings = Settings.shared
        let hotkey = settings.hotkeySetting

        #expect(hotkey.isModifierOnly)
        #expect(hotkey.modifierKey == .rightOption)
    }

    @Test("Hotkey setting can be changed to Left Option")
    func hotkeyChangeToLeftOption() {
        let settings = Settings.shared
        let newSetting = HotkeySetting.modifierOnly( .leftOption)
        settings.hotkeySetting = newSetting

        let read = settings.hotkeySetting
        #expect(read.isModifierOnly)
        #expect(read.modifierKey == .leftOption)

        // Restore default.
        settings.hotkeySetting = .default
    }

    @Test("Hotkey setting can be changed to Right Command")
    func hotkeyChangeToRightCommand() {
        let settings = Settings.shared
        let newSetting = HotkeySetting.modifierOnly( .rightCommand)
        settings.hotkeySetting = newSetting

        let read = settings.hotkeySetting
        #expect(read.modifierKey == .rightCommand)

        // Restore default.
        settings.hotkeySetting = .default
    }

    @Test("Hotkey setting round-trips modifier+key through Settings")
    func hotkeyModifierPlusKeyRoundTrip() {
        let settings = Settings.shared
        let flags: UInt = 0x0010_0000 | 0x0002_0000
        let newSetting = HotkeySetting.modifierPlusKey(
            modifierFlags: flags,
            keyCode: 2,
            keyName: "D"
        )
        settings.hotkeySetting = newSetting

        let read = settings.hotkeySetting
        #expect(!read.isModifierOnly)
        #expect(read.modifierFlags == flags)
        #expect(read.keyCode == UInt16(2))
        #expect(read.keyName == "D")

        // Restore default.
        settings.hotkeySetting = .default
    }

    @Test("Hotkey setting persists through UserDefaults")
    func hotkeyPersistence() {
        let settings = Settings.shared
        let newSetting = HotkeySetting.modifierOnly( .leftCommand)
        settings.hotkeySetting = newSetting

        // Read directly from UserDefaults and decode.
        guard let data = UserDefaults.standard.data(forKey: "hotkeyConfiguration"),
            let decoded = try? JSONDecoder().decode(HotkeySetting.self, from: data)
        else {
            Issue.record("Hotkey setting not found in UserDefaults")
            settings.hotkeySetting = .default
            return
        }
        #expect(decoded.modifierKey == .leftCommand)

        // Restore default.
        settings.hotkeySetting = .default
    }

    @Test("Removing hotkey UserDefaults key falls back to default")
    func hotkeyFallbackAfterRemoval() {
        let settings = Settings.shared
        settings.hotkeySetting = HotkeySetting.modifierOnly(.leftCommand)
        #expect(settings.hotkeySetting.modifierKey == .leftCommand)

        // Remove the persisted key.
        UserDefaults.standard.removeObject(forKey: "hotkeyConfiguration")

        // Should fall back to Right Option default.
        let fallback = settings.hotkeySetting
        #expect(fallback.isModifierOnly)
        #expect(fallback.modifierKey == .rightOption)
    }

    @Test("Corrupted hotkey data falls back to default")
    func hotkeyCorruptedDataFallback() {
        // Write invalid JSON data to the key.
        let garbage = Data("not valid json".utf8)
        UserDefaults.standard.set(garbage, forKey: "hotkeyConfiguration")

        let settings = Settings.shared
        let hotkey = settings.hotkeySetting
        #expect(hotkey.isModifierOnly)
        #expect(hotkey.modifierKey == .rightOption)

        // Clean up.
        UserDefaults.standard.removeObject(forKey: "hotkeyConfiguration")
    }

    // MARK: - Notification

    @Test("Setting sound feedback posts settingsDidChange notification")
    func soundFeedbackNotification() {
        let settings = Settings.shared

        // NotificationCenter.default.post delivers synchronously on the
        // calling thread, so a simple flag works without async.
        var receivedKey: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: settings,
            queue: nil
        ) { notification in
            if receivedKey == nil {
                receivedKey = notification.userInfo?["key"] as? String
            }
        }

        settings.soundFeedbackEnabled = false

        NotificationCenter.default.removeObserver(observer)

        #expect(receivedKey == "soundFeedbackEnabled")

        // Restore default.
        settings.soundFeedbackEnabled = true
    }

    @Test("Setting hotkey posts settingsDidChange notification")
    func hotkeyNotification() {
        let settings = Settings.shared

        var receivedKey: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: settings,
            queue: nil
        ) { notification in
            if receivedKey == nil {
                receivedKey = notification.userInfo?["key"] as? String
            }
        }

        settings.hotkeySetting = HotkeySetting.modifierOnly( .leftOption)

        NotificationCenter.default.removeObserver(observer)

        #expect(receivedKey == "hotkeyConfiguration")

        // Restore default.
        settings.hotkeySetting = .default
    }

    // MARK: - Reset

    @Test("resetAll posts settingsDidChange notification")
    func resetAllPostsNotification() {
        let settings = Settings.shared

        // Change a setting so there is something to reset.
        settings.soundFeedbackEnabled = false

        var receivedNotification = false
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: settings,
            queue: nil
        ) { _ in
            receivedNotification = true
        }

        settings.resetAll()

        NotificationCenter.default.removeObserver(observer)

        #expect(receivedNotification, "resetAll() must post .settingsDidChange")

        // Restore (already reset, so defaults are in effect).
    }

    @Test("incognitoModeShortcutLabel setter posts settingsDidChange notification")
    func incognitoModeShortcutLabelNotification() {
        let settings = Settings.shared
        let original = settings.incognitoModeShortcutLabel

        var receivedKey: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: settings,
            queue: nil
        ) { notification in
            if receivedKey == nil {
                receivedKey = notification.userInfo?["key"] as? String
            }
        }

        settings.incognitoModeShortcutLabel = "⌃⌥X"

        NotificationCenter.default.removeObserver(observer)

        #expect(receivedKey == "incognitoModeShortcutLabel")

        // Restore.
        settings.incognitoModeShortcutLabel = original
    }

    @Test("Exact legacy mode shortcut migrates to Control Shift M")
    func legacyModeShortcutMigration() throws {
        let suiteName = "SettingsTests.legacyModeShortcutMigration"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(ShortcutBinding.legacyDefaultIncognitoMode),
            forKey: "incognitoModeShortcutBinding")
        defaults.set("⌃⌥P", forKey: "incognitoModeShortcutLabel")

        let settings = Settings(defaults: defaults)

        #expect(settings.incognitoModeShortcutBinding == .defaultIncognitoMode)
        #expect(settings.incognitoModeShortcutLabel == "⌃⇧M")
    }

    @Test("Valid custom mode shortcut survives legacy migration")
    func customModeShortcutPreserved() throws {
        let suiteName = "SettingsTests.customModeShortcutPreserved"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let custom = ShortcutBinding(
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.commandFlag,
            keyCode: 37,
            label: "⌃⌘L")
        defaults.set(
            try JSONEncoder().encode(custom),
            forKey: "incognitoModeShortcutBinding")

        let settings = Settings(defaults: defaults)

        #expect(settings.incognitoModeShortcutBinding == custom)
    }

    @Test("Former incognito-mode keys migrate to the renamed keys")
    func formerIncognitoModeKeysMigrate() throws {
        let suiteName = "SettingsTests.formerIncognitoModeKeysMigrate"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let custom = ShortcutBinding(
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.commandFlag,
            keyCode: 37,
            label: "⌃⌘L")
        defaults.set(
            try JSONEncoder().encode(custom),
            forKey: "privateModeShortcutBinding")
        defaults.set("⌃⌘L", forKey: "privateModeShortcutLabel")

        let settings = Settings(defaults: defaults)

        #expect(settings.incognitoModeShortcutBinding == custom)
        #expect(settings.incognitoModeShortcutLabel == "⌃⌘L")
        #expect(defaults.data(forKey: "privateModeShortcutBinding") == nil)
        #expect(defaults.string(forKey: "privateModeShortcutLabel") == nil)
    }

    @Test("hasCompletedOnboarding round-trips and clears on reset")
    func hasCompletedOnboardingRoundTrips() throws {
        let suiteName = "SettingsTests.hasCompletedOnboarding"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)

        #expect(settings.hasCompletedOnboarding == false)
        settings.hasCompletedOnboarding = true
        #expect(settings.hasCompletedOnboarding == true)
        settings.resetAll()
        #expect(settings.hasCompletedOnboarding == false)
    }

    @Test("Missing mode binding repairs around a retained Control dictation key")
    func missingModeShortcutRepairsAroundControlDictation() throws {
        let suiteName =
            "SettingsTests.missingModeShortcutRepairsAroundControlDictation"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(
                HotkeySetting.modifierOnly(.leftControl)),
            forKey: "hotkeyConfiguration")

        let settings = Settings(defaults: defaults)
        let repaired = settings.incognitoModeShortcutBinding

        #expect(repaired.standardModifierCount >= 2)
        #expect(!repaired.hasControl)
        #expect(repaired.keyCode == 46)
        #expect(settings.incognitoModeShortcutLabel == repaired.label)
    }

    @Test("Legacy mode binding repairs around a retained Shift dictation key")
    func legacyModeShortcutRepairsAroundShiftDictation() throws {
        let suiteName =
            "SettingsTests.legacyModeShortcutRepairsAroundShiftDictation"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(
                HotkeySetting.modifierOnly(.rightShift)),
            forKey: "hotkeyConfiguration")
        defaults.set(
            try JSONEncoder().encode(ShortcutBinding.legacyDefaultIncognitoMode),
            forKey: "incognitoModeShortcutBinding")

        let settings = Settings(defaults: defaults)
        let repaired = settings.incognitoModeShortcutBinding

        #expect(repaired.standardModifierCount >= 2)
        #expect(!repaired.hasShift)
        #expect(repaired.keyCode == 46)
        #expect(settings.incognitoModeShortcutLabel == repaired.label)
    }

    @Test("Dictation shortcut cannot invalidate retained mode shortcut")
    func dictationShortcutCannotInvalidateModeShortcut() throws {
        let suiteName = "SettingsTests.dictationShortcutCannotInvalidateModeShortcut"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)

        let original = settings.hotkeySetting
        settings.hotkeySetting = .modifierOnly(.leftControl)

        #expect(settings.hotkeySetting == original)
        #expect(settings.incognitoModeShortcutBinding == .defaultIncognitoMode)
    }

    @Test("Hands-free shortcut cannot invalidate retained mode shortcut")
    func handsfreeShortcutCannotInvalidateModeShortcut() throws {
        let suiteName = "SettingsTests.handsfreeShortcutCannotInvalidateModeShortcut"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        let original = settings.handsfreeShortcutBinding
        let originalLabel = settings.handsfreeShortcutLabel

        settings.handsfreeShortcutBinding = .defaultIncognitoMode

        #expect(settings.handsfreeShortcutBinding == original)
        #expect(settings.handsfreeShortcutLabel == originalLabel)
        #expect(settings.incognitoModeShortcutBinding == .defaultIncognitoMode)
    }

    @Test("Paste shortcut cannot invalidate retained mode shortcut")
    func pasteShortcutCannotInvalidateModeShortcut() throws {
        let suiteName = "SettingsTests.pasteShortcutCannotInvalidateModeShortcut"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        let original = settings.pasteShortcutBinding
        let originalLabel = settings.pasteShortcutLabel

        settings.pasteShortcutBinding = .defaultIncognitoMode

        #expect(settings.pasteShortcutBinding == original)
        #expect(settings.pasteShortcutLabel == originalLabel)
        #expect(settings.incognitoModeShortcutBinding == .defaultIncognitoMode)
    }

    @Test("Cancel shortcut cannot invalidate retained mode shortcut")
    func cancelShortcutCannotInvalidateModeShortcut() throws {
        let suiteName = "SettingsTests.cancelShortcutCannotInvalidateModeShortcut"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = Settings(defaults: defaults)
        let original = settings.cancelShortcutBinding
        let originalLabel = settings.cancelShortcutLabel

        settings.cancelShortcutBinding = .defaultIncognitoMode

        #expect(settings.cancelShortcutBinding == original)
        #expect(settings.cancelShortcutLabel == originalLabel)
        #expect(settings.incognitoModeShortcutBinding == .defaultIncognitoMode)
    }

    // MARK: - Single Source of Truth

    @Test("ShortcutConfiguration.holdToRecordKeyName matches Settings.shared.hotkeySetting")
    func holdToRecordKeyNameMatchesSettings() {
        let settings = Settings.shared

        // Change the hotkey through Settings (the canonical path).
        settings.hotkeySetting = HotkeySetting.modifierOnly( .leftCommand)

        let config = ShortcutConfiguration.default
        #expect(
            config.holdToRecordKeyName == settings.hotkeySetting.displayName,
            "holdToRecordKeyName must read from Settings.shared, not a separate path"
        )

        // Restore.
        settings.hotkeySetting = .default
    }

    // MARK: - Language

    @Test("Language defaults to a valid setting")
    func languageDefault() {
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        let lang = Settings.shared.language
        // Should be system locale or English fallback.
        #expect(LanguageSetting.allCases.contains(lang))
    }

    @Test("Language round-trips through Settings")
    func languageRoundTrip() {
        let settings = Settings.shared
        settings.language = .french
        #expect(settings.language == .french)

        settings.language = .tamil
        #expect(settings.language == .tamil)

        // Restore.
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
    }

    @Test("Language setter posts settingsDidChange notification")
    func languageNotification() {
        let settings = Settings.shared

        var receivedKey: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: settings,
            queue: nil
        ) { notification in
            if receivedKey == nil {
                receivedKey = notification.userInfo?["key"] as? String
            }
        }

        settings.language = .german

        NotificationCenter.default.removeObserver(observer)

        #expect(receivedKey == "selectedLanguage")

        // Restore.
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
    }

    // MARK: - Dictation Mode

    @Test("Dictation mode defaults to cloud")
    func dictationModeDefault() {
        UserDefaults.standard.removeObject(forKey: "dictationMode")
        #expect(Settings.shared.dictationMode == .cloud)
    }

    @Test("Dictation mode round-trips through Settings")
    func dictationModeRoundTrip() {
        let settings = Settings.shared
        settings.dictationMode = .local
        #expect(settings.dictationMode == .local)

        settings.dictationMode = .cloud
        #expect(settings.dictationMode == .cloud)
    }

    @Test("Dictation mode setter posts settingsDidChange notification")
    func dictationModeNotification() {
        let settings = Settings.shared

        var receivedKey: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: settings,
            queue: nil
        ) { notification in
            if receivedKey == nil {
                receivedKey = notification.userInfo?["key"] as? String
            }
        }

        settings.dictationMode = .local

        NotificationCenter.default.removeObserver(observer)

        #expect(receivedKey == "dictationMode")

        // Restore.
        settings.dictationMode = .cloud
    }

    // MARK: - Settings is singleton

    @Test("Settings.shared always returns the same instance")
    func singletonIdentity() {
        let a = Settings.shared
        let b = Settings.shared
        #expect(a === b)
    }
}
