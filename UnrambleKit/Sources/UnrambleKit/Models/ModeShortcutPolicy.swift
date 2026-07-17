import Foundation

public enum ModeShortcutValidationError: String, Error, Sendable, Equatable {
    case requiresKey
    case requiresTwoModifiers
    case conflictsWithDictation
    case conflictsWithHandsfree
    case conflictsWithPaste
    case conflictsWithCancel
}

/// Validates the high-impact shortcut that changes the dictation backend.
/// The policy is symmetric: callers can validate a proposed mode binding or
/// revalidate the retained mode binding after any other command changes.
public struct ModeShortcutPolicy: Sendable {
    public let dictation: HotkeySetting
    public let handsfree: ShortcutBinding
    public let paste: ShortcutBinding
    public let cancel: ShortcutBinding

    public init(
        dictation: HotkeySetting,
        handsfree: ShortcutBinding,
        paste: ShortcutBinding,
        cancel: ShortcutBinding
    ) {
        self.dictation = dictation
        self.handsfree = handsfree
        self.paste = paste
        self.cancel = cancel
    }

    public func validate(
        _ binding: ShortcutBinding
    ) -> ModeShortcutValidationError? {
        guard binding.kind == .key else { return .requiresKey }
        guard binding.standardModifierCount >= 2 else {
            return .requiresTwoModifiers
        }

        if binding.hasSameKeystroke(as: handsfree) {
            return .conflictsWithHandsfree
        }
        if binding.hasSameKeystroke(as: paste) {
            return .conflictsWithPaste
        }
        if binding.hasSameKeystroke(as: cancel) {
            return .conflictsWithCancel
        }

        switch dictation {
        case .modifierOnly(let modifier):
            if binding.standardModifierFlags & modifier.standardFlag != 0 {
                return .conflictsWithDictation
            }
        case .modifierPlusKey(let flags, let keyCode, _):
            let dictationBinding = ShortcutBinding(
                modifierFlags: flags,
                keyCode: keyCode,
                label: "")
            if binding.hasSameKeystroke(as: dictationBinding) {
                return .conflictsWithDictation
            }
        }

        return nil
    }
}
