use std::{collections::HashMap, sync::Arc};

use async_trait::async_trait;
use freeflow_core::{
    AppContext, AppSettings, AudioBuffer, AudioChunk, CAPTURE_SAMPLE_RATE, CredentialStore,
    DictationProvider, FreeFlowError, MicProximity, PolishMode, PolishProvider, Result,
    StreamingDictationProvider,
};
use freeflow_mock_openai::{
    MockServer, Scenario, TEST_API_KEY, TEST_POLISHED_TRANSCRIPT, TEST_TRANSCRIPT,
};
use freeflow_openai::{OPENAI_API_KEY_CREDENTIAL, OpenAIProviders};
use tokio::sync::RwLock;
use tokio_util::sync::CancellationToken;

#[derive(Default)]
struct MemoryCredentials {
    values: RwLock<HashMap<String, String>>,
}

impl MemoryCredentials {
    async fn with_api_key(key: &str) -> Arc<Self> {
        let store = Arc::new(Self::default());
        store.write(OPENAI_API_KEY_CREDENTIAL, key).await.unwrap();
        store
    }
}

#[async_trait]
impl CredentialStore for MemoryCredentials {
    async fn read(&self, key: &str) -> Result<Option<String>> {
        Ok(self.values.read().await.get(key).cloned())
    }

    async fn write(&self, key: &str, value: &str) -> Result<()> {
        self.values
            .write()
            .await
            .insert(key.to_owned(), value.to_owned());
        Ok(())
    }

    async fn delete(&self, key: &str) -> Result<()> {
        self.values.write().await.remove(key);
        Ok(())
    }

    async fn is_available(&self) -> bool {
        true
    }
}

async fn providers(scenario: Scenario) -> (MockServer, OpenAIProviders) {
    let server = MockServer::start(scenario).await.unwrap();
    let settings = AppSettings {
        api_base_url: server.api_base_url.clone(),
        realtime_model: "mock-realtime-model".into(),
        transcription_model: "mock-transcription-model".into(),
        polish_model: "mock-polish-model".into(),
        request_timeout_seconds: 5,
        ..AppSettings::default()
    };
    let credentials = MemoryCredentials::with_api_key(TEST_API_KEY).await;
    (server, OpenAIProviders::new(settings, credentials))
}

fn audio() -> AudioBuffer {
    AudioBuffer {
        samples: vec![1_000; CAPTURE_SAMPLE_RATE as usize],
        sample_rate: CAPTURE_SAMPLE_RATE,
        channels: 1,
        peak_rms: 0.1,
        ambient_rms: 0.001,
        gain: 1.0,
        device_name: "test source".into(),
        proximity: MicProximity::NearField,
    }
}

#[tokio::test]
async fn transcribes_wav_through_the_batch_endpoint() {
    let (server, providers) = providers(Scenario::Success).await;
    let transcript = providers
        .batch
        .transcribe(&audio(), "en", CancellationToken::new())
        .await
        .unwrap();

    assert_eq!(transcript, TEST_TRANSCRIPT);
    assert_eq!(server.metrics().await.batch_requests, 1);
}

#[tokio::test]
async fn polishes_without_exposing_context_unless_it_is_supplied() {
    let (server, providers) = providers(Scenario::Success).await;
    let transcript = providers
        .polish
        .polish(
            "freeflow deterministic transcript",
            &AppContext::default(),
            "en",
            PolishMode::Normal,
            CancellationToken::new(),
        )
        .await
        .unwrap();

    assert_eq!(transcript, TEST_POLISHED_TRANSCRIPT);
    assert_eq!(server.metrics().await.polish_requests, 1);
}

#[tokio::test]
async fn streams_resampled_audio_and_delivers_partial_and_final_text() {
    let (server, providers) = providers(Scenario::Success).await;
    let session = providers
        .realtime
        .begin("en", MicProximity::NearField, CancellationToken::new())
        .await
        .unwrap();
    let mut partials = session.partials();
    session
        .send_audio(AudioChunk {
            samples: vec![1_000; CAPTURE_SAMPLE_RATE as usize],
            sample_rate: CAPTURE_SAMPLE_RATE,
        })
        .await
        .unwrap();
    let transcript = session.finish().await.unwrap();

    assert_eq!(transcript, TEST_TRANSCRIPT);
    assert_eq!(partials.recv().await.unwrap(), "FreeFlow deterministic ");
    let metrics = server.metrics().await;
    assert_eq!(metrics.realtime_connections, 1);
    assert_eq!(
        metrics.realtime_model.as_deref(),
        Some("mock-realtime-model")
    );
    assert_eq!(metrics.realtime_audio_bytes, 24_000 * 2);
}

#[tokio::test]
async fn maps_rejected_credentials_to_a_safe_error() {
    let (_server, providers) = providers(Scenario::AuthenticationFailure).await;
    let error = providers
        .batch
        .transcribe(&audio(), "en", CancellationToken::new())
        .await
        .unwrap_err();
    assert_eq!(error, FreeFlowError::AuthenticationFailed);
}

#[tokio::test]
async fn reports_a_realtime_disconnect_for_batch_fallback() {
    let (_server, providers) = providers(Scenario::BatchFallback).await;
    let session = providers
        .realtime
        .begin("en", MicProximity::NearField, CancellationToken::new())
        .await
        .unwrap();
    let error = session.finish().await.unwrap_err();
    assert_eq!(error.category(), "network");
}

#[tokio::test]
async fn preserves_the_server_error_after_the_realtime_socket_closes() {
    let (_server, providers) = providers(Scenario::RealtimeError).await;
    let session = providers
        .realtime
        .begin("en", MicProximity::NearField, CancellationToken::new())
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(30)).await;

    let error = session
        .send_audio(AudioChunk {
            samples: vec![1_000; 320],
            sample_rate: CAPTURE_SAMPLE_RATE,
        })
        .await
        .unwrap_err();

    assert_eq!(
        error,
        FreeFlowError::Api {
            status: 0,
            message: "scripted realtime failure".into()
        }
    );
}

#[tokio::test]
async fn cancellation_stops_batch_requests() {
    let (server, providers) = providers(Scenario::Delayed).await;
    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let error = providers
        .batch
        .transcribe(&audio(), "en", cancellation)
        .await
        .unwrap_err();
    assert_eq!(error, FreeFlowError::Cancelled);
    assert_eq!(server.metrics().await.batch_requests, 0);
}

#[tokio::test]
async fn live_realtime_transcribes_opt_in_pcm() {
    if std::env::var("FREEFLOW_TEST_OPENAI").as_deref() != Ok("1") {
        return;
    }
    let key = std::env::var("OPENAI_API_KEY").expect("OPENAI_API_KEY is required");
    let path = std::env::var("FREEFLOW_TEST_OPENAI_PCM")
        .expect("FREEFLOW_TEST_OPENAI_PCM must point to 16 kHz mono PCM16 audio");
    let bytes = std::fs::read(path).expect("test PCM should be readable");
    assert_eq!(bytes.len() % 2, 0, "PCM16 must have complete samples");
    let samples = bytes
        .chunks_exact(2)
        .map(|sample| i16::from_le_bytes([sample[0], sample[1]]))
        .collect::<Vec<_>>();
    let credentials = MemoryCredentials::with_api_key(&key).await;
    let providers = OpenAIProviders::new(AppSettings::default(), credentials);
    let session = providers
        .realtime
        .begin("en", MicProximity::NearField, CancellationToken::new())
        .await
        .expect("live realtime session should connect");
    for chunk in samples.chunks((CAPTURE_SAMPLE_RATE / 10) as usize) {
        session
            .send_audio(AudioChunk {
                samples: chunk.to_vec(),
                sample_rate: CAPTURE_SAMPLE_RATE,
            })
            .await
            .expect("live realtime audio should stream");
    }
    let transcript = session
        .finish()
        .await
        .expect("live realtime session should finalize");

    assert!(!transcript.trim().is_empty());
}
