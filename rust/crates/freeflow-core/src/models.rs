use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const CAPTURE_SAMPLE_RATE: u32 = 16_000;
pub const REALTIME_SAMPLE_RATE: u32 = 24_000;
pub const CAPTURE_CHANNELS: u16 = 1;
pub const CAPTURE_BITS_PER_SAMPLE: u16 = 16;
pub const MINIMUM_AUDIO_DURATION_SECONDS: f64 = 0.1;
pub const DEFAULT_SILENCE_THRESHOLD: f32 = 0.005;
pub const FAR_FIELD_SILENCE_THRESHOLD: f32 = 0.001;
pub const AMBIENT_MULTIPLIER: f32 = 1.2;
pub const MINIMUM_ADAPTIVE_THRESHOLD: f32 = 0.0005;
pub const MAXIMUM_ADAPTIVE_THRESHOLD: f32 = 0.01;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum RecordingState {
    #[default]
    Idle,
    Preparing,
    Recording,
    Finalizing,
    Transcribing,
    Polishing,
    Injecting,
    InjectionFailed,
    Failed,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum SessionType {
    X11,
    Wayland,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum MicProximity {
    #[default]
    NearField,
    FarField,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AudioBuffer {
    pub samples: Vec<i16>,
    pub sample_rate: u32,
    pub channels: u16,
    pub peak_rms: f32,
    pub ambient_rms: f32,
    pub gain: f32,
    pub device_name: String,
    pub proximity: MicProximity,
}

impl AudioBuffer {
    #[must_use]
    pub fn empty() -> Self {
        Self {
            samples: Vec::new(),
            sample_rate: CAPTURE_SAMPLE_RATE,
            channels: CAPTURE_CHANNELS,
            peak_rms: 0.0,
            ambient_rms: 0.0,
            gain: 1.0,
            device_name: "System Default".into(),
            proximity: MicProximity::NearField,
        }
    }

    #[must_use]
    pub fn duration_seconds(&self) -> f64 {
        if self.sample_rate == 0 || self.channels == 0 {
            return 0.0;
        }
        self.samples.len() as f64 / f64::from(self.sample_rate) / f64::from(self.channels)
    }

    #[must_use]
    pub fn pcm_le_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(self.samples.len() * 2);
        for sample in &self.samples {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        bytes
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AudioChunk {
    pub samples: Vec<i16>,
    pub sample_rate: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AudioDevice {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub backend: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AudioCaptureInfo {
    pub device: AudioDevice,
    pub sample_rate: u32,
    pub channels: u16,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub enum ShortcutModifier {
    Control,
    Alt,
    Shift,
    Super,
    LeftControl,
    RightControl,
    LeftAlt,
    RightAlt,
    LeftShift,
    RightShift,
    LeftSuper,
    RightSuper,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Shortcut {
    pub modifiers: Vec<ShortcutModifier>,
    /// XKB-style key name, such as `space`, `d`, or `F9`. `None` makes
    /// the modifier or modifier chord itself act as push-to-talk.
    pub key: Option<String>,
}

impl Shortcut {
    #[must_use]
    pub fn default_linux() -> Self {
        Self {
            modifiers: vec![ShortcutModifier::Control, ShortcutModifier::Super],
            key: None,
        }
    }

    #[must_use]
    pub fn is_modifier_only(&self) -> bool {
        self.key.is_none()
    }

    pub fn validate(&self) -> crate::Result<()> {
        if self.key.is_none() && self.modifiers.is_empty() {
            return Err(crate::FreeFlowError::Configuration(
                "modifier-only shortcuts require at least one modifier".into(),
            ));
        }
        if self.key.as_ref().is_some_and(|key| key.trim().is_empty()) {
            return Err(crate::FreeFlowError::Configuration(
                "shortcut key cannot be empty".into(),
            ));
        }
        Ok(())
    }

    #[must_use]
    pub fn display_name(&self) -> String {
        let mut parts: Vec<&str> = self
            .modifiers
            .iter()
            .map(|modifier| match modifier {
                ShortcutModifier::Control => "Ctrl",
                ShortcutModifier::Alt => "Alt",
                ShortcutModifier::Shift => "Shift",
                ShortcutModifier::Super => "Win",
                ShortcutModifier::LeftControl => "Left Ctrl",
                ShortcutModifier::RightControl => "Right Ctrl",
                ShortcutModifier::LeftAlt => "Left Alt",
                ShortcutModifier::RightAlt => "Right Alt",
                ShortcutModifier::LeftShift => "Left Shift",
                ShortcutModifier::RightShift => "Right Shift",
                ShortcutModifier::LeftSuper => "Left Win",
                ShortcutModifier::RightSuper => "Right Win",
            })
            .collect();
        if let Some(key) = &self.key {
            parts.push(key);
        }
        parts.join("+")
    }
}

impl Default for Shortcut {
    fn default() -> Self {
        Self::default_linux()
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum HotkeyEvent {
    Pressed,
    Released,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct AppContext {
    pub active_window_id: Option<u64>,
    pub process_id: Option<u32>,
    pub app_class: String,
    pub app_name: String,
    pub window_title: String,
    pub desktop_environment: String,
    pub is_terminal: bool,
    pub is_editable: Option<bool>,
    pub focused_field_content: Option<String>,
    pub selected_text: Option<String>,
    pub cursor_position: Option<usize>,
}

impl AppContext {
    #[must_use]
    pub fn for_network(&self, share_context: bool) -> Self {
        if share_context {
            self.clone()
        } else {
            Self::default()
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum PolishMode {
    Minimal,
    #[default]
    Normal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub api_base_url: String,
    pub realtime_model: String,
    pub transcription_model: String,
    pub polish_model: String,
    pub language: String,
    pub polish_enabled: bool,
    pub polish_mode: PolishMode,
    pub share_context: bool,
    pub selected_audio_device: Option<String>,
    pub shortcut: Shortcut,
    pub start_on_login: bool,
    pub realtime_enabled: bool,
    pub request_timeout_seconds: u64,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            api_base_url: "https://api.openai.com/v1".into(),
            realtime_model: "gpt-realtime-whisper".into(),
            transcription_model: "gpt-4o-mini-transcribe".into(),
            polish_model: "gpt-5.4-nano".into(),
            language: "en".into(),
            polish_enabled: true,
            polish_mode: PolishMode::Normal,
            share_context: false,
            selected_audio_device: None,
            shortcut: Shortcut::default(),
            start_on_login: true,
            realtime_enabled: true,
            request_timeout_seconds: 60,
        }
    }
}

impl AppSettings {
    pub fn validate(&self) -> crate::Result<()> {
        if !(self.api_base_url.starts_with("https://")
            || self.api_base_url.starts_with("http://127.0.0.1")
            || self.api_base_url.starts_with("http://localhost"))
        {
            return Err(crate::FreeFlowError::Configuration(
                "API base URL must use HTTPS unless it targets localhost".into(),
            ));
        }
        if self.realtime_model.trim().is_empty()
            || self.transcription_model.trim().is_empty()
            || self.polish_model.trim().is_empty()
        {
            return Err(crate::FreeFlowError::Configuration(
                "model names cannot be empty".into(),
            ));
        }
        if !(5..=300).contains(&self.request_timeout_seconds) {
            return Err(crate::FreeFlowError::Configuration(
                "request timeout must be between 5 and 300 seconds".into(),
            ));
        }
        self.shortcut.validate()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InjectionResult {
    pub strategy: String,
    pub pasted: bool,
    pub clipboard_retained: bool,
    pub requires_manual_paste: bool,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PermissionStatus {
    pub microphone: String,
    pub global_shortcut: String,
    pub text_injection: String,
    pub session_type: SessionType,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum AppEvent {
    StatusChanged {
        state: RecordingState,
    },
    RecordingStarted {
        device_name: String,
    },
    RecordingLevel {
        level: f32,
    },
    RecordingStopped {
        duration_seconds: f64,
    },
    TranscriptionPartial {
        text: String,
    },
    TranscriptionCompleted {
        character_count: usize,
    },
    PolishStarted,
    PolishCompleted {
        changed: bool,
    },
    InjectionCompleted {
        strategy: String,
    },
    InjectionFailed {
        message: String,
    },
    HotkeyRegistrationFailed {
        message: String,
    },
    AudioDeviceChanged {
        device: AudioDevice,
    },
    ErrorOccurred {
        category: String,
        message: String,
        recoverable: bool,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AppStatus {
    pub state: RecordingState,
    pub has_api_key: bool,
    pub has_last_transcript: bool,
    pub hotkey_registered: bool,
    pub selected_device: Option<AudioDevice>,
    pub session_type: SessionType,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Diagnostics {
    pub version: String,
    pub os: String,
    pub desktop_environment: String,
    pub session_type: SessionType,
    pub audio_backend: String,
    pub shortcut_backend: String,
    pub injection_backend: String,
    pub config_path: String,
    pub log_path: String,
    pub credential_store_available: bool,
    pub details: BTreeMap<String, String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_defaults_enable_startup_and_control_super_push_to_talk() {
        let settings = AppSettings::default();

        assert!(settings.start_on_login);
        assert_eq!(
            settings.shortcut.modifiers,
            vec![ShortcutModifier::Control, ShortcutModifier::Super]
        );
        assert_eq!(settings.shortcut.key, None);
        assert_eq!(settings.shortcut.display_name(), "Ctrl+Win");
        settings.validate().unwrap();
    }

    #[test]
    fn modifier_chords_require_at_least_one_modifier() {
        let empty = Shortcut {
            modifiers: Vec::new(),
            key: None,
        };

        assert!(empty.validate().is_err());
    }
}
