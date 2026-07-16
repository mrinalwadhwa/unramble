import Foundation

/// A persistent representation of a keyboard shortcut binding.
///
/// Stores the modifier flags and virtual key code needed to detect a
/// shortcut at runtime, alongside a human-readable label for display.
/// Codable so it can be serialized to UserDefaults via JSONEncoder.
///
/// Used by `Settings` to persist the actual key bindings for the
/// handsfree, paste, and cancel shortcuts. Without this, only the
/// display label was saved and the runtime detection remained
/// hard-coded.
public struct ShortcutBinding: Codable, Sendable, Equatable {

    public enum Kind: String, Codable, Sendable {
        case key
        case modifierOnly
    }

    /// Whether this binding includes a non-modifier key. Keeping this explicit
    /// avoids confusing modifier-only input with the physical A key, whose
    /// macOS virtual key code is also zero.
    public var kind: Kind

    /// Device-independent modifier flags (NSEvent.ModifierFlags raw values).
    ///
    /// Uses the same constants as `HotkeySetting`:
    /// - Control: `0x0004_0000`
    /// - Option:  `0x0008_0000`
    /// - Shift:   `0x0002_0000`
    /// - Command: `0x0010_0000`
    public var modifierFlags: UInt

    /// The virtual key code (macOS `CGKeyCode` / `event.keyCode`).
    /// For modifier-only shortcuts this is 0.
    public var keyCode: UInt16

    /// Human-readable display label (e.g. "⌃⌥V", "⌘⇧H", "Escape").
    public var label: String

    // MARK: - Modifier flag constants (same as HotkeySetting)

    /// Control key modifier flag (NSEvent.ModifierFlags.control.rawValue).
    public static let controlFlag: UInt = 0x0004_0000

    /// Option key modifier flag (NSEvent.ModifierFlags.option.rawValue).
    public static let optionFlag: UInt = 0x0008_0000

    /// Shift key modifier flag (NSEvent.ModifierFlags.shift.rawValue).
    public static let shiftFlag: UInt = 0x0002_0000

    /// Command key modifier flag (NSEvent.ModifierFlags.command.rawValue).
    public static let commandFlag: UInt = 0x0010_0000

    // MARK: - Initializers

    public init(
        kind: Kind = .key,
        modifierFlags: UInt,
        keyCode: UInt16,
        label: String
    ) {
        self.kind = kind
        self.modifierFlags = modifierFlags
        self.keyCode = keyCode
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case modifierFlags
        case keyCode
        case label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifierFlags = try container.decode(UInt.self, forKey: .modifierFlags)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        label = try container.decode(String.self, forKey: .label)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? Self.inferLegacyKind(keyCode: keyCode, label: label)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(modifierFlags, forKey: .modifierFlags)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(label, forKey: .label)
    }

    private static func inferLegacyKind(keyCode: UInt16, label: String) -> Kind {
        guard keyCode == 0 else { return .key }
        let modifierGlyphs = CharacterSet(charactersIn: "⌃⌥⇧⌘ ")
        return label.unicodeScalars.allSatisfy(modifierGlyphs.contains)
            ? .modifierOnly
            : .key
    }

    // MARK: - Matching

    /// Check whether an NSEvent matches this shortcut binding.
    ///
    /// Compares the event's key code and device-independent modifier flags
    /// against the stored binding. Only the four standard modifier bits
    /// (Control, Option, Shift, Command) are compared; Caps Lock, Fn, and
    /// other flags are masked out.
    ///
    /// - Parameter keyCode: The virtual key code from the event.
    /// - Parameter modifierFlags: The raw value of the event's
    ///   device-independent modifier flags.
    /// - Returns: `true` if the event matches this binding.
    public func matches(keyCode eventKeyCode: UInt16, modifierFlags eventFlags: UInt) -> Bool {
        guard kind == .key else { return false }
        guard eventKeyCode == keyCode else { return false }
        return (eventFlags & Self.standardModifierMask) == standardModifierFlags
    }

    public static let standardModifierMask =
        controlFlag | optionFlag | shiftFlag | commandFlag

    public var standardModifierFlags: UInt {
        modifierFlags & Self.standardModifierMask
    }

    public var standardModifierCount: Int {
        [hasControl, hasOption, hasShift, hasCommand].filter { $0 }.count
    }

    public func hasSameKeystroke(as other: ShortcutBinding) -> Bool {
        kind == .key && other.kind == .key
            && keyCode == other.keyCode
            && standardModifierFlags == other.standardModifierFlags
    }

    // MARK: - Convenience query

    /// Whether this binding has the Control modifier.
    public var hasControl: Bool { modifierFlags & Self.controlFlag != 0 }

    /// Whether this binding has the Option modifier.
    public var hasOption: Bool { modifierFlags & Self.optionFlag != 0 }

    /// Whether this binding has the Shift modifier.
    public var hasShift: Bool { modifierFlags & Self.shiftFlag != 0 }

    /// Whether this binding has the Command modifier.
    public var hasCommand: Bool { modifierFlags & Self.commandFlag != 0 }

    // MARK: - Default bindings

    /// Default paste shortcut: ⌃⌥V (Control+Option+V, key code 9).
    public static let defaultPaste = ShortcutBinding(
        modifierFlags: controlFlag | optionFlag,
        keyCode: 9,
        label: "⌃⌥V"
    )

    /// Default hands-free shortcut: ⌃⌥H (Control+Option+H, key code 4).
    public static let defaultHandsfree = ShortcutBinding(
        modifierFlags: controlFlag | optionFlag,
        keyCode: 4,
        label: "⌃⌥H"
    )

    /// Default cancel shortcut: Escape (no modifiers, key code 53).
    public static let defaultCancel = ShortcutBinding(
        modifierFlags: 0,
        keyCode: 53,
        label: "Escape"
    )

    /// Legacy private mode shortcut retained only for exact migration.
    public static let legacyDefaultPrivateMode = ShortcutBinding(
        modifierFlags: controlFlag | optionFlag,
        keyCode: 35,
        label: "⌃⌥P"
    )

    /// Default private mode shortcut: ⌃⇧M (Control+Shift+M, key code 46).
    public static let defaultPrivateMode = ShortcutBinding(
        modifierFlags: controlFlag | shiftFlag,
        keyCode: 46,
        label: "⌃⇧M"
    )
}
