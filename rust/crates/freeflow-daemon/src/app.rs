use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

use async_trait::async_trait;
use freeflow_core::{
    AppEvent, AppSettings, AppStatus, AudioProvider, CredentialStore, Diagnostics,
    DictationPipeline, FreeFlowError, HotkeyEvent, HotkeyProvider, PermissionStatus,
    PipelineServices, Result, SessionType, SettingsStore, Shortcut,
};
use freeflow_openai::{OPENAI_API_KEY_CREDENTIAL, OpenAIProviders};
use freeflow_platform::JsonSettingsStore;
use freeflow_platform_linux::{
    LinuxAppContextProvider, LinuxAudioProvider, LinuxTextInjector, X11HotkeyProvider,
    desktop_environment, detect_session_type,
};
use freeflow_rpc::{PROTOCOL_VERSION, RpcError, RpcHandler, RpcNotification};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::{Mutex, RwLock, broadcast};
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use crate::credentials::DaemonCredentialStore;

pub struct DaemonApp {
    settings_store: Arc<JsonSettingsStore>,
    settings: RwLock<AppSettings>,
    credentials: Arc<DaemonCredentialStore>,
    audio: Arc<LinuxAudioProvider>,
    hotkey: Arc<X11HotkeyProvider>,
    pipeline: Arc<DictationPipeline>,
    openai: OpenAIProviders,
    notifications: broadcast::Sender<RpcNotification>,
    shutdown_signal: CancellationToken,
    preview_cancel: Mutex<Option<CancellationToken>>,
    preview_active: AtomicBool,
    tasks: Mutex<Vec<tokio::task::JoinHandle<()>>>,
}

impl DaemonApp {
    pub async fn new(
        settings_store: Arc<JsonSettingsStore>,
        mut settings: AppSettings,
        credentials: Arc<DaemonCredentialStore>,
        shutdown_signal: CancellationToken,
    ) -> Result<Self> {
        settings.validate()?;
        let audio = Arc::new(LinuxAudioProvider::new());
        if let Some(device) = settings.selected_audio_device.as_deref()
            && let Err(error) = audio.select_device(Some(device)).await
        {
            warn!(
                category = error.category(),
                "stored microphone is unavailable; using the system default"
            );
            settings.selected_audio_device = None;
            settings_store.save(&settings).await?;
        }
        let hotkey = Arc::new(X11HotkeyProvider::new());
        let injector = Arc::new(LinuxTextInjector::new());
        let context = Arc::new(LinuxAppContextProvider::new());
        let openai = OpenAIProviders::new(settings.clone(), credentials.clone());
        let pipeline = Arc::new(DictationPipeline::new(
            PipelineServices {
                audio: audio.clone(),
                context,
                batch: openai.batch.clone(),
                streaming: Some(openai.realtime.clone()),
                polish: Some(openai.polish.clone()),
                injector,
            },
            settings.clone(),
        ));
        let (notifications, _) = broadcast::channel(512);
        Ok(Self {
            settings_store,
            settings: RwLock::new(settings),
            credentials,
            audio,
            hotkey,
            pipeline,
            openai,
            notifications,
            shutdown_signal,
            preview_cancel: Mutex::new(None),
            preview_active: AtomicBool::new(false),
            tasks: Mutex::new(Vec::new()),
        })
    }

    pub async fn start_background_services(self: &Arc<Self>) {
        let mut pipeline_events = self.pipeline.events();
        let notification_sender = self.notifications.clone();
        let event_task = tokio::spawn(async move {
            loop {
                match pipeline_events.recv().await {
                    Ok(event) => {
                        let _ = notification_sender.send(notification_for_event(event));
                    }
                    Err(broadcast::error::RecvError::Lagged(count)) => {
                        warn!(
                            dropped_events = count,
                            "pipeline notification bridge lagged"
                        );
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });

        let mut hotkey_events = self.hotkey.events();
        let weak = Arc::downgrade(self);
        let hotkey_task = tokio::spawn(async move {
            loop {
                let event = match hotkey_events.recv().await {
                    Ok(event) => event,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                };
                let Some(app) = weak.upgrade() else { break };
                let result = match event {
                    HotkeyEvent::Pressed => app.pipeline.start().await.map(|_| ()),
                    HotkeyEvent::Released => app.pipeline.stop().await.map(|_| ()),
                };
                if let Err(error) = result {
                    debug!(
                        category = error.category(),
                        "push-to-talk action did not complete"
                    );
                }
            }
        });
        self.tasks.lock().await.extend([event_task, hotkey_task]);

        if detect_session_type() == SessionType::X11 {
            let shortcut = self.settings.read().await.shortcut.clone();
            if let Err(error) = self.hotkey.register(shortcut).await {
                let _ = self.notifications.send(RpcNotification::new(
                    "hotkey.registrationFailed",
                    json!({"message": error.to_string()}),
                ));
            }
        } else {
            let _ = self.notifications.send(RpcNotification::new(
                "hotkey.registrationFailed",
                json!({
                    "message": "The Wayland compositor did not expose a supported global-shortcut portal. Use the tray or window controls to start and stop dictation."
                }),
            ));
        }
    }

    pub async fn shutdown(&self) {
        if let Some(cancel) = self.preview_cancel.lock().await.take() {
            cancel.cancel();
        }
        let _ = self.pipeline.cancel().await;
        let _ = self.hotkey.unregister().await;
        for task in self.tasks.lock().await.drain(..) {
            task.abort();
        }
    }

    async fn status(&self) -> AppStatus {
        AppStatus {
            state: self.pipeline.state_machine().current().await,
            has_api_key: self
                .credentials
                .read(OPENAI_API_KEY_CREDENTIAL)
                .await
                .ok()
                .flatten()
                .is_some(),
            has_last_transcript: self.pipeline.transcript_buffer().has_transcript().await,
            hotkey_registered: self.hotkey.is_registered().await,
            selected_device: self.audio.selected_device().await.ok().flatten(),
            session_type: detect_session_type(),
            last_error: self.pipeline.last_error().await,
        }
    }

    async fn update_settings(&self, params: Value) -> Result<AppSettings> {
        let mut merged = serde_json::to_value(self.settings.read().await.clone())
            .map_err(|error| FreeFlowError::Internal(error.to_string()))?;
        let updates = params.get("settings").cloned().unwrap_or(params);
        let updates = updates.as_object().ok_or_else(|| {
            FreeFlowError::Configuration("settings update must be an object".into())
        })?;
        if updates
            .keys()
            .any(|key| key.to_ascii_lowercase().contains("apikey"))
        {
            return Err(FreeFlowError::Configuration(
                "API credentials must use the credential RPC methods".into(),
            ));
        }
        let target = merged
            .as_object_mut()
            .expect("serialized settings are an object");
        for (key, value) in updates {
            target.insert(key.clone(), value.clone());
        }
        let next: AppSettings = serde_json::from_value(merged).map_err(|error| {
            FreeFlowError::Configuration(format!("invalid settings update: {error}"))
        })?;
        self.apply_settings(next).await
    }

    async fn apply_settings(&self, next: AppSettings) -> Result<AppSettings> {
        next.validate()?;
        let previous = self.settings.read().await.clone();
        if next.selected_audio_device != previous.selected_audio_device {
            self.audio
                .select_device(next.selected_audio_device.as_deref())
                .await?;
        }
        if next.shortcut != previous.shortcut && self.hotkey.is_registered().await {
            self.hotkey.unregister().await?;
            if let Err(error) = self.hotkey.register(next.shortcut.clone()).await {
                let _ = self.hotkey.register(previous.shortcut).await;
                return Err(error);
            }
        }
        self.settings_store.save(&next).await?;
        self.openai.update_settings(next.clone()).await?;
        self.pipeline.update_settings(next.clone()).await?;
        *self.settings.write().await = next.clone();
        Ok(next)
    }

    async fn register_hotkey(&self) -> Result<()> {
        if detect_session_type() != SessionType::X11 {
            return Err(FreeFlowError::Hotkey(
                "global shortcuts are unavailable under this Wayland compositor; use the tray controls"
                    .into(),
            ));
        }
        let shortcut = self.settings.read().await.shortcut.clone();
        self.hotkey.register(shortcut).await
    }

    async fn start_preview(&self) -> Result<Value> {
        if self.preview_active.swap(true, Ordering::SeqCst) {
            return Err(FreeFlowError::Audio(
                "audio preview is already active".into(),
            ));
        }
        let capture = match self.audio.start().await {
            Ok(capture) => capture,
            Err(error) => {
                self.preview_active.store(false, Ordering::SeqCst);
                return Err(error);
            }
        };
        let mut levels = self.audio.audio_levels();
        let cancel = CancellationToken::new();
        *self.preview_cancel.lock().await = Some(cancel.clone());
        let notifications = self.notifications.clone();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    () = cancel.cancelled() => break,
                    level = levels.recv() => match level {
                        Ok(level) => { let _ = notifications.send(RpcNotification::new("recording.level", json!({"level": level}))); }
                        Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
        });
        self.tasks.lock().await.push(task);
        serde_json::to_value(capture).map_err(|error| FreeFlowError::Internal(error.to_string()))
    }

    async fn stop_preview(&self) -> Result<Value> {
        if !self.preview_active.swap(false, Ordering::SeqCst) {
            return Err(FreeFlowError::Audio("audio preview is not active".into()));
        }
        if let Some(cancel) = self.preview_cancel.lock().await.take() {
            cancel.cancel();
        }
        let buffer = self.audio.stop().await?;
        Ok(json!({
            "durationSeconds": buffer.duration_seconds(),
            "peakRms": buffer.peak_rms,
            "ambientRms": buffer.ambient_rms,
            "gain": buffer.gain
        }))
    }

    async fn permission_status(&self) -> PermissionStatus {
        let session = detect_session_type();
        PermissionStatus {
            microphone: if self.audio.available_devices().await.is_ok() {
                "available".into()
            } else {
                "unavailable".into()
            },
            global_shortcut: match session {
                SessionType::X11 if self.hotkey.is_registered().await => "registered".into(),
                SessionType::X11 => "available".into(),
                SessionType::Wayland => "portalUnavailable".into(),
                SessionType::Unknown => "unavailable".into(),
            },
            text_injection: if session == SessionType::X11 {
                "clipboardAndXTest".into()
            } else {
                "clipboardOnly".into()
            },
            session_type: session,
            message: (session == SessionType::Wayland).then(|| {
                "Wayland may require tray activation and a manual paste. FreeFlow keeps the transcript in the clipboard."
                    .into()
            }),
        }
    }

    async fn diagnostics(&self) -> Diagnostics {
        let selected = self.audio.selected_device().await.ok().flatten();
        let mut details = BTreeMap::new();
        details.insert("architecture".into(), std::env::consts::ARCH.into());
        details.insert(
            "displayAvailable".into(),
            std::env::var_os("DISPLAY").is_some().to_string(),
        );
        details.insert(
            "waylandDisplayAvailable".into(),
            std::env::var_os("WAYLAND_DISPLAY").is_some().to_string(),
        );
        Diagnostics {
            version: env!("CARGO_PKG_VERSION").into(),
            os: std::env::consts::OS.into(),
            desktop_environment: desktop_environment(),
            session_type: detect_session_type(),
            audio_backend: selected
                .as_ref()
                .map_or_else(|| "not selected".into(), |device| device.backend.clone()),
            shortcut_backend: if detect_session_type() == SessionType::X11 {
                "XGrabKey".into()
            } else {
                "none".into()
            },
            injection_backend: if detect_session_type() == SessionType::X11 {
                "clipboard + XTest".into()
            } else {
                "clipboard".into()
            },
            config_path: self.settings_store.path().display().to_string(),
            log_path: std::env::var("FREEFLOW_LOG_PATH").unwrap_or_default(),
            credential_store_available: self.credentials.is_available().await,
            details,
        }
    }

    async fn export_diagnostics(&self, params: Value) -> Result<PathBuf> {
        let diagnostics = self.diagnostics().await;
        let requested = params
            .get("path")
            .and_then(Value::as_str)
            .map(PathBuf::from);
        let path = requested.unwrap_or_else(|| {
            self.settings_store
                .path()
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .join("diagnostics.json")
        });
        let contents = serde_json::to_vec_pretty(&diagnostics)
            .map_err(|error| FreeFlowError::Internal(error.to_string()))?;
        let write_path = path.clone();
        tokio::task::spawn_blocking(move || write_private(&write_path, &contents))
            .await
            .map_err(|error| FreeFlowError::Internal(error.to_string()))??;
        Ok(path)
    }
}

#[async_trait]
impl RpcHandler for DaemonApp {
    async fn handle(&self, method: &str, params: Value) -> std::result::Result<Value, RpcError> {
        let value = match method {
            "app.getStatus" => serde_json::to_value(self.status().await),
            "app.getVersion" => Ok(json!({
                "version": env!("CARGO_PKG_VERSION"),
                "protocolVersion": PROTOCOL_VERSION
            })),
            "app.shutdown" => {
                let shutdown = self.shutdown_signal.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    shutdown.cancel();
                });
                Ok(json!({"accepted": true}))
            }
            "settings.get" => serde_json::to_value(self.settings.read().await.clone()),
            "settings.update" => serde_json::to_value(self.update_settings(params).await?),
            "settings.reset" => {
                serde_json::to_value(self.apply_settings(AppSettings::default()).await?)
            }
            "credentials.hasApiKey" => Ok(json!({
                "hasApiKey": self.credentials.read(OPENAI_API_KEY_CREDENTIAL).await?.is_some(),
                "secureStoreAvailable": self.credentials.is_available().await
            })),
            "credentials.setApiKey" => {
                let request: SetApiKey = parse_params(params)?;
                if request.api_key.trim().len() < 8 {
                    return Err(RpcError::invalid_params("API key is too short"));
                }
                if request.persist {
                    self.credentials
                        .persist_api_key(request.api_key.trim())
                        .await?;
                } else {
                    self.credentials
                        .set_session_api_key(Some(request.api_key.trim().to_owned()))
                        .await;
                }
                Ok(json!({"stored": request.persist, "sessionOnly": !request.persist}))
            }
            "credentials.deleteApiKey" => {
                self.credentials.set_session_api_key(None).await;
                if self.credentials.is_available().await {
                    self.credentials.delete(OPENAI_API_KEY_CREDENTIAL).await?;
                }
                Ok(json!({"deleted": true}))
            }
            "audio.listDevices" => serde_json::to_value(self.audio.available_devices().await?),
            "audio.selectDevice" => {
                let request: SelectDevice = parse_params(params)?;
                let mut settings = self.settings.read().await.clone();
                settings.selected_audio_device = request.id;
                serde_json::to_value(self.apply_settings(settings).await?)
            }
            "audio.startPreview" => Ok(self.start_preview().await?),
            "audio.stopPreview" => Ok(self.stop_preview().await?),
            "hotkey.get" => Ok(json!({
                "shortcut": self.settings.read().await.shortcut,
                "registered": self.hotkey.is_registered().await
            })),
            "hotkey.set" => {
                let request: SetHotkey = parse_params(params)?;
                let mut settings = self.settings.read().await.clone();
                settings.shortcut = request.shortcut;
                serde_json::to_value(self.apply_settings(settings).await?)
            }
            "hotkey.register" => {
                self.register_hotkey().await?;
                Ok(json!({"registered": true}))
            }
            "hotkey.unregister" => {
                self.hotkey.unregister().await?;
                Ok(json!({"registered": false}))
            }
            "dictation.start" => Ok(json!({"started": self.pipeline.start().await?})),
            "dictation.stop" => serde_json::to_value(self.pipeline.stop().await?),
            "dictation.cancel" => Ok(json!({"cancelled": self.pipeline.cancel().await?})),
            "dictation.retryLast" => serde_json::to_value(self.pipeline.retry_last().await?),
            "dictation.copyLastTranscript" => {
                Ok(json!({"copied": self.pipeline.copy_last_transcript().await?}))
            }
            "dictation.injectLastTranscript" => {
                serde_json::to_value(self.pipeline.inject_last_transcript().await?)
            }
            "permissions.getStatus" => serde_json::to_value(self.permission_status().await),
            "permissions.request" => {
                if detect_session_type() == SessionType::X11 && !self.hotkey.is_registered().await {
                    let _ = self.register_hotkey().await;
                }
                serde_json::to_value(self.permission_status().await)
            }
            "diagnostics.get" => serde_json::to_value(self.diagnostics().await),
            "diagnostics.export" => Ok(json!({
                "path": self.export_diagnostics(params).await?.display().to_string()
            })),
            _ => return Err(RpcError::method_not_found(method)),
        }
        .map_err(|error| RpcError::from(FreeFlowError::Internal(error.to_string())))?;
        Ok(value)
    }

    fn notifications(&self) -> broadcast::Receiver<RpcNotification> {
        self.notifications.subscribe()
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetApiKey {
    api_key: String,
    #[serde(default = "default_true")]
    persist: bool,
}

#[derive(Deserialize)]
struct SelectDevice {
    #[serde(default)]
    id: Option<String>,
}

#[derive(Deserialize)]
struct SetHotkey {
    shortcut: Shortcut,
}

fn default_true() -> bool {
    true
}

fn parse_params<T: for<'de> Deserialize<'de>>(params: Value) -> std::result::Result<T, RpcError> {
    serde_json::from_value(params)
        .map_err(|error| RpcError::invalid_params(format!("invalid parameters: {error}")))
}

fn notification_for_event(event: AppEvent) -> RpcNotification {
    match event {
        AppEvent::StatusChanged { state } => {
            RpcNotification::new("status.changed", json!({"state": state}))
        }
        AppEvent::RecordingStarted { device_name } => {
            RpcNotification::new("recording.started", json!({"deviceName": device_name}))
        }
        AppEvent::RecordingLevel { level } => {
            RpcNotification::new("recording.level", json!({"level": level}))
        }
        AppEvent::RecordingStopped { duration_seconds } => RpcNotification::new(
            "recording.stopped",
            json!({"durationSeconds": duration_seconds}),
        ),
        AppEvent::TranscriptionPartial { text } => {
            RpcNotification::new("transcription.partial", json!({"text": text}))
        }
        AppEvent::TranscriptionCompleted { character_count } => RpcNotification::new(
            "transcription.completed",
            json!({"characterCount": character_count}),
        ),
        AppEvent::PolishStarted => RpcNotification::new("polish.started", Value::Null),
        AppEvent::PolishCompleted { changed } => {
            RpcNotification::new("polish.completed", json!({"changed": changed}))
        }
        AppEvent::InjectionCompleted { strategy } => {
            RpcNotification::new("injection.completed", json!({"strategy": strategy}))
        }
        AppEvent::InjectionFailed { message } => {
            RpcNotification::new("injection.failed", json!({"message": message}))
        }
        AppEvent::HotkeyRegistrationFailed { message } => {
            RpcNotification::new("hotkey.registrationFailed", json!({"message": message}))
        }
        AppEvent::AudioDeviceChanged { device } => {
            RpcNotification::new("audio.deviceChanged", json!({"device": device}))
        }
        AppEvent::ErrorOccurred {
            category,
            message,
            recoverable,
        } => RpcNotification::new(
            "error.occurred",
            json!({
                "category": category,
                "message": message,
                "recoverable": recoverable
            }),
        ),
    }
}

#[cfg(unix)]
fn write_private(path: &Path, contents: &[u8]) -> Result<()> {
    use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt};

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| {
            FreeFlowError::Configuration(format!("could not create diagnostics directory: {error}"))
        })?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| {
            FreeFlowError::Configuration(format!("could not create diagnostics export: {error}"))
        })?;
    file.write_all(contents).map_err(|error| {
        FreeFlowError::Configuration(format!("could not write diagnostics export: {error}"))
    })
}

#[cfg(not(unix))]
fn write_private(path: &Path, contents: &[u8]) -> Result<()> {
    std::fs::write(path, contents).map_err(|error| {
        FreeFlowError::Configuration(format!("could not write diagnostics export: {error}"))
    })
}
