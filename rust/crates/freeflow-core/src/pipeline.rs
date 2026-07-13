use std::{sync::Arc, time::Duration};

use serde::{Deserialize, Serialize};
use tokio::{
    sync::{Mutex, RwLock, broadcast},
    task::JoinHandle,
    time::{Instant, timeout},
};
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use crate::{
    AppContext, AppContextProvider, AppEvent, AppSettings, AudioBuffer, AudioProvider,
    DictationProvider, FreeFlowError, InjectionResult, PolishProvider, RecordingState,
    RecordingStateMachine, Result, StreamingDictationProvider, StreamingSession, TextInjector,
    TranscriptBuffer, audio, polish,
};

pub struct PipelineServices {
    pub audio: Arc<dyn AudioProvider>,
    pub context: Arc<dyn AppContextProvider>,
    pub batch: Arc<dyn DictationProvider>,
    pub streaming: Option<Arc<dyn StreamingDictationProvider>>,
    pub polish: Option<Arc<dyn PolishProvider>>,
    pub injector: Arc<dyn TextInjector>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DictationOutcome {
    pub transcript: String,
    pub injected: bool,
    pub injection: Option<InjectionResult>,
}

struct ActiveRun {
    started_at: Instant,
    context: AppContext,
    streaming: Arc<RwLock<Option<Arc<dyn StreamingSession>>>>,
    stop_tasks: CancellationToken,
    session_cancel: CancellationToken,
    stream_task: JoinHandle<()>,
    level_task: JoinHandle<()>,
}

struct PreparingRun {
    cancel: CancellationToken,
    finished: CancellationToken,
}

#[derive(Clone)]
struct RecoveryData {
    audio: AudioBuffer,
    context: AppContext,
}

/// Coordinate capture, streaming fallback, polish, and text delivery.
pub struct DictationPipeline {
    services: PipelineServices,
    state: Arc<RecordingStateMachine>,
    transcripts: Arc<TranscriptBuffer>,
    settings: RwLock<AppSettings>,
    preparing: Mutex<Option<Arc<PreparingRun>>>,
    active: Mutex<Option<ActiveRun>>,
    processing_cancel: Mutex<Option<CancellationToken>>,
    recovery: RwLock<Option<RecoveryData>>,
    events: broadcast::Sender<AppEvent>,
    last_error: RwLock<Option<String>>,
}

impl DictationPipeline {
    #[must_use]
    pub fn new(services: PipelineServices, settings: AppSettings) -> Self {
        let (events, _) = broadcast::channel(256);
        Self {
            services,
            state: Arc::new(RecordingStateMachine::new()),
            transcripts: Arc::new(TranscriptBuffer::new()),
            settings: RwLock::new(settings),
            preparing: Mutex::new(None),
            active: Mutex::new(None),
            processing_cancel: Mutex::new(None),
            recovery: RwLock::new(None),
            events,
            last_error: RwLock::new(None),
        }
    }

    #[must_use]
    pub fn state_machine(&self) -> Arc<RecordingStateMachine> {
        Arc::clone(&self.state)
    }

    #[must_use]
    pub fn transcript_buffer(&self) -> Arc<TranscriptBuffer> {
        Arc::clone(&self.transcripts)
    }

    #[must_use]
    pub fn events(&self) -> broadcast::Receiver<AppEvent> {
        self.events.subscribe()
    }

    pub async fn settings(&self) -> AppSettings {
        self.settings.read().await.clone()
    }

    pub async fn update_settings(&self, settings: AppSettings) -> Result<()> {
        settings.validate()?;
        *self.settings.write().await = settings;
        Ok(())
    }

    pub async fn last_error(&self) -> Option<String> {
        self.last_error.read().await.clone()
    }

    pub async fn start(&self) -> Result<bool> {
        let preparation = Arc::new(PreparingRun {
            cancel: CancellationToken::new(),
            finished: CancellationToken::new(),
        });
        let mut preparing = self.preparing.lock().await;
        if !self.state.begin_preparing().await {
            let state = self.state.current().await;
            debug!(?state, "ignoring duplicate dictation start");
            return Ok(false);
        }
        *preparing = Some(Arc::clone(&preparation));
        drop(preparing);
        *self.last_error.write().await = None;

        let mut audio_chunks = self.services.audio.audio_chunks();
        let mut audio_levels = self.services.audio.audio_levels();
        let audio_provider = Arc::clone(&self.services.audio);
        let capture_task = tokio::spawn(async move {
            match timeout(Duration::from_secs(5), audio_provider.start()).await {
                Ok(result) => result,
                Err(_) => Err(FreeFlowError::Timeout("microphone startup".into())),
            }
        });
        let context_provider = Arc::clone(&self.services.context);
        let context_future = async move {
            match timeout(
                Duration::from_millis(200),
                context_provider.current_context(),
            )
            .await
            {
                Ok(Ok(context)) => context,
                Ok(Err(error)) => {
                    debug!(
                        category = error.category(),
                        "application context unavailable"
                    );
                    AppContext::default()
                }
                Err(_) => AppContext::default(),
            }
        };
        let context = context_future.await;
        self.publish(AppEvent::StatusChanged {
            state: RecordingState::Preparing,
        });
        let capture = match capture_task.await {
            Ok(Ok(capture)) => capture,
            Ok(Err(error)) => {
                self.finish_preparing(&preparation).await;
                if preparation.cancel.is_cancelled() {
                    self.reset_to_idle().await;
                    return Ok(false);
                }
                self.fail(&error).await;
                return Err(error);
            }
            Err(error) => {
                let error = FreeFlowError::Internal(format!(
                    "microphone startup task stopped unexpectedly: {error}"
                ));
                self.finish_preparing(&preparation).await;
                if preparation.cancel.is_cancelled() {
                    self.reset_to_idle().await;
                    return Ok(false);
                }
                self.fail(&error).await;
                return Err(error);
            }
        };
        while audio_chunks.try_recv().is_ok() {}
        while audio_levels.try_recv().is_ok() {}
        if preparation.cancel.is_cancelled() {
            let _ = self.services.audio.stop().await;
            self.reset_to_idle().await;
            self.finish_preparing(&preparation).await;
            return Ok(false);
        }

        let settings = self.settings.read().await.clone();
        let stop_tasks = CancellationToken::new();
        let session_cancel = CancellationToken::new();
        let streaming_slot: Arc<RwLock<Option<Arc<dyn StreamingSession>>>> =
            Arc::new(RwLock::new(None));

        let level_events = self.events.clone();
        let level_cancel = stop_tasks.clone();
        let level_task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = level_cancel.cancelled() => break,
                    level = audio_levels.recv() => match level {
                        Ok(level) => {
                            let _ = level_events.send(AppEvent::RecordingLevel { level });
                        }
                        Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
        });

        let streaming_provider = if settings.realtime_enabled {
            self.services.streaming.clone()
        } else {
            None
        };
        let streaming_for_task = Arc::clone(&streaming_slot);
        let stream_stop = stop_tasks.clone();
        let stream_session_cancel = session_cancel.clone();
        let stream_events = self.events.clone();
        let language = settings.language.clone();
        let proximity = capture.device.name.to_ascii_lowercase();
        let proximity = if proximity.contains("built-in")
            || proximity.contains("internal")
            || proximity.contains("analog stereo")
        {
            crate::MicProximity::FarField
        } else {
            crate::MicProximity::NearField
        };
        let stream_task = tokio::spawn(async move {
            let Some(provider) = streaming_provider else {
                stream_stop.cancelled().await;
                return;
            };
            let begin = provider.begin(&language, proximity, stream_session_cancel);
            let session = tokio::select! {
                _ = stream_stop.cancelled() => return,
                result = timeout(Duration::from_secs(5), begin) => match result {
                    Ok(Ok(session)) => session,
                    Ok(Err(error)) => {
                        let _ = stream_events.send(AppEvent::ErrorOccurred {
                            category: "realtime".into(),
                            message: format!("Realtime setup failed; batch fallback remains available: {error}"),
                            recoverable: true,
                        });
                        return;
                    }
                    Err(_) => {
                        let _ = stream_events.send(AppEvent::ErrorOccurred {
                            category: "realtime".into(),
                            message: "Realtime setup timed out; batch fallback remains available".into(),
                            recoverable: true,
                        });
                        return;
                    }
                }
            };
            *streaming_for_task.write().await = Some(Arc::clone(&session));
            let mut partials = session.partials();
            loop {
                tokio::select! {
                    _ = stream_stop.cancelled() => {
                        while let Ok(chunk) = audio_chunks.try_recv() {
                            if session.send_audio(chunk).await.is_err() {
                                break;
                            }
                        }
                        break;
                    }
                    chunk = audio_chunks.recv() => match chunk {
                        Ok(chunk) => {
                            if let Err(error) = session.send_audio(chunk).await {
                                let _ = stream_events.send(AppEvent::ErrorOccurred {
                                    category: "realtime".into(),
                                    message: format!("Realtime audio streaming failed; batch fallback will be used: {error}"),
                                    recoverable: true,
                                });
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(count)) => {
                            warn!(dropped_chunks = count, "realtime audio consumer lagged");
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    },
                    partial = partials.recv() => match partial {
                        Ok(text) if !text.is_empty() => {
                            let _ = stream_events.send(AppEvent::TranscriptionPartial { text });
                        }
                        Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
        });

        let run = ActiveRun {
            started_at: Instant::now(),
            context,
            streaming: streaming_slot,
            stop_tasks,
            session_cancel,
            stream_task,
            level_task,
        };
        *self.active.lock().await = Some(run);
        self.transition(RecordingState::Recording).await?;
        self.publish(AppEvent::RecordingStarted {
            device_name: capture.device.name,
        });
        self.finish_preparing(&preparation).await;
        Ok(true)
    }

    pub async fn stop(&self) -> Result<Option<DictationOutcome>> {
        if self.state.current().await != RecordingState::Recording {
            let state = self.state.current().await;
            debug!(?state, "ignoring dictation stop outside recording");
            return Ok(None);
        }
        self.transition(RecordingState::Finalizing).await?;
        let Some(mut run) = self.active.lock().await.take() else {
            let error = FreeFlowError::Internal("active recording metadata was missing".into());
            self.fail(&error).await;
            return Err(error);
        };

        let audio = match timeout(Duration::from_secs(5), self.services.audio.stop()).await {
            Ok(Ok(audio)) => audio,
            Ok(Err(error)) => {
                run.stop_tasks.cancel();
                run.session_cancel.cancel();
                self.fail(&error).await;
                return Err(error);
            }
            Err(_) => {
                run.stop_tasks.cancel();
                run.session_cancel.cancel();
                let error = FreeFlowError::Timeout("microphone shutdown".into());
                self.fail(&error).await;
                return Err(error);
            }
        };
        run.stop_tasks.cancel();
        if timeout(Duration::from_secs(2), &mut run.stream_task)
            .await
            .is_err()
        {
            run.stream_task.abort();
        }
        if timeout(Duration::from_secs(1), &mut run.level_task)
            .await
            .is_err()
        {
            run.level_task.abort();
        }

        let observed_duration = run.started_at.elapsed().as_secs_f64();
        let duration = audio
            .duration_seconds()
            .max(observed_duration.min(audio.duration_seconds() + 0.1));
        self.publish(AppEvent::RecordingStopped {
            duration_seconds: audio.duration_seconds(),
        });

        if audio.duration_seconds() < crate::MINIMUM_AUDIO_DURATION_SECONDS {
            run.session_cancel.cancel();
            self.state.reset().await;
            self.publish(AppEvent::StatusChanged {
                state: RecordingState::Idle,
            });
            return Ok(None);
        }
        if audio::is_silent(&audio) {
            run.session_cancel.cancel();
            debug!(
                peak_rms = audio.peak_rms,
                ambient_rms = audio.ambient_rms,
                "discarding silent recording"
            );
            self.state.reset().await;
            self.publish(AppEvent::StatusChanged {
                state: RecordingState::Idle,
            });
            return Ok(None);
        }

        *self.recovery.write().await = Some(RecoveryData {
            audio: audio.clone(),
            context: run.context.clone(),
        });
        self.transition(RecordingState::Transcribing).await?;

        let cancellation = CancellationToken::new();
        *self.processing_cancel.lock().await = Some(cancellation.clone());
        let streaming = run.streaming.read().await.clone();
        let deadline = Self::pipeline_deadline(duration);
        let result = timeout(
            Duration::from_secs_f64(deadline),
            self.process(audio, run.context, streaming, cancellation.clone()),
        )
        .await;
        self.processing_cancel.lock().await.take();

        match result {
            Ok(Ok(outcome)) => Ok(Some(outcome)),
            Ok(Err(FreeFlowError::Cancelled)) => {
                self.state.reset().await;
                self.publish(AppEvent::StatusChanged {
                    state: RecordingState::Idle,
                });
                Err(FreeFlowError::Cancelled)
            }
            Ok(Err(FreeFlowError::EmptyAudio | FreeFlowError::SilentAudio)) => {
                self.state.reset().await;
                self.publish(AppEvent::StatusChanged {
                    state: RecordingState::Idle,
                });
                Ok(None)
            }
            Ok(Err(error)) => {
                self.fail(&error).await;
                Err(error)
            }
            Err(_) => {
                cancellation.cancel();
                let error = FreeFlowError::Timeout(format!(
                    "dictation processing exceeded {deadline:.0} seconds"
                ));
                self.fail(&error).await;
                Err(error)
            }
        }
    }

    async fn process(
        &self,
        audio: AudioBuffer,
        context: AppContext,
        streaming: Option<Arc<dyn StreamingSession>>,
        cancellation: CancellationToken,
    ) -> Result<DictationOutcome> {
        let settings = self.settings.read().await.clone();
        let raw = self
            .transcribe(&audio, streaming, &settings, cancellation.clone())
            .await?;
        if cancellation.is_cancelled() {
            return Err(FreeFlowError::Cancelled);
        }
        let raw = raw.trim();
        if raw.is_empty() {
            return Err(FreeFlowError::EmptyAudio);
        }

        self.publish(AppEvent::TranscriptionCompleted {
            character_count: raw.chars().count(),
        });
        let preprocessed = polish::preprocess(raw, &settings.language, settings.polish_mode);
        let mut final_text = preprocessed.clone();
        if settings.polish_enabled
            && !polish::is_clean_transcript(raw, &settings.language)
            && let Some(provider) = &self.services.polish
        {
            self.transition(RecordingState::Polishing).await?;
            self.publish(AppEvent::PolishStarted);
            let network_context = context.for_network(settings.share_context);
            let polished = tokio::select! {
                _ = cancellation.cancelled() => Err(FreeFlowError::Cancelled),
                result = provider.polish(
                    &preprocessed,
                    &network_context,
                    &settings.language,
                    settings.polish_mode,
                    cancellation.clone(),
                ) => result,
            };
            if let Ok(polished) = polished
                && let Some(safe) = polish::safe_model_output(&polished, &preprocessed)
            {
                final_text = polish::normalize_formatting(&safe, &settings.language);
            }
            self.publish(AppEvent::PolishCompleted {
                changed: final_text != preprocessed,
            });
        }

        let final_text = final_text.trim().to_owned();
        if final_text.is_empty() {
            return Err(FreeFlowError::EmptyAudio);
        }
        self.transcripts.store(final_text.clone()).await;
        self.transition(RecordingState::Injecting).await?;
        let delivery_text = polish::add_leading_space_if_needed(
            &final_text,
            context.focused_field_content.as_deref(),
            context.cursor_position,
        );
        match self
            .services
            .injector
            .inject(&delivery_text, &context)
            .await
        {
            Ok(injection) => {
                self.publish(AppEvent::InjectionCompleted {
                    strategy: injection.strategy.clone(),
                });
                self.transition(RecordingState::Idle).await?;
                *self.recovery.write().await = None;
                Ok(DictationOutcome {
                    transcript: final_text,
                    injected: injection.pasted || !injection.requires_manual_paste,
                    injection: Some(injection),
                })
            }
            Err(error) => {
                self.publish(AppEvent::InjectionFailed {
                    message: error.to_string(),
                });
                self.transition(RecordingState::InjectionFailed).await?;
                Ok(DictationOutcome {
                    transcript: final_text,
                    injected: false,
                    injection: None,
                })
            }
        }
    }

    async fn transcribe(
        &self,
        audio: &AudioBuffer,
        streaming: Option<Arc<dyn StreamingSession>>,
        settings: &AppSettings,
        cancellation: CancellationToken,
    ) -> Result<String> {
        if let Some(streaming) = streaming {
            let streaming_timeout =
                Duration::from_secs_f64(Self::transcript_timeout(audio.duration_seconds()));
            let result = tokio::select! {
                _ = cancellation.cancelled() => Err(FreeFlowError::Cancelled),
                result = timeout(streaming_timeout, streaming.finish()) => match result {
                    Ok(result) => result,
                    Err(_) => Err(FreeFlowError::Timeout("realtime transcript".into())),
                },
            };
            match result {
                Ok(text) if !text.trim().is_empty() => return Ok(text),
                Ok(_) => debug!("realtime returned an empty transcript; using batch fallback"),
                Err(FreeFlowError::Cancelled) => return Err(FreeFlowError::Cancelled),
                Err(error) => {
                    debug!(
                        category = error.category(),
                        "realtime failed; using batch fallback"
                    );
                }
            }
        }

        tokio::select! {
            _ = cancellation.cancelled() => Err(FreeFlowError::Cancelled),
            result = self.services.batch.transcribe(
                audio,
                &settings.language,
                cancellation.clone(),
            ) => result,
        }
    }

    pub async fn cancel(&self) -> Result<bool> {
        let current = self.state.current().await;
        if current == RecordingState::Idle {
            return Ok(false);
        }

        let preparation = { self.preparing.lock().await.clone() };
        if let Some(preparation) = preparation {
            preparation.cancel.cancel();
            let _ = timeout(Duration::from_secs(6), preparation.finished.cancelled()).await;
        }
        if let Some(run) = self.active.lock().await.take() {
            run.stop_tasks.cancel();
            run.session_cancel.cancel();
            let _ = self.services.audio.stop().await;
            if let Some(session) = run.streaming.read().await.clone() {
                session.cancel().await;
            }
            run.stream_task.abort();
            run.level_task.abort();
        }
        if let Some(cancellation) = self.processing_cancel.lock().await.take() {
            cancellation.cancel();
        }
        self.reset_to_idle().await;
        Ok(true)
    }

    pub async fn copy_last_transcript(&self) -> Result<bool> {
        let Some(text) = self.transcripts.get().await else {
            return Ok(false);
        };
        self.services.injector.copy_to_clipboard(&text).await?;
        Ok(true)
    }

    pub async fn inject_last_transcript(&self) -> Result<Option<InjectionResult>> {
        let Some(text) = self.transcripts.get().await else {
            return Ok(None);
        };
        let state = self.state.current().await;
        if !matches!(
            state,
            RecordingState::Idle | RecordingState::InjectionFailed
        ) {
            return Err(FreeFlowError::InvalidState(format!(
                "cannot inject a retained transcript from {state:?}"
            )));
        }
        self.transition(RecordingState::Injecting).await?;
        let context = self
            .services
            .context
            .current_context()
            .await
            .unwrap_or_default();
        let delivery_text = polish::add_leading_space_if_needed(
            &text,
            context.focused_field_content.as_deref(),
            context.cursor_position,
        );
        match self
            .services
            .injector
            .inject(&delivery_text, &context)
            .await
        {
            Ok(result) => {
                self.publish(AppEvent::InjectionCompleted {
                    strategy: result.strategy.clone(),
                });
                self.transition(RecordingState::Idle).await?;
                Ok(Some(result))
            }
            Err(error) => {
                self.publish(AppEvent::InjectionFailed {
                    message: error.to_string(),
                });
                self.transition(RecordingState::InjectionFailed).await?;
                Err(error)
            }
        }
    }

    pub async fn retry_last(&self) -> Result<Option<DictationOutcome>> {
        let Some(recovery) = self.recovery.read().await.clone() else {
            return Ok(None);
        };
        if self.state.current().await != RecordingState::Failed {
            return Err(FreeFlowError::InvalidState(
                "dictation retry is only available after transcription failure".into(),
            ));
        }
        self.transition(RecordingState::Transcribing).await?;
        let cancellation = CancellationToken::new();
        *self.processing_cancel.lock().await = Some(cancellation.clone());
        let deadline = Self::pipeline_deadline(recovery.audio.duration_seconds());
        let result = timeout(
            Duration::from_secs_f64(deadline),
            self.process(recovery.audio, recovery.context, None, cancellation),
        )
        .await;
        self.processing_cancel.lock().await.take();
        match result {
            Ok(Ok(outcome)) => Ok(Some(outcome)),
            Ok(Err(error)) => {
                self.fail(&error).await;
                Err(error)
            }
            Err(_) => {
                let error = FreeFlowError::Timeout("dictation retry".into());
                self.fail(&error).await;
                Err(error)
            }
        }
    }

    #[must_use]
    pub fn pipeline_deadline(recording_duration_seconds: f64) -> f64 {
        (recording_duration_seconds.max(0.0) + 45.0).min(300.0)
    }

    #[must_use]
    pub fn transcript_timeout(audio_duration_seconds: f64) -> f64 {
        (15.0 + audio_duration_seconds.max(0.0) * 0.5).clamp(15.0, 300.0)
    }

    async fn transition(&self, next: RecordingState) -> Result<()> {
        self.state.transition(next).await?;
        self.publish(AppEvent::StatusChanged { state: next });
        Ok(())
    }

    async fn finish_preparing(&self, preparation: &Arc<PreparingRun>) {
        let mut active = self.preparing.lock().await;
        if active
            .as_ref()
            .is_some_and(|candidate| Arc::ptr_eq(candidate, preparation))
        {
            active.take();
        }
        preparation.finished.cancel();
    }

    async fn reset_to_idle(&self) {
        self.state.reset().await;
        self.publish(AppEvent::StatusChanged {
            state: RecordingState::Idle,
        });
    }

    async fn fail(&self, error: &FreeFlowError) {
        *self.last_error.write().await = Some(error.to_string());
        let current = self.state.current().await;
        if RecordingStateMachine::is_valid_transition(current, RecordingState::Failed) {
            let _ = self.state.transition(RecordingState::Failed).await;
        } else {
            self.state.reset().await;
        }
        let state = self.state.current().await;
        self.publish(AppEvent::StatusChanged { state });
        self.publish(AppEvent::ErrorOccurred {
            category: error.category().into(),
            message: error.to_string(),
            recoverable: error.is_recoverable(),
        });
    }

    fn publish(&self, event: AppEvent) {
        let _ = self.events.send(event);
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    use async_trait::async_trait;

    use super::*;
    use crate::{
        AudioCaptureInfo, AudioChunk, AudioDevice, HotkeyEvent, MicProximity, PolishMode, Shortcut,
    };

    struct MockAudio {
        recording: AtomicBool,
        startup_delay: Duration,
        output: AudioBuffer,
        chunks: broadcast::Sender<AudioChunk>,
        levels: broadcast::Sender<f32>,
    }

    impl MockAudio {
        fn speaking() -> Self {
            let samples = vec![3_000; 3_200];
            let (chunks, _) = broadcast::channel(16);
            let (levels, _) = broadcast::channel(16);
            Self {
                recording: AtomicBool::new(false),
                startup_delay: Duration::ZERO,
                output: AudioBuffer {
                    samples,
                    sample_rate: 16_000,
                    channels: 1,
                    peak_rms: 0.09,
                    ambient_rms: 0.001,
                    gain: 1.0,
                    device_name: "Test Microphone".into(),
                    proximity: MicProximity::NearField,
                },
                chunks,
                levels,
            }
        }
    }

    #[async_trait]
    impl AudioProvider for MockAudio {
        async fn start(&self) -> Result<AudioCaptureInfo> {
            tokio::time::sleep(self.startup_delay).await;
            if self.recording.swap(true, Ordering::SeqCst) {
                return Err(FreeFlowError::Audio("already recording".into()));
            }
            let _ = self.levels.send(0.4);
            let _ = self.chunks.send(AudioChunk {
                samples: self.output.samples.clone(),
                sample_rate: 16_000,
            });
            Ok(AudioCaptureInfo {
                device: AudioDevice {
                    id: "test".into(),
                    name: "Test Microphone".into(),
                    is_default: true,
                    backend: "mock".into(),
                },
                sample_rate: 16_000,
                channels: 1,
            })
        }

        async fn stop(&self) -> Result<AudioBuffer> {
            self.recording.store(false, Ordering::SeqCst);
            Ok(self.output.clone())
        }

        async fn available_devices(&self) -> Result<Vec<AudioDevice>> {
            Ok(Vec::new())
        }

        async fn selected_device(&self) -> Result<Option<AudioDevice>> {
            Ok(None)
        }

        async fn select_device(&self, _id: Option<&str>) -> Result<()> {
            Ok(())
        }

        fn audio_chunks(&self) -> broadcast::Receiver<AudioChunk> {
            self.chunks.subscribe()
        }

        fn audio_levels(&self) -> broadcast::Receiver<f32> {
            self.levels.subscribe()
        }
    }

    struct MockContext;

    #[async_trait]
    impl AppContextProvider for MockContext {
        async fn current_context(&self) -> Result<AppContext> {
            Ok(AppContext::default())
        }
    }

    struct MockBatch {
        calls: AtomicUsize,
        response: Result<String>,
    }

    #[async_trait]
    impl DictationProvider for MockBatch {
        async fn transcribe(
            &self,
            _audio: &AudioBuffer,
            _language: &str,
            _cancellation: CancellationToken,
        ) -> Result<String> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.response.clone()
        }
    }

    struct MockStreamProvider {
        session: Arc<MockStream>,
    }

    struct MockStream {
        response: Result<String>,
        partials: broadcast::Sender<String>,
        cancellation: RwLock<Option<CancellationToken>>,
    }

    #[async_trait]
    impl StreamingSession for MockStream {
        async fn send_audio(&self, _audio: AudioChunk) -> Result<()> {
            Ok(())
        }

        async fn finish(&self) -> Result<String> {
            if self
                .cancellation
                .read()
                .await
                .as_ref()
                .is_some_and(CancellationToken::is_cancelled)
            {
                return Err(FreeFlowError::Cancelled);
            }
            self.response.clone()
        }

        async fn cancel(&self) {}

        fn partials(&self) -> broadcast::Receiver<String> {
            self.partials.subscribe()
        }
    }

    #[async_trait]
    impl StreamingDictationProvider for MockStreamProvider {
        async fn begin(
            &self,
            _language: &str,
            _proximity: MicProximity,
            cancellation: CancellationToken,
        ) -> Result<Arc<dyn StreamingSession>> {
            *self.session.cancellation.write().await = Some(cancellation);
            Ok(self.session.clone())
        }
    }

    struct MockPolish {
        response: Result<String>,
    }

    #[async_trait]
    impl PolishProvider for MockPolish {
        async fn polish(
            &self,
            _transcript: &str,
            _context: &AppContext,
            _language: &str,
            _mode: PolishMode,
            _cancellation: CancellationToken,
        ) -> Result<String> {
            self.response.clone()
        }
    }

    struct MockInjector {
        fail: AtomicBool,
        copied: RwLock<Option<String>>,
    }

    #[async_trait]
    impl TextInjector for MockInjector {
        async fn inject(&self, _text: &str, _context: &AppContext) -> Result<InjectionResult> {
            if self.fail.load(Ordering::SeqCst) {
                return Err(FreeFlowError::Injection("no focused field".into()));
            }
            Ok(InjectionResult {
                strategy: "mock".into(),
                pasted: true,
                clipboard_retained: false,
                requires_manual_paste: false,
                message: None,
            })
        }

        async fn copy_to_clipboard(&self, text: &str) -> Result<()> {
            *self.copied.write().await = Some(text.into());
            Ok(())
        }
    }

    fn pipeline(
        stream_response: Option<Result<String>>,
        batch_response: Result<String>,
        polish_response: Option<Result<String>>,
        injection_fails: bool,
    ) -> (DictationPipeline, Arc<MockBatch>, Arc<MockInjector>) {
        let batch = Arc::new(MockBatch {
            calls: AtomicUsize::new(0),
            response: batch_response,
        });
        let injector = Arc::new(MockInjector {
            fail: AtomicBool::new(injection_fails),
            copied: RwLock::new(None),
        });
        let streaming = stream_response.map(|response| {
            let (partials, _) = broadcast::channel(4);
            Arc::new(MockStreamProvider {
                session: Arc::new(MockStream {
                    response,
                    partials,
                    cancellation: RwLock::new(None),
                }),
            }) as Arc<dyn StreamingDictationProvider>
        });
        let polish = polish_response
            .map(|response| Arc::new(MockPolish { response }) as Arc<dyn PolishProvider>);
        let services = PipelineServices {
            audio: Arc::new(MockAudio::speaking()),
            context: Arc::new(MockContext),
            batch: batch.clone(),
            streaming,
            polish,
            injector: injector.clone(),
        };
        (
            DictationPipeline::new(services, AppSettings::default()),
            batch,
            injector,
        )
    }

    #[tokio::test]
    async fn full_streaming_cycle_injects_and_returns_idle() {
        let (pipeline, batch, _) = pipeline(
            Some(Ok("Hello world.".into())),
            Ok("batch".into()),
            None,
            false,
        );
        assert!(pipeline.start().await.unwrap());
        assert!(!pipeline.start().await.unwrap());
        tokio::time::sleep(Duration::from_millis(10)).await;
        let outcome = pipeline.stop().await.unwrap().unwrap();
        assert_eq!(outcome.transcript, "Hello world.");
        assert!(outcome.injected);
        assert_eq!(batch.calls.load(Ordering::SeqCst), 0);
        assert_eq!(pipeline.state.current().await, RecordingState::Idle);
    }

    #[tokio::test]
    async fn realtime_failure_uses_batch_fallback() {
        let (pipeline, batch, _) = pipeline(
            Some(Err(FreeFlowError::Network("disconnected".into()))),
            Ok("Fallback transcript.".into()),
            None,
            false,
        );
        pipeline.start().await.unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;
        let outcome = pipeline.stop().await.unwrap().unwrap();
        assert_eq!(outcome.transcript, "Fallback transcript.");
        assert_eq!(batch.calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn polish_failure_falls_back_to_deterministic_text() {
        let (pipeline, _, _) = pipeline(
            None,
            Ok("um hello comma world".into()),
            Some(Err(FreeFlowError::Network("polish unavailable".into()))),
            false,
        );
        pipeline.start().await.unwrap();
        let outcome = pipeline.stop().await.unwrap().unwrap();
        assert_eq!(outcome.transcript, "Hello, world");
    }

    #[tokio::test]
    async fn injection_failure_retains_transcript_for_copy() {
        let (pipeline, _, injector) = pipeline(None, Ok("Retain this.".into()), None, true);
        pipeline.start().await.unwrap();
        let outcome = pipeline.stop().await.unwrap().unwrap();
        assert!(!outcome.injected);
        assert_eq!(
            pipeline.state.current().await,
            RecordingState::InjectionFailed
        );
        assert_eq!(
            pipeline.transcripts.get().await.as_deref(),
            Some("Retain this.")
        );
        assert!(pipeline.copy_last_transcript().await.unwrap());
        assert_eq!(
            injector.copied.read().await.as_deref(),
            Some("Retain this.")
        );
    }

    #[tokio::test]
    async fn cancel_is_recoverable() {
        let (pipeline, _, _) = pipeline(None, Ok("unused".into()), None, false);
        pipeline.start().await.unwrap();
        assert!(pipeline.cancel().await.unwrap());
        assert_eq!(pipeline.state.current().await, RecordingState::Idle);
        assert!(pipeline.start().await.unwrap());
    }

    #[tokio::test]
    async fn cancel_waits_for_microphone_startup_to_release_audio() {
        let mut delayed_audio = MockAudio::speaking();
        delayed_audio.startup_delay = Duration::from_millis(100);
        let audio = Arc::new(delayed_audio);
        let batch = Arc::new(MockBatch {
            calls: AtomicUsize::new(0),
            response: Ok("unused".into()),
        });
        let injector = Arc::new(MockInjector {
            fail: AtomicBool::new(false),
            copied: RwLock::new(None),
        });
        let pipeline = Arc::new(DictationPipeline::new(
            PipelineServices {
                audio: audio.clone(),
                context: Arc::new(MockContext),
                batch,
                streaming: None,
                polish: None,
                injector,
            },
            AppSettings::default(),
        ));

        let starting = {
            let pipeline = pipeline.clone();
            tokio::spawn(async move { pipeline.start().await })
        };
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert_eq!(pipeline.state.current().await, RecordingState::Preparing);
        assert!(pipeline.cancel().await.unwrap());

        assert!(!starting.await.unwrap().unwrap());
        assert!(!audio.recording.load(Ordering::SeqCst));
        assert_eq!(pipeline.state.current().await, RecordingState::Idle);
    }

    #[test]
    fn duration_scaled_deadlines_match_native_behavior() {
        assert_eq!(DictationPipeline::pipeline_deadline(0.0), 45.0);
        assert_eq!(DictationPipeline::pipeline_deadline(30.0), 75.0);
        assert_eq!(DictationPipeline::pipeline_deadline(600.0), 300.0);
        assert_eq!(DictationPipeline::transcript_timeout(0.0), 15.0);
        assert_eq!(DictationPipeline::transcript_timeout(30.0), 30.0);
        assert_eq!(DictationPipeline::transcript_timeout(1_000.0), 300.0);
    }

    #[allow(dead_code)]
    async fn _traits_remain_object_safe(
        _hotkey: Arc<dyn crate::HotkeyProvider>,
        _shortcut: Shortcut,
        _event: HotkeyEvent,
    ) {
    }
}
