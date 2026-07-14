//! Linux audio, desktop, clipboard, hotkey, and credential integrations.

mod audio;
mod context;
mod credentials;
mod hotkey;
mod injection;
mod portal_hotkey;
mod session;
mod x11;

pub use audio::LinuxAudioProvider;
pub use context::LinuxAppContextProvider;
pub use credentials::SecretServiceCredentialStore;
pub use hotkey::{LinuxHotkeyProvider, X11HotkeyProvider};
pub use injection::LinuxTextInjector;
pub use portal_hotkey::PortalHotkeyProvider;
pub use session::{desktop_environment, detect_session_type};
