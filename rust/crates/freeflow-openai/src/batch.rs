use async_trait::async_trait;
use freeflow_core::{AudioBuffer, DictationProvider, FreeFlowError, Result, audio::encode_wav};
use reqwest::multipart::{Form, Part};
use tokio_util::sync::CancellationToken;
use tracing::debug;

use crate::OpenAIClient;

#[derive(Clone)]
pub struct OpenAIBatchProvider {
    client: OpenAIClient,
}

impl OpenAIBatchProvider {
    #[must_use]
    pub fn new(client: OpenAIClient) -> Self {
        Self { client }
    }
}

#[async_trait]
impl DictationProvider for OpenAIBatchProvider {
    async fn transcribe(
        &self,
        audio: &AudioBuffer,
        language: &str,
        cancellation: CancellationToken,
    ) -> Result<String> {
        if cancellation.is_cancelled() {
            return Err(FreeFlowError::Cancelled);
        }
        let settings = self.client.settings().await;
        let key = self.client.api_key().await?;
        let endpoint = OpenAIClient::endpoint(&settings, "audio/transcriptions")?;
        let wav = encode_wav(&audio.samples, audio.sample_rate, audio.channels);
        let audio_part = Part::bytes(wav)
            .file_name("recording.wav")
            .mime_str("audio/wav")
            .map_err(|error| FreeFlowError::Internal(error.to_string()))?;
        let mut form = Form::new()
            .part("file", audio_part)
            .text("model", settings.transcription_model)
            .text("response_format", "json");
        if !language.trim().is_empty() && language != "auto" {
            form = form.text("language", language.to_owned());
        }

        debug!(
            duration_ms = (audio.duration_seconds() * 1_000.0).round() as u64,
            sample_rate = audio.sample_rate,
            "sending batch transcription"
        );
        let request = self
            .client
            .http()
            .post(endpoint)
            .bearer_auth(key)
            .timeout(std::time::Duration::from_secs(
                settings.request_timeout_seconds,
            ))
            .multipart(form)
            .send();
        let response = tokio::select! {
            () = cancellation.cancelled() => return Err(FreeFlowError::Cancelled),
            response = request => response.map_err(|error| {
                if error.is_timeout() {
                    FreeFlowError::Timeout("batch transcription".into())
                } else {
                    FreeFlowError::Network(error.to_string())
                }
            })?,
        };
        let json = OpenAIClient::response_json(response).await?;
        let text = json
            .get("text")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .ok_or_else(|| {
                FreeFlowError::InvalidResponse("transcription response did not contain text".into())
            })?;
        debug!(
            characters = text.chars().count(),
            "batch transcription completed"
        );
        Ok(text.to_owned())
    }
}
