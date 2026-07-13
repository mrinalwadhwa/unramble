use serde::{Deserialize, Serialize};
use thiserror::Error;

pub type Result<T> = std::result::Result<T, FreeFlowError>;

/// Errors exposed across the core and local RPC boundary.
#[derive(Debug, Clone, Error, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "category", content = "detail", rename_all = "camelCase")]
pub enum FreeFlowError {
    #[error("invalid state transition: {0}")]
    InvalidState(String),
    #[error("audio capture failed: {0}")]
    Audio(String),
    #[error("no microphone input device is available")]
    NoAudioDevice,
    #[error("the recording did not contain enough audio")]
    EmptyAudio,
    #[error("the recording did not contain detectable speech")]
    SilentAudio,
    #[error("global shortcut registration failed: {0}")]
    Hotkey(String),
    #[error("text injection failed: {0}")]
    Injection(String),
    #[error("clipboard access failed: {0}")]
    Clipboard(String),
    #[error("secure credential storage is unavailable: {0}")]
    CredentialUnavailable(String),
    #[error("no API key is configured")]
    MissingApiKey,
    #[error("the API key was rejected")]
    AuthenticationFailed,
    #[error("the API rate limit was reached")]
    RateLimited,
    #[error("API request failed with status {status}: {message}")]
    Api { status: u16, message: String },
    #[error("network request failed: {0}")]
    Network(String),
    #[error("operation timed out: {0}")]
    Timeout(String),
    #[error("operation cancelled")]
    Cancelled,
    #[error("invalid service response: {0}")]
    InvalidResponse(String),
    #[error("invalid configuration: {0}")]
    Configuration(String),
    #[error("platform integration failed: {0}")]
    Platform(String),
    #[error("internal error: {0}")]
    Internal(String),
}

impl FreeFlowError {
    #[must_use]
    pub fn category(&self) -> &'static str {
        match self {
            Self::InvalidState(_) => "state",
            Self::Audio(_) | Self::NoAudioDevice | Self::EmptyAudio | Self::SilentAudio => "audio",
            Self::Hotkey(_) => "hotkey",
            Self::Injection(_) | Self::Clipboard(_) => "injection",
            Self::CredentialUnavailable(_) | Self::MissingApiKey => "credentials",
            Self::AuthenticationFailed => "authentication",
            Self::RateLimited => "rateLimit",
            Self::Api { .. } => "api",
            Self::Network(_) => "network",
            Self::Timeout(_) => "timeout",
            Self::Cancelled => "cancelled",
            Self::InvalidResponse(_) => "response",
            Self::Configuration(_) => "configuration",
            Self::Platform(_) => "platform",
            Self::Internal(_) => "internal",
        }
    }

    #[must_use]
    pub fn is_recoverable(&self) -> bool {
        !matches!(
            self,
            Self::AuthenticationFailed | Self::CredentialUnavailable(_)
        )
    }
}
