use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use crate::{
    AppContext, AppSettings, AudioBuffer, AudioCaptureInfo, AudioChunk, AudioDevice, HotkeyEvent,
    InjectionResult, MicProximity, PolishMode, Result, Shortcut,
};

#[async_trait]
pub trait AudioProvider: Send + Sync {
    async fn start(&self) -> Result<AudioCaptureInfo>;
    async fn stop(&self) -> Result<AudioBuffer>;
    async fn available_devices(&self) -> Result<Vec<AudioDevice>>;
    async fn selected_device(&self) -> Result<Option<AudioDevice>>;
    async fn select_device(&self, id: Option<&str>) -> Result<()>;
    fn audio_chunks(&self) -> broadcast::Receiver<AudioChunk>;
    fn audio_levels(&self) -> broadcast::Receiver<f32>;
}

#[async_trait]
pub trait HotkeyProvider: Send + Sync {
    async fn register(&self, shortcut: Shortcut) -> Result<()>;
    async fn unregister(&self) -> Result<()>;
    fn events(&self) -> broadcast::Receiver<HotkeyEvent>;
    async fn is_registered(&self) -> bool;
}

#[async_trait]
pub trait TextInjector: Send + Sync {
    async fn inject(&self, text: &str, context: &AppContext) -> Result<InjectionResult>;
    async fn copy_to_clipboard(&self, text: &str) -> Result<()>;
}

#[async_trait]
pub trait AppContextProvider: Send + Sync {
    async fn current_context(&self) -> Result<AppContext>;
}

#[async_trait]
pub trait DictationProvider: Send + Sync {
    async fn transcribe(
        &self,
        audio: &AudioBuffer,
        language: &str,
        cancellation: CancellationToken,
    ) -> Result<String>;
}

#[async_trait]
pub trait StreamingSession: Send + Sync {
    async fn send_audio(&self, audio: AudioChunk) -> Result<()>;
    async fn finish(&self) -> Result<String>;
    async fn cancel(&self);
    fn partials(&self) -> broadcast::Receiver<String>;
}

#[async_trait]
pub trait StreamingDictationProvider: Send + Sync {
    async fn begin(
        &self,
        language: &str,
        proximity: MicProximity,
        cancellation: CancellationToken,
    ) -> Result<Arc<dyn StreamingSession>>;
}

#[async_trait]
pub trait PolishProvider: Send + Sync {
    async fn polish(
        &self,
        transcript: &str,
        context: &AppContext,
        language: &str,
        mode: PolishMode,
        cancellation: CancellationToken,
    ) -> Result<String>;
}

#[async_trait]
pub trait CredentialStore: Send + Sync {
    async fn read(&self, key: &str) -> Result<Option<String>>;
    async fn write(&self, key: &str, value: &str) -> Result<()>;
    async fn delete(&self, key: &str) -> Result<()>;
    async fn is_available(&self) -> bool;
}

#[async_trait]
pub trait SettingsStore: Send + Sync {
    async fn load(&self) -> Result<AppSettings>;
    async fn save(&self, settings: &AppSettings) -> Result<()>;
    async fn reset(&self) -> Result<AppSettings>;
}
