use async_trait::async_trait;
use freeflow_core::{
    AppContext, FreeFlowError, PolishMode, PolishProvider, Result,
    polish::{build_user_prompt, system_prompt},
};
use serde_json::json;
use tokio_util::sync::CancellationToken;
use tracing::debug;

use crate::OpenAIClient;

#[derive(Clone)]
pub struct OpenAIPolishProvider {
    client: OpenAIClient,
}

impl OpenAIPolishProvider {
    #[must_use]
    pub fn new(client: OpenAIClient) -> Self {
        Self { client }
    }
}

#[async_trait]
impl PolishProvider for OpenAIPolishProvider {
    async fn polish(
        &self,
        transcript: &str,
        context: &AppContext,
        language: &str,
        mode: PolishMode,
        cancellation: CancellationToken,
    ) -> Result<String> {
        if cancellation.is_cancelled() {
            return Err(FreeFlowError::Cancelled);
        }
        let settings = self.client.settings().await;
        let key = self.client.api_key().await?;
        let endpoint = OpenAIClient::endpoint(&settings, "chat/completions")?;
        let body = json!({
            "model": settings.polish_model,
            "messages": [
                {"role": "system", "content": system_prompt(language, mode)},
                {"role": "user", "content": build_user_prompt(transcript, context, language)}
            ]
        });

        debug!(
            characters = transcript.chars().count(),
            "sending transcript polish request"
        );
        let request = self
            .client
            .http()
            .post(endpoint)
            .bearer_auth(key)
            .timeout(std::time::Duration::from_secs(
                settings.request_timeout_seconds,
            ))
            .json(&body)
            .send();
        let response = tokio::select! {
            () = cancellation.cancelled() => return Err(FreeFlowError::Cancelled),
            response = request => response.map_err(|error| {
                if error.is_timeout() {
                    FreeFlowError::Timeout("transcript polish".into())
                } else {
                    FreeFlowError::Network(error.to_string())
                }
            })?,
        };
        let json = OpenAIClient::response_json(response).await?;
        let text = json
            .pointer("/choices/0/message/content")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .ok_or_else(|| {
                FreeFlowError::InvalidResponse("polish response did not contain text".into())
            })?;
        debug!(
            characters = text.chars().count(),
            "transcript polish completed"
        );
        Ok(text.to_owned())
    }
}
