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
        if detect_session_type() != SessionType::X11 {
            return Ok(InjectionResult {
                strategy: "clipboard".into(),
                pasted: false,
                clipboard_retained: true,
                requires_manual_paste: true,
                message: Some(
                    "Wayland blocks unrestricted keyboard injection; press paste in the target application."
                        .into(),
                ),
            });
        }

        tokio::time::sleep(std::time::Duration::from_millis(35)).await;
        let terminal = context.is_terminal;
        match tokio::task::spawn_blocking(move || Self::paste_x11(terminal)).await {
            Ok(Ok(())) => Ok(InjectionResult {
                strategy: if terminal {
                    "x11ClipboardCtrlShiftV".into()
                } else {
                    "x11ClipboardCtrlV".into()
                },
                pasted: true,
                clipboard_retained: true,
                requires_manual_paste: false,
                message: None,
            }),
            Ok(Err(error)) => Ok(InjectionResult {
                strategy: "clipboardFallback".into(),
                pasted: false,
                clipboard_retained: true,
                requires_manual_paste: true,
                message: Some(format!(
                    "Automatic paste failed: {error}. The transcript remains in the clipboard."
                )),
            }),
            Err(error) => Err(FreeFlowError::Internal(error.to_string())),
        }
    }

    async fn copy_to_clipboard(&self, text: &str) -> Result<()> {
        self.set_clipboard(text).await
    }
}

fn injection_error(error: impl std::fmt::Display) -> FreeFlowError {
    FreeFlowError::Injection(format!("X11 synthetic paste failed: {error}"))
}
