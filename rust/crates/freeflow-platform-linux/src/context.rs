use async_trait::async_trait;
use freeflow_core::{AppContext, AppContextProvider, FreeFlowError, Result, SessionType};
use serde_json::Value;
use x11rb::{
    connection::Connection,
    protocol::xproto::{Atom, AtomEnum, ConnectionExt, Window},
    rust_connection::RustConnection,
};

use crate::{desktop_environment, detect_session_type, x11};

#[derive(Debug, Clone, Default)]
pub struct LinuxAppContextProvider;

impl LinuxAppContextProvider {
    #[must_use]
    pub fn new() -> Self {
        Self
    }

    fn current_x11_context() -> Result<AppContext> {
        let (connection, screen) = x11::connect()?;
        let root = connection.setup().roots[screen].root;
        let active_atom = intern(&connection, b"_NET_ACTIVE_WINDOW")?;
        let active = connection
            .get_property(false, root, active_atom, AtomEnum::WINDOW, 0, 1)
            .map_err(platform_error)?
            .reply()
            .map_err(platform_error)?
            .value32()
            .and_then(|mut values| values.next());
        let Some(window) = active else {
            return Ok(AppContext {
                desktop_environment: desktop_environment(),
                ..AppContext::default()
            });
        };

        let process_id = property_u32(&connection, window, b"_NET_WM_PID")?;
        let app_class = wm_class(&connection, window).unwrap_or_default();
        let window_title = window_title(&connection, window).unwrap_or_default();
        let app_name = process_id
            .and_then(process_name)
            .unwrap_or_else(|| app_class.clone());
        let is_terminal = terminal_hint(&app_class, &app_name);

        Ok(AppContext {
            active_window_id: Some(u64::from(window)),
            process_id,
            app_class,
            app_name,
            window_title,
            desktop_environment: desktop_environment(),
            is_terminal,
            is_editable: None,
            focused_field_content: None,
            selected_text: None,
            cursor_position: None,
        })
    }

    async fn current_hyprland_context() -> Result<AppContext> {
        let output = tokio::time::timeout(
            std::time::Duration::from_millis(150),
            tokio::process::Command::new("hyprctl")
                .args(["-j", "activewindow"])
                .output(),
        )
        .await
        .map_err(|_| FreeFlowError::Platform("Hyprland active-window query timed out".into()))?
        .map_err(|error| {
            FreeFlowError::Platform(format!(
                "could not query the Hyprland active window: {error}"
            ))
        })?;
        if !output.status.success() {
            return Err(FreeFlowError::Platform(
                "Hyprland rejected the active-window query".into(),
            ));
        }
        let value: Value = serde_json::from_slice(&output.stdout).map_err(|error| {
            FreeFlowError::Platform(format!(
                "Hyprland returned invalid window metadata: {error}"
            ))
        })?;
        Ok(context_from_hyprland_json(&value))
    }
}

#[async_trait]
impl AppContextProvider for LinuxAppContextProvider {
    async fn current_context(&self) -> Result<AppContext> {
        match detect_session_type() {
            SessionType::X11 => tokio::task::spawn_blocking(Self::current_x11_context)
                .await
                .map_err(|error| FreeFlowError::Internal(error.to_string()))?,
            SessionType::Wayland
                if std::env::var("XDG_CURRENT_DESKTOP")
                    .unwrap_or_default()
                    .to_ascii_lowercase()
                    .contains("hyprland")
                    || std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some() =>
            {
                Self::current_hyprland_context().await
            }
            SessionType::Wayland | SessionType::Unknown => Ok(AppContext {
                desktop_environment: desktop_environment(),
                ..AppContext::default()
            }),
        }
    }
}

fn context_from_hyprland_json(value: &Value) -> AppContext {
    let process_id = value
        .get("pid")
        .and_then(Value::as_u64)
        .and_then(|pid| u32::try_from(pid).ok());
    let app_class = value
        .get("class")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let window_title = value
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let app_name = process_id
        .and_then(process_name)
        .unwrap_or_else(|| app_class.clone());
    let active_window_id = value
        .get("address")
        .and_then(Value::as_str)
        .and_then(|address| address.strip_prefix("0x").or(Some(address)))
        .and_then(|address| u64::from_str_radix(address, 16).ok());
    AppContext {
        active_window_id,
        process_id,
        is_terminal: terminal_hint(&app_class, &app_name),
        app_class,
        app_name,
        window_title,
        desktop_environment: desktop_environment(),
        is_editable: None,
        focused_field_content: None,
        selected_text: None,
        cursor_position: None,
    }
}

fn terminal_hint(app_class: &str, app_name: &str) -> bool {
    let hint = format!("{app_class} {app_name}").to_ascii_lowercase();
    [
        "terminal",
        "konsole",
        "alacritty",
        "kitty",
        "wezterm",
        "xterm",
        "urxvt",
        "foot",
        "tilix",
    ]
    .iter()
    .any(|candidate| hint.contains(candidate))
}

fn intern(connection: &RustConnection, name: &[u8]) -> Result<Atom> {
    connection
        .intern_atom(false, name)
        .map_err(platform_error)?
        .reply()
        .map(|reply| reply.atom)
        .map_err(platform_error)
}

fn property_u32(connection: &RustConnection, window: Window, name: &[u8]) -> Result<Option<u32>> {
    let atom = intern(connection, name)?;
    Ok(connection
        .get_property(false, window, atom, AtomEnum::CARDINAL, 0, 1)
        .map_err(platform_error)?
        .reply()
        .map_err(platform_error)?
        .value32()
        .and_then(|mut values| values.next()))
}

fn wm_class(connection: &RustConnection, window: Window) -> Result<String> {
    let reply = connection
        .get_property(false, window, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 1024)
        .map_err(platform_error)?
        .reply()
        .map_err(platform_error)?;
    Ok(String::from_utf8_lossy(&reply.value)
        .split('\0')
        .rfind(|part| !part.is_empty())
        .unwrap_or_default()
        .to_owned())
}

fn window_title(connection: &RustConnection, window: Window) -> Result<String> {
    let net_name = intern(connection, b"_NET_WM_NAME")?;
    let utf8 = intern(connection, b"UTF8_STRING")?;
    let modern = connection
        .get_property(false, window, net_name, utf8, 0, 4096)
        .map_err(platform_error)?
        .reply()
        .map_err(platform_error)?;
    if !modern.value.is_empty() {
        return Ok(String::from_utf8_lossy(&modern.value).into_owned());
    }
    let legacy = connection
        .get_property(false, window, AtomEnum::WM_NAME, AtomEnum::STRING, 0, 4096)
        .map_err(platform_error)?
        .reply()
        .map_err(platform_error)?;
    Ok(String::from_utf8_lossy(&legacy.value).into_owned())
}

fn process_name(process_id: u32) -> Option<String> {
    std::fs::read_to_string(format!("/proc/{process_id}/comm"))
        .ok()
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
}

fn platform_error(error: impl std::fmt::Display) -> FreeFlowError {
    FreeFlowError::Platform(format!("could not read X11 application context: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hyprland_terminal_context() {
        let context = context_from_hyprland_json(&serde_json::json!({
            "class": "kitty",
            "title": "shell",
            "pid": 1234,
            "address": "0x1234abcd",
            "xwayland": false
        }));
        assert_eq!(context.active_window_id, Some(0x1234_abcd));
        assert_eq!(context.process_id, Some(1234));
        assert_eq!(context.app_class, "kitty");
        assert_eq!(context.window_title, "shell");
        assert!(context.is_terminal);
    }
}
