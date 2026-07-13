use freeflow_core::SessionType;

#[must_use]
pub fn detect_session_type() -> SessionType {
    let declared = std::env::var("XDG_SESSION_TYPE")
        .unwrap_or_default()
        .to_ascii_lowercase();
    if declared == "wayland" || std::env::var_os("WAYLAND_DISPLAY").is_some() {
        SessionType::Wayland
    } else if declared == "x11" || std::env::var_os("DISPLAY").is_some() {
        SessionType::X11
    } else {
        SessionType::Unknown
    }
}

#[must_use]
pub fn desktop_environment() -> String {
    std::env::var("XDG_CURRENT_DESKTOP")
        .or_else(|_| std::env::var("DESKTOP_SESSION"))
        .unwrap_or_else(|_| "unknown".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_environment_always_returns_a_value() {
        assert!(!desktop_environment().is_empty());
    }
}
