import Foundation

/// Key bindings for hotkeys and shortcut hints displayed in the HUD and menu bar.
///
/// All UI components read from this struct to render shortcut hints dynamically.
/// Both the hold-to-record key name and the paste shortcut name are read from
/// `Settings.shared` so they update automatically when the user changes shortcuts
/// in Settings.
public struct ShortcutConfiguration: Sendable, Equatable {

    /// Display name of the dismiss key (e.g. "Escape").
    public let dismissKeyName: String

    public init(
        dismissKeyName: String = "Escape"
    ) {
        self.dismissKeyName = dismissKeyName
    }

    /// Default configuration with standard key bindings.
    public static let `default` = ShortcutConfiguration()

    /// Display name of the paste-last-transcript shortcut, read dynamically
    /// from settings.
    ///
    /// This is a computed property so it always reflects the current shortcut
    /// configuration, even after the user changes it in Settings.
    public var pasteShortcutName: String {
        Settings.shared.pasteShortcutBinding.label
    }

    /// Display name of the hold-to-record key, read dynamically from settings.
    ///
    /// This is a computed property so it always reflects the current hotkey
    /// configuration, even after the user changes it in Settings.
    public var holdToRecordKeyName: String {
        Settings.shared.hotkeySetting.displayName
    }

    /// The instructional hint shown in the Ready state when the user hovers the HUD.
    ///
    /// Example: "Hold **Right Option ⌥** to dictate"
    public var holdToRecordHint: String {
        "Hold \(holdToRecordKeyName) to dictate"
    }

    /// The instructional hint shown in the No Target state.
    ///
    /// Example: "Select a text field, then ⌃⌥V to paste"
    public var noTargetHint: String {
        "Select a text field, then \(pasteShortcutName) to paste"
    }
}
