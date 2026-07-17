import Foundation

/// Configuration for the global dictation hotkey.
///
/// Two modes:
/// - `.modifierOnly` — a single modifier key (e.g., Right Option)
/// - `.modifierPlusKey` — a modifier + key combo (e.g., Cmd+Shift+D)
///
/// Persisted in UserDefaults via `Settings.shared.hotkeySetting`.
/// The `CGEventTapHotkeyProvider` reads this on registration to
/// determine which key events to monitor.
public enum HotkeySetting: Sendable, Equatable {

    /// A modifier key by itself (e.g., Right Option).
    case modifierOnly(ModifierKey)

    /// A modifier + key combination (e.g., Cmd+Shift+D).
    case modifierPlusKey(modifierFlags: UInt, keyCode: UInt16, keyName: String)

    // MARK: - ModifierKey

    /// Modifier keys that can be used alone as hotkeys.
    public enum ModifierKey: String, Codable, Sendable, CaseIterable {
        case rightOption
        case leftOption
        case rightCommand
        case leftCommand
        case rightControl
        case leftControl
        case rightShift
        case leftShift

        /// The CGEvent device-dependent flags mask for this modifier.
        public var deviceFlag: UInt64 {
            switch self {
            // Device-dependent flag masks from IOKit/IOLLEvent.h
            case .rightOption: return 0x0000_0040  // NX_DEVICERALTKEYMASK
            case .leftOption: return 0x0000_0020  // NX_DEVICELALTKEYMASK
            case .rightCommand: return 0x0000_0010  // NX_DEVICERCMDKEYMASK
            case .leftCommand: return 0x0000_0008  // NX_DEVICELCMDKEYMASK
            case .rightControl: return 0x0000_2000  // NX_DEVICERCTLKEYMASK
            case .leftControl: return 0x0000_0001  // NX_DEVICELCTLKEYMASK
            case .rightShift: return 0x0000_0004  // NX_DEVICERSHIFTKEYMASK
            case .leftShift: return 0x0000_0002  // NX_DEVICELSHIFTKEYMASK
            }
        }

        /// Device-independent modifier family used for shortcut conflicts.
        public var standardFlag: UInt {
            switch self {
            case .rightOption, .leftOption:
                ShortcutBinding.optionFlag
            case .rightCommand, .leftCommand:
                ShortcutBinding.commandFlag
            case .rightControl, .leftControl:
                ShortcutBinding.controlFlag
            case .rightShift, .leftShift:
                ShortcutBinding.shiftFlag
            }
        }

        /// Human-readable display name for the modifier key.
        public var displayName: String {
            switch self {
            case .rightOption: return "Right Option ⌥"
            case .leftOption: return "Left Option ⌥"
            case .rightCommand: return "Right Command ⌘"
            case .leftCommand: return "Left Command ⌘"
            case .rightControl: return "Right Control ⌃"
            case .leftControl: return "Left Control ⌃"
            case .rightShift: return "Right Shift ⇧"
            case .leftShift: return "Left Shift ⇧"
            }
        }

        /// Short symbol representation for UI hints.
        public var symbol: String {
            switch self {
            case .rightOption, .leftOption: return "⌥"
            case .rightCommand, .leftCommand: return "⌘"
            case .rightControl, .leftControl: return "⌃"
            case .rightShift, .leftShift: return "⇧"
            }
        }
    }

    // MARK: - Convenience accessors

    /// The modifier key for `.modifierOnly`, nil for `.modifierPlusKey`.
    public var modifierKey: ModifierKey? {
        if case .modifierOnly(let key) = self { return key }
        return nil
    }

    /// The modifier flags for `.modifierPlusKey`, nil for `.modifierOnly`.
    public var modifierFlags: UInt? {
        if case .modifierPlusKey(let flags, _, _) = self { return flags }
        return nil
    }

    /// The key code for `.modifierPlusKey`, nil for `.modifierOnly`.
    public var keyCode: UInt16? {
        if case .modifierPlusKey(_, let code, _) = self { return code }
        return nil
    }

    /// The key name for `.modifierPlusKey`, nil for `.modifierOnly`.
    public var keyName: String? {
        if case .modifierPlusKey(_, _, let name) = self { return name }
        return nil
    }

    /// Whether this is a modifier-only hotkey.
    public var isModifierOnly: Bool {
        if case .modifierOnly = self { return true }
        return false
    }

    // MARK: - Display

    /// Human-readable display name for the hotkey.
    public var displayName: String {
        switch self {
        case .modifierOnly(let key):
            return key.displayName
        case .modifierPlusKey(let flags, _, let keyName):
            var parts: [String] = []
            if flags & ShortcutBinding.controlFlag != 0 {
                parts.append("⌃")
            }
            if flags & ShortcutBinding.optionFlag != 0 {
                parts.append("⌥")
            }
            if flags & ShortcutBinding.shiftFlag != 0 {
                parts.append("⇧")
            }
            if flags & ShortcutBinding.commandFlag != 0 {
                parts.append("⌘")
            }
            parts.append(keyName)
            return parts.joined()
        }
    }

    /// Short hint text for UI (e.g., "⌥ Right Option").
    public var hintText: String {
        switch self {
        case .modifierOnly(let key):
            return
                "\(key.symbol) \(key.displayName.replacingOccurrences(of: " \(key.symbol)", with: ""))"
        case .modifierPlusKey:
            return displayName
        }
    }

    // MARK: - Defaults and presets

    /// The default hotkey: Right Option.
    public static let `default` = HotkeySetting.modifierOnly(.rightOption)

    /// Preset: Right Option (default)
    public static let rightOption = HotkeySetting.modifierOnly(.rightOption)

    /// Preset: Left Option
    public static let leftOption = HotkeySetting.modifierOnly(.leftOption)

    /// Preset: Right Command
    public static let rightCommand = HotkeySetting.modifierOnly(.rightCommand)

    /// Preset: Right Control
    public static let rightControl = HotkeySetting.modifierOnly(.rightControl)
}

// MARK: - Codable

/// Custom Codable to maintain backward compatibility with the old
/// struct-based JSON format:
///   {"type":"modifierOnly","modifierKey":"rightOption"}
///   {"type":"modifierPlusKey","modifierFlags":786432,"keyCode":2,"keyName":"D"}
extension HotkeySetting: Codable {

    private enum CodingKeys: String, CodingKey {
        case type, modifierKey, modifierFlags, keyCode, keyName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "modifierOnly":
            let key = try container.decode(ModifierKey.self, forKey: .modifierKey)
            self = .modifierOnly(key)
        case "modifierPlusKey":
            let flags = try container.decode(UInt.self, forKey: .modifierFlags)
            let code = try container.decode(UInt16.self, forKey: .keyCode)
            let name = try container.decode(String.self, forKey: .keyName)
            self = .modifierPlusKey(modifierFlags: flags, keyCode: code, keyName: name)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown hotkey type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .modifierOnly(let key):
            try container.encode("modifierOnly", forKey: .type)
            try container.encode(key, forKey: .modifierKey)
        case .modifierPlusKey(let flags, let code, let name):
            try container.encode("modifierPlusKey", forKey: .type)
            try container.encode(flags, forKey: .modifierFlags)
            try container.encode(code, forKey: .keyCode)
            try container.encode(name, forKey: .keyName)
        }
    }
}
