use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicU8, Ordering},
};

use async_trait::async_trait;
use cpal::{
    BufferSize, Device, HostId, SampleFormat, Stream, SupportedBufferSize,
    traits::{DeviceTrait, HostTrait, StreamTrait},
};
use freeflow_core::{
    AudioBuffer, AudioCaptureInfo, AudioChunk, AudioDevice, AudioProvider, CAPTURE_SAMPLE_RATE,
    FreeFlowError, MicProximity, Result,
    audio::{AudioMeter, StreamingResampler, apply_gain, normalized_to_i16},
};
use tokio::sync::{Mutex as AsyncMutex, RwLock, broadcast};
use tracing::{debug, warn};

const MAX_RECORDING_SECONDS: usize = 600;
const MAX_CAPTURE_SAMPLES: usize = CAPTURE_SAMPLE_RATE as usize * MAX_RECORDING_SECONDS;

struct CaptureData {
    samples: Vec<i16>,
    resampler: StreamingResampler,
    meter: AudioMeter,
    error: Option<String>,
}

struct CaptureSession {
    stream: Stream,
    data: Arc<Mutex<CaptureData>>,
    device: AudioDevice,
    source_rate: u32,
}

#[derive(Clone)]
struct LocatedDevice {
    host_id: HostId,
    device: Device,
    metadata: AudioDevice,
}

pub struct LinuxAudioProvider {
    selected_id: RwLock<Option<String>>,
    session: AsyncMutex<Option<CaptureSession>>,
    chunks: broadcast::Sender<AudioChunk>,
    levels: broadcast::Sender<f32>,
    proximity: AtomicU8,
    recording: AtomicBool,
}

impl Default for LinuxAudioProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl LinuxAudioProvider {
    #[must_use]
    pub fn new() -> Self {
        let (chunks, _) = broadcast::channel(128);
        let (levels, _) = broadcast::channel(128);
        Self {
            selected_id: RwLock::new(None),
            session: AsyncMutex::new(None),
            chunks,
            levels,
            proximity: AtomicU8::new(0),
            recording: AtomicBool::new(false),
        }
    }

    pub fn set_proximity(&self, proximity: MicProximity) {
        self.proximity.store(
            u8::from(proximity == MicProximity::FarField),
            Ordering::Relaxed,
        );
    }

    fn proximity(&self) -> MicProximity {
        if self.proximity.load(Ordering::Relaxed) == 1 {
            MicProximity::FarField
        } else {
            MicProximity::NearField
        }
    }

    pub async fn warm_up(&self) -> Result<AudioCaptureInfo> {
        let capture = self.start().await?;
        if let Some(data) = self
            .session
            .lock()
            .await
            .as_ref()
            .map(|session| session.data.clone())
        {
            let _ = wait_for_first_sample(&data, std::time::Duration::from_secs(1)).await;
        }
        self.stop().await?;
        Ok(capture)
    }

    fn enumerate_host(host_id: HostId) -> Vec<LocatedDevice> {
        let Ok(host) = cpal::host_from_id(host_id) else {
            return Vec::new();
        };
        let default_id = host
            .default_input_device()
            .and_then(|device| device.id().ok());
        let devices = match host.input_devices() {
            Ok(devices) => devices,
            Err(error) => {
                warn!(backend = host_id.name(), %error, "could not enumerate audio backend");
                return Vec::new();
            }
        };
        devices
            .filter_map(|device| {
                let native_id = device.id().ok()?;
                let name = device.to_string();
                let id = format!("{}::{native_id}", host_id.name().to_ascii_lowercase());
                let is_default = default_id.as_ref() == Some(&native_id);
                Some(LocatedDevice {
                    host_id,
                    device,
                    metadata: AudioDevice {
                        id,
                        name,
                        is_default,
                        backend: host_id.name().to_owned(),
                    },
                })
            })
            .collect()
    }

    fn enumerate_devices() -> Result<Vec<LocatedDevice>> {
        let mut found: Vec<_> = cpal::available_hosts()
            .into_iter()
            .flat_map(Self::enumerate_host)
            .collect();
        if found.is_empty() {
            return Err(FreeFlowError::NoAudioDevice);
        }
        found.sort_by_key(|device| (!device.metadata.is_default, device.metadata.name.clone()));
        Ok(found)
    }

    fn resolve_device(selected_id: Option<&str>) -> Result<(LocatedDevice, bool)> {
        if let Some(selected_id) = selected_id
            && let Some((backend, _)) = selected_id.split_once("::")
            && let Some(host_id) = cpal::available_hosts()
                .into_iter()
                .find(|host_id| host_id.name().eq_ignore_ascii_case(backend))
            && let Some(device) = Self::enumerate_host(host_id)
                .into_iter()
                .find(|device| device.metadata.id == selected_id)
        {
            return Ok((device, false));
        }
        let devices = Self::enumerate_devices()?;
        let fallback = devices
            .iter()
            .find(|device| {
                device.metadata.is_default && device.host_id == cpal::default_host().id()
            })
            .or_else(|| devices.iter().find(|device| device.metadata.is_default))
            .or_else(|| devices.first())
            .cloned()
            .ok_or(FreeFlowError::NoAudioDevice)?;
        Ok((fallback, selected_id.is_some()))
    }

    fn build_session(
        located: LocatedDevice,
        proximity: MicProximity,
        chunks: broadcast::Sender<AudioChunk>,
        levels: broadcast::Sender<f32>,
    ) -> Result<(CaptureSession, AudioCaptureInfo)> {
        let supported = located.device.default_input_config().map_err(|error| {
            FreeFlowError::Audio(format!(
                "{} ({}) has no usable default input format: {error}",
                located.metadata.name, located.metadata.backend
            ))
        })?;
        let sample_format = supported.sample_format();
        let mut config = supported.config();
        let source_rate = config.sample_rate;
        if let SupportedBufferSize::Range { min, max } = supported.buffer_size() {
            let low_latency_frames = (source_rate / 50).max(64).clamp(*min, *max);
            config.buffer_size = BufferSize::Fixed(low_latency_frames);
        }
        let channels = config.channels;
        if channels == 0 || source_rate == 0 {
            return Err(FreeFlowError::Audio(format!(
                "{} returned an invalid {channels}-channel {source_rate} Hz format",
                located.metadata.name
            )));
        }
        let data = Arc::new(Mutex::new(fresh_capture_data(source_rate, proximity)));
        let make_error_callback = || {
            let error_data = data.clone();
            move |error: cpal::Error| {
                warn!(%error, "microphone stream reported an error");
                if let Ok(mut data) = error_data.lock() {
                    data.error = Some(error.to_string());
                }
            }
        };

        macro_rules! input_stream {
            ($sample:ty, $convert:expr) => {{
                let data = data.clone();
                let chunks = chunks.clone();
                let levels = levels.clone();
                located.device.build_input_stream(
                    config,
                    move |input: &[$sample], _| {
                        process_input(input, channels, $convert, &data, &chunks, &levels);
                    },
                    make_error_callback(),
                    Some(std::time::Duration::from_secs(5)),
                )
            }};
        }

        let stream = match sample_format {
            SampleFormat::I8 => input_stream!(i8, |sample: i8| f32::from(sample) / 128.0),
            SampleFormat::I16 => {
                input_stream!(i16, |sample: i16| f32::from(sample) / 32_768.0)
            }
            SampleFormat::I32 => input_stream!(i32, |sample: i32| sample as f32 / 2_147_483_648.0),
            SampleFormat::I64 => input_stream!(i64, |sample: i64| sample as f32 / i64::MAX as f32),
            SampleFormat::U8 => input_stream!(u8, |sample: u8| (f32::from(sample) - 128.0) / 128.0),
            SampleFormat::U16 => input_stream!(u16, |sample: u16| {
                (f32::from(sample) - 32_768.0) / 32_768.0
            }),
            SampleFormat::U32 => input_stream!(u32, |sample: u32| {
                (sample as f32 - 2_147_483_648.0) / 2_147_483_648.0
            }),
            SampleFormat::U64 => input_stream!(u64, |sample: u64| {
                (sample as f64 / u64::MAX as f64 * 2.0 - 1.0) as f32
            }),
            SampleFormat::F32 => input_stream!(f32, |sample: f32| sample),
            SampleFormat::F64 => input_stream!(f64, |sample: f64| sample as f32),
            other => {
                return Err(FreeFlowError::Audio(format!(
                    "{} uses unsupported sample format {other}",
                    located.metadata.name
                )));
            }
        }
        .map_err(|error| {
            FreeFlowError::Audio(format!(
                "could not open {} through {}: {error}",
                located.metadata.name, located.metadata.backend
            ))
        })?;
        stream.play().map_err(|error| {
            FreeFlowError::Audio(format!(
                "could not start {} through {}: {error}",
                located.metadata.name, located.metadata.backend
            ))
        })?;
        debug!(
            device = located.metadata.name,
            backend = located.metadata.backend,
            source_rate,
            channels,
            "microphone capture started"
        );
        let info = AudioCaptureInfo {
            device: located.metadata.clone(),
            sample_rate: CAPTURE_SAMPLE_RATE,
            channels: 1,
        };
        Ok((
            CaptureSession {
                stream,
                data,
                device: located.metadata,
                source_rate,
            },
            info,
        ))
    }
}

#[async_trait]
impl AudioProvider for LinuxAudioProvider {
    async fn start(&self) -> Result<AudioCaptureInfo> {
        if self
            .recording
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Err(FreeFlowError::Audio(
                "microphone capture is already active".into(),
            ));
        }
        let selected = self.selected_id.read().await.clone();
        let resolved =
            tokio::task::spawn_blocking(move || Self::resolve_device(selected.as_deref()))
                .await
                .map_err(|error| FreeFlowError::Internal(error.to_string()))?;
        let (located, fell_back) = match resolved {
            Ok(value) => value,
            Err(error) => {
                self.recording.store(false, Ordering::SeqCst);
                return Err(error);
            }
        };
        if fell_back {
            warn!(
                device = located.metadata.name,
                "selected microphone disappeared; using fallback"
            );
            *self.selected_id.write().await = None;
        }
        let mut cached = self.session.lock().await;
        if let Some(session) = cached.as_mut()
            && session.device.id == located.metadata.id
        {
            if let Ok(mut data) = session.data.lock() {
                *data = fresh_capture_data(session.source_rate, self.proximity());
            } else {
                self.recording.store(false, Ordering::SeqCst);
                return Err(FreeFlowError::Audio(
                    "audio capture lock was poisoned".into(),
                ));
            }
            if let Err(error) = session.stream.play() {
                self.recording.store(false, Ordering::SeqCst);
                return Err(FreeFlowError::Audio(format!(
                    "could not resume {} through {}: {error}",
                    session.device.name, session.device.backend
                )));
            }
            let info = AudioCaptureInfo {
                device: session.device.clone(),
                sample_rate: CAPTURE_SAMPLE_RATE,
                channels: 1,
            };
            let data = session.data.clone();
            let source_rate = session.source_rate;
            drop(cached);
            if wait_for_first_sample(&data, std::time::Duration::from_millis(1_500)).await {
                let mut data = data
                    .lock()
                    .map_err(|_| FreeFlowError::Audio("audio capture lock was poisoned".into()))?;
                *data = fresh_capture_data(source_rate, self.proximity());
            }
            return Ok(info);
        }
        *cached = None;
        let result = Self::build_session(
            located,
            self.proximity(),
            self.chunks.clone(),
            self.levels.clone(),
        );
        match result {
            Ok((session, info)) => {
                *cached = Some(session);
                Ok(info)
            }
            Err(error) => {
                self.recording.store(false, Ordering::SeqCst);
                Err(error)
            }
        }
    }

    async fn stop(&self) -> Result<AudioBuffer> {
        let mut cached = self.session.lock().await;
        let session = cached
            .as_mut()
            .ok_or_else(|| FreeFlowError::Audio("microphone capture is not active".into()))?;
        self.recording.store(false, Ordering::SeqCst);
        session.stream.pause().map_err(|error| {
            FreeFlowError::Audio(format!(
                "could not pause {} through {}: {error}",
                session.device.name, session.device.backend
            ))
        })?;
        let mut data = session
            .data
            .lock()
            .map_err(|_| FreeFlowError::Audio("audio capture lock was poisoned".into()))?;
        let tail = normalized_to_i16(&data.resampler.finish());
        if data.samples.len() < MAX_CAPTURE_SAMPLES {
            let remaining = MAX_CAPTURE_SAMPLES - data.samples.len();
            data.samples.extend(tail.into_iter().take(remaining));
        }
        if data.samples.is_empty()
            && let Some(error) = data.error.take()
        {
            return Err(FreeFlowError::Audio(format!(
                "{} stopped before delivering audio: {error}",
                session.device.name
            )));
        }
        let gain = data.meter.gain();
        let samples = apply_gain(&data.samples, gain);
        debug!(
            samples = samples.len(),
            peak_rms = data.meter.peak_rms(),
            ambient_rms = data.meter.ambient_rms(),
            gain,
            "microphone capture stopped"
        );
        Ok(AudioBuffer {
            samples,
            sample_rate: CAPTURE_SAMPLE_RATE,
            channels: 1,
            peak_rms: data.meter.peak_rms(),
            ambient_rms: data.meter.ambient_rms(),
            gain,
            device_name: session.device.name.clone(),
            proximity: self.proximity(),
        })
    }

    async fn available_devices(&self) -> Result<Vec<AudioDevice>> {
        tokio::task::spawn_blocking(|| {
            Self::enumerate_devices()
                .map(|devices| devices.into_iter().map(|device| device.metadata).collect())
        })
        .await
        .map_err(|error| FreeFlowError::Internal(error.to_string()))?
    }

    async fn selected_device(&self) -> Result<Option<AudioDevice>> {
        let selected = self.selected_id.read().await.clone();
        let Some(selected) = selected else {
            return Ok(None);
        };
        Ok(self
            .available_devices()
            .await?
            .into_iter()
            .find(|device| device.id == selected))
    }

    async fn select_device(&self, id: Option<&str>) -> Result<()> {
        if self.recording.load(Ordering::SeqCst) {
            return Err(FreeFlowError::Audio(
                "stop recording before changing microphones".into(),
            ));
        }
        if let Some(id) = id {
            let exists = self
                .available_devices()
                .await?
                .iter()
                .any(|device| device.id == id);
            if !exists {
                return Err(FreeFlowError::Audio(format!(
                    "selected microphone is no longer available: {id}"
                )));
            }
        }
        let next = id.map(ToOwned::to_owned);
        let changed = *self.selected_id.read().await != next;
        *self.selected_id.write().await = next;
        if changed {
            *self.session.lock().await = None;
        }
        Ok(())
    }

    fn audio_chunks(&self) -> broadcast::Receiver<AudioChunk> {
        self.chunks.subscribe()
    }

    fn audio_levels(&self) -> broadcast::Receiver<f32> {
        self.levels.subscribe()
    }
}

fn process_input<T: Copy>(
    input: &[T],
    channels: u16,
    convert: impl Fn(T) -> f32,
    shared: &Arc<Mutex<CaptureData>>,
    chunks: &broadcast::Sender<AudioChunk>,
    levels: &broadcast::Sender<f32>,
) {
    let channels = usize::from(channels);
    let mut mono = Vec::with_capacity(input.len() / channels);
    for frame in input.chunks_exact(channels) {
        let sum: f32 = frame.iter().map(|sample| convert(*sample)).sum();
        mono.push((sum / channels as f32).clamp(-1.0, 1.0));
    }
    let Ok(mut data) = shared.lock() else {
        return;
    };
    let level = data.meter.observe(&mono);
    let gain = data.meter.gain();
    let resampled = data.resampler.process(&mono);
    let raw_chunk = normalized_to_i16(&resampled);
    if data.samples.len() < MAX_CAPTURE_SAMPLES {
        let remaining = MAX_CAPTURE_SAMPLES - data.samples.len();
        data.samples
            .extend(raw_chunk.iter().copied().take(remaining));
    }
    let streamed = apply_gain(&raw_chunk, gain);
    drop(data);
    let _ = levels.send(level);
    if !streamed.is_empty() {
        let _ = chunks.send(AudioChunk {
            samples: streamed,
            sample_rate: CAPTURE_SAMPLE_RATE,
        });
    }
}

fn fresh_capture_data(source_rate: u32, proximity: MicProximity) -> CaptureData {
    CaptureData {
        samples: Vec::with_capacity(CAPTURE_SAMPLE_RATE as usize * 30),
        resampler: StreamingResampler::new(source_rate, CAPTURE_SAMPLE_RATE),
        meter: AudioMeter::new(proximity),
        error: None,
    }
}

async fn wait_for_first_sample(
    data: &Arc<Mutex<CaptureData>>,
    timeout: std::time::Duration,
) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if data.lock().is_ok_and(|data| !data.samples.is_empty()) {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
}
