import Foundation
import Testing

@testable import UnrambleKit

@Suite("ShortcutConfiguration")
struct ShortcutConfigurationTests {

    @Test("Default configuration has expected key names")
    func defaultValues() {
        let config = ShortcutConfiguration.default

        // holdToRecordKeyName is dynamic, read from Settings.shared.hotkeySetting.
        // With default settings it should reflect Right Option.
        #expect(config.holdToRecordKeyName == Settings.shared.hotkeySetting.displayName)
        // pasteShortcutName is now dynamic, read from Settings.shared.
        // With default settings it should reflect ⌃⌥V.
        #expect(config.pasteShortcutName == Settings.shared.pasteShortcutBinding.label)
        #expect(config.dismissKeyName == "Escape")
    }

    @Test("Static default matches parameterless init")
    func staticDefaultMatchesInit() {
        let config = ShortcutConfiguration()
        #expect(config == .default)
    }

    @Test("Custom configuration preserves dismiss value")
    func customValues() {
        let config = ShortcutConfiguration(
            dismissKeyName: "Esc"
        )

        #expect(config.dismissKeyName == "Esc")
    }

    @Test("Hold-to-record hint includes key name from HotkeySetting")
    func holdToRecordHint() {
        let config = ShortcutConfiguration.default
        let expected = "Hold \(Settings.shared.hotkeySetting.displayName) to dictate"
        #expect(config.holdToRecordHint == expected)
    }

    @Test("No-target hint includes paste shortcut from Settings")
    func noTargetHint() {
        let config = ShortcutConfiguration.default
        let pasteLabel = Settings.shared.pasteShortcutBinding.label
        #expect(config.noTargetHint == "Select a text field, then \(pasteLabel) to paste")
    }

    @Test("Paste shortcut name reflects current Settings binding")
    func pasteShortcutNameDynamic() {
        let config = ShortcutConfiguration.default
        // The paste shortcut name should always match what Settings reports.
        #expect(config.pasteShortcutName == Settings.shared.pasteShortcutBinding.label)
    }

    @Test("Equatable compares dismiss field")
    func equatable() {
        let a = ShortcutConfiguration.default
        let b = ShortcutConfiguration(dismissKeyName: "Esc")
        #expect(a != b)
    }
}
