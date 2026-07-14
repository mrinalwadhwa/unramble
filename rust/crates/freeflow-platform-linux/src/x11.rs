use freeflow_core::{FreeFlowError, Result, ShortcutModifier};
use x11rb::{
    connection::Connection,
    protocol::xproto::{ConnectionExt, Keycode, ModMask},
    rust_connection::RustConnection,
};

pub(crate) fn connect() -> Result<(RustConnection, usize)> {
    x11rb::connect(None)
        .map_err(|error| FreeFlowError::Platform(format!("could not connect to X11: {error}")))
}

pub(crate) fn modifier_mask(modifiers: &[ShortcutModifier]) -> ModMask {
    modifiers.iter().fold(ModMask::default(), |mask, modifier| {
        mask | match modifier {
            ShortcutModifier::Control
            | ShortcutModifier::LeftControl
            | ShortcutModifier::RightControl => ModMask::CONTROL,
            ShortcutModifier::Alt | ShortcutModifier::LeftAlt | ShortcutModifier::RightAlt => {
                ModMask::M1
            }
            ShortcutModifier::Shift
            | ShortcutModifier::LeftShift
            | ShortcutModifier::RightShift => ModMask::SHIFT,
            ShortcutModifier::Super
            | ShortcutModifier::LeftSuper
            | ShortcutModifier::RightSuper => ModMask::M4,
        }
    })
}

pub(crate) fn keycode_for_name(connection: &RustConnection, name: &str) -> Result<Keycode> {
    let keysym = keysym_for_name(name)
        .ok_or_else(|| FreeFlowError::Hotkey(format!("unsupported shortcut key: {name}")))?;
    keycode_for_keysym(connection, keysym).ok_or_else(|| {
        FreeFlowError::Hotkey(format!("the current X11 keymap has no key named {name}"))
    })
}

pub(crate) fn keycode_for_keysym(connection: &RustConnection, keysym: u32) -> Option<Keycode> {
    let setup = connection.setup();
    let minimum = setup.min_keycode;
    let count = setup.max_keycode.saturating_sub(minimum).saturating_add(1);
    let mapping = connection
        .get_keyboard_mapping(minimum, count)
        .ok()?
        .reply()
        .ok()?;
    let width = usize::from(mapping.keysyms_per_keycode);
    mapping
        .keysyms
        .chunks(width)
        .position(|symbols| symbols.contains(&keysym))
        .and_then(|index| u8::try_from(index).ok())
        .and_then(|offset| minimum.checked_add(offset))
}

fn keysym_for_name(name: &str) -> Option<u32> {
    let trimmed = name.trim();
    if trimmed.chars().count() == 1 {
        return trimmed
            .chars()
            .next()
            .map(|ch| u32::from(xkeysym::Keysym::from_char(ch)));
    }
    let lowered = trimmed.to_ascii_lowercase();
    match lowered.as_str() {
        "space" => Some(xkeysym::key::space),
        "enter" | "return" => Some(xkeysym::key::Return),
        "tab" => Some(xkeysym::key::Tab),
        "escape" | "esc" => Some(xkeysym::key::Escape),
        "backspace" => Some(xkeysym::key::BackSpace),
        "delete" => Some(xkeysym::key::Delete),
        "left" => Some(xkeysym::key::Left),
        "right" => Some(xkeysym::key::Right),
        "up" => Some(xkeysym::key::Up),
        "down" => Some(xkeysym::key::Down),
        _ => lowered
            .strip_prefix('f')
            .and_then(|number| number.parse::<u32>().ok())
            .filter(|number| (1..=35).contains(number))
            .map(|number| xkeysym::key::F1 + number - 1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_common_key_names_without_an_x_server() {
        assert_eq!(keysym_for_name("space"), Some(xkeysym::key::space));
        assert_eq!(keysym_for_name("F9"), Some(xkeysym::key::F9));
        assert_eq!(keysym_for_name("d"), Some(xkeysym::key::d));
        assert_eq!(keysym_for_name("not-a-key"), None);
    }

    #[test]
    fn maps_generic_and_sided_modifiers() {
        assert_eq!(
            modifier_mask(&[ShortcutModifier::Control, ShortcutModifier::LeftAlt]),
            ModMask::CONTROL | ModMask::M1
        );
    }
}
