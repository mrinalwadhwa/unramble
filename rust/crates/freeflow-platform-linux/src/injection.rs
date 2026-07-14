use std::sync::{Arc, Mutex};

use arboard::Clipboard;
use async_trait::async_trait;
use freeflow_core::{
    AppContext, FreeFlowError, InjectionResult, Result, SessionType, TextInjector,
};
use x11rb::{
    connection::Connection,
    protocol::{
        xproto::{KEY_PRESS_EVENT, KEY_RELEASE_EVENT},
        xtest::ConnectionExt as _,
    },
};

use crate::{detect_session_type, x11};

const PASTE_SETTLE_DELAY: std::time::Duration = std::time::Duration::from_millis(25);
const FOCUS_SETTLE_DELAY: std::time::Duration = std::time::Duration::from_millis(25);
const CLIPBOARD_READY_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(800);

#[derive(Clone)]
pub struct LinuxTextInjector {
    clipboard: Arc<Mutex<Option<Clipboard>>>,
}

impl LinuxTextInjector {
    #[must_use]
    pub fn new() -> Self {
        Self {
            clipboard: Arc::new(Mutex::new(None)),
        }
    }

    async fn set_clipboard(&self, text: &str) -> Result<()> {
        let clipboard = self.clipboard.clone();
        let text = text.to_owned();
        tokio::task::spawn_blocking(move || {
            let mut clipboard = clipboard
                .lock()
                .map_err(|_| FreeFlowError::Clipboard("clipboard lock was poisoned".into()))?;
            if clipboard.is_none() {
                *clipboard = Some(Clipboard::new().map_err(|error| {
                    FreeFlowError::Clipboard(format!(
                        "could not connect to the desktop clipboard: {error}"
                    ))
                })?);
            }
            clipboard
                .as_mut()
                .expect("clipboard was initialized")
                .set_text(text)
                .map_err(|error| FreeFlowError::Clipboard(error.to_string()))
        })
        .await
        .map_err(|error| FreeFlowError::Internal(error.to_string()))?
    }

    fn paste_x11(use_terminal_shortcut: bool) -> Result<()> {
        let (connection, screen) = x11::connect()?;
        let root = connection.setup().roots[screen].root;
        let control = x11::keycode_for_keysym(&connection, xkeysym::key::Control_L)
            .ok_or_else(|| FreeFlowError::Injection("X11 keymap has no Control key".into()))?;
        let shift = x11::keycode_for_keysym(&connection, xkeysym::key::Shift_L)
            .ok_or_else(|| FreeFlowError::Injection("X11 keymap has no Shift key".into()))?;
        let v = x11::keycode_for_keysym(&connection, xkeysym::key::v)
            .ok_or_else(|| FreeFlowError::Injection("X11 keymap has no V key".into()))?;
        let mut keys = vec![control];
        if use_terminal_shortcut {
            keys.push(shift);
        }
        keys.push(v);
        for key in &keys {
            connection
                .xtest_fake_input(KEY_PRESS_EVENT, *key, 0, root, 0, 0, 0)
                .map_err(injection_error)?;
        }
        for key in keys.iter().rev() {
            connection
                .xtest_fake_input(KEY_RELEASE_EVENT, *key, 0, root, 0, 0, 0)
                .map_err(injection_error)?;
        }
        connection.flush().map_err(injection_error)?;
        Ok(())
    }

    async fn paste_wayland(
        use_terminal_shortcut: bool,
        target_window_id: Option<u64>,
    ) -> Result<()> {
        if is_hyprland() {
            if let Some(target_window_id) = target_window_id {
                let target = format!("address:0x{target_window_id:x}");
                let output = tokio::time::timeout(
                    std::time::Duration::from_secs(2),
                    tokio::process::Command::new("hyprctl")
                        .args(["dispatch", "focuswindow"])
                        .arg(target)
                        .output(),
                )
                .await
                .map_err(|_| {
                    FreeFlowError::Injection("restoring the target window timed out".into())
                })?
                .map_err(|error| {
                    FreeFlowError::Injection(format!(
                        "could not restore the dictation target: {error}"
                    ))
                })?;
                if !output.status.success() {
                    return Err(FreeFlowError::Injection(
                        "Hyprland could not restore the dictation target".into(),
                    ));
                }
                tokio::time::sleep(FOCUS_SETTLE_DELAY).await;
            }
            let modifiers = if use_terminal_shortcut {
                "CTRL SHIFT"
            } else {
                "CTRL"
            };
            let shortcut = format!("{modifiers},V,activewindow");
            let output = tokio::time::timeout(
                std::time::Duration::from_secs(3),
                tokio::process::Command::new("hyprctl")
                    .args(["dispatch", "sendshortcut"])
                    .arg(shortcut)
                    .output(),
            )
            .await
            .map_err(|_| FreeFlowError::Injection("Hyprland paste timed out".into()))?
            .map_err(|error| {
                FreeFlowError::Injection(format!(
                    "the Hyprland input dispatcher is unavailable: {error}"
                ))
            })?;
            if output.status.success() {
                return Ok(());
            }
        }

        let output = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            tokio::process::Command::new("wtype")
                .args(wayland_paste_args(use_terminal_shortcut))
                .output(),
        )
        .await
        .map_err(|_| FreeFlowError::Injection("Wayland paste timed out".into()))?
        .map_err(|error| {
            FreeFlowError::Injection(format!(
                "the Wayland virtual-keyboard helper is unavailable: {error}"
            ))
        })?;
        if !output.status.success() {
            let detail = String::from_utf8_lossy(&output.stderr);
            return Err(FreeFlowError::Injection(format!(
                "the compositor rejected automatic paste: {}",
                detail.trim().chars().take(240).collect::<String>()
            )));
        }
        Ok(())
    }

    async fn wait_for_wayland_clipboard(text: &str) {
        let deadline = tokio::time::Instant::now() + CLIPBOARD_READY_TIMEOUT;
        while tokio::time::Instant::now() < deadline {
            let output = tokio::time::timeout(
                std::time::Duration::from_millis(120),
                tokio::process::Command::new("wl-paste")
                    .arg("--no-newline")
                    .output(),
            )
            .await;
            match output {
                Ok(Ok(output)) if output.status.success() && output.stdout == text.as_bytes() => {
                    return;
                }
                Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => return,
                _ => tokio::time::sleep(std::time::Duration::from_millis(25)).await,
            }
        }
    }
}

impl Default for LinuxTextInjector {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl TextInjector for LinuxTextInjector {
    async fn inject(&self, text: &str, context: &AppContext) -> Result<InjectionResult> {
        self.set_clipboard(text).await?;
        let session = detect_session_type();
        if session == SessionType::Wayland {
            Self::wait_for_wayland_clipboard(text).await;
        }
        // Realtime finalization normally overlaps the physical key release.
        // Retain one compositor frame of settling for unusually fast fallback
        // responses without adding a long fixed delay after every request.
        tokio::time::sleep(PASTE_SETTLE_DELAY).await;
        let terminal = context.is_terminal;
        let paste = match session {
            SessionType::X11 => tokio::task::spawn_blocking(move || Self::paste_x11(terminal))
                .await
                .map_err(|error| FreeFlowError::Internal(error.to_string()))?,
            SessionType::Wayland => Self::paste_wayland(terminal, context.active_window_id).await,
            SessionType::Unknown => Err(FreeFlowError::Injection(
                "no supported desktop input service is available".into(),
            )),
        };
        match paste {
            Ok(()) => Ok(InjectionResult {
                strategy: match (session, terminal) {
                    (SessionType::X11, true) => "x11ClipboardCtrlShiftV".into(),
                    (SessionType::X11, false) => "x11ClipboardCtrlV".into(),
                    (SessionType::Wayland, true) => "waylandClipboardCtrlShiftV".into(),
                    (SessionType::Wayland, false) => "waylandClipboardCtrlV".into(),
                    (SessionType::Unknown, _) => unreachable!("unknown sessions cannot paste"),
                },
                pasted: true,
                clipboard_retained: true,
                requires_manual_paste: false,
                message: None,
            }),
            Err(error) => Err(FreeFlowError::Injection(format!(
                "automatic paste failed: {error}. The transcript remains in the clipboard"
            ))),
        }
    }

    async fn copy_to_clipboard(&self, text: &str) -> Result<()> {
        self.set_clipboard(text).await
    }
}

fn is_hyprland() -> bool {
    std::env::var("XDG_CURRENT_DESKTOP")
        .unwrap_or_default()
        .to_ascii_lowercase()
        .contains("hyprland")
        || std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some()
}

fn wayland_paste_args(use_terminal_shortcut: bool) -> Vec<&'static str> {
    let mut arguments = vec!["-M", "ctrl"];
    if use_terminal_shortcut {
        arguments.extend(["-M", "shift"]);
    }
    arguments.extend(["-k", "v"]);
    if use_terminal_shortcut {
        arguments.extend(["-m", "shift"]);
    }
    arguments.extend(["-m", "ctrl"]);
    arguments
}

fn injection_error(error: impl std::fmt::Display) -> FreeFlowError {
    FreeFlowError::Injection(format!("X11 synthetic paste failed: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wayland_paste_uses_ctrl_v_for_regular_fields() {
        assert_eq!(
            wayland_paste_args(false),
            ["-M", "ctrl", "-k", "v", "-m", "ctrl"]
        );
    }

    #[test]
    fn wayland_paste_uses_ctrl_shift_v_for_terminals() {
        assert_eq!(
            wayland_paste_args(true),
            [
                "-M", "ctrl", "-M", "shift", "-k", "v", "-m", "shift", "-m", "ctrl"
            ]
        );
    }
}
