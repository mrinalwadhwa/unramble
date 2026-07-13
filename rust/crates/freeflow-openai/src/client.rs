use std::{sync::Arc, time::Duration};

use freeflow_core::{AppSettings, CredentialStore, FreeFlowError, Result};
use reqwest::{Response, StatusCode};
use serde_json::Value;
use tokio::sync::RwLock;
use url::Url;

pub const OPENAI_API_KEY_CREDENTIAL: &str = "openai-api-key";
const MAX_ERROR_MESSAGE_CHARS: usize = 300;

#[derive(Clone)]
pub struct OpenAIClient {
    settings: Arc<RwLock<AppSettings>>,
    credentials: Arc<dyn CredentialStore>,
    http: reqwest::Client,
}

impl OpenAIClient {
    #[must_use]
    pub fn new(settings: AppSettings, credentials: Arc<dyn CredentialStore>) -> Self {
        Self {
            settings: Arc::new(RwLock::new(settings)),
            credentials,
            http: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(10))
                .build()
                .expect("reqwest client configuration is valid"),
        }
    }

    pub async fn update_settings(&self, settings: AppSettings) -> Result<()> {
        settings.validate()?;
        *self.settings.write().await = settings;
        Ok(())
    }

    pub(crate) async fn settings(&self) -> AppSettings {
        self.settings.read().await.clone()
    }

    pub(crate) async fn api_key(&self) -> Result<String> {
        self.credentials
            .read(OPENAI_API_KEY_CREDENTIAL)
            .await?
            .filter(|key| !key.trim().is_empty())
            .ok_or(FreeFlowError::MissingApiKey)
    }

    pub(crate) fn http(&self) -> &reqwest::Client {
        &self.http
    }

    pub(crate) fn endpoint(settings: &AppSettings, suffix: &str) -> Result<Url> {
        let base = settings.api_base_url.trim_end_matches('/');
        Url::parse(&format!("{base}/{}", suffix.trim_start_matches('/')))
            .map_err(|error| FreeFlowError::Configuration(format!("invalid API base URL: {error}")))
    }

    pub(crate) fn websocket_endpoint(settings: &AppSettings) -> Result<Url> {
        let mut url = Self::endpoint(settings, "realtime")?;
        let scheme = match url.scheme() {
            "https" => "wss",
            "http" => "ws",
            other => {
                return Err(FreeFlowError::Configuration(format!(
                    "unsupported API URL scheme: {other}"
                )));
            }
        };
        url.set_scheme(scheme).map_err(|()| {
            FreeFlowError::Configuration("could not construct the realtime URL".into())
        })?;
        url.query_pairs_mut()
            .append_pair("model", &settings.realtime_model);
        Ok(url)
    }

    pub(crate) async fn response_json(response: Response) -> Result<Value> {
        let status = response.status();
        if status.is_success() {
            return response
                .json::<Value>()
                .await
                .map_err(|error| FreeFlowError::InvalidResponse(error.to_string()));
        }

        let body = response.text().await.unwrap_or_default();
        Err(map_api_error(status, &body))
    }
}

pub(crate) fn map_api_error(status: StatusCode, body: &str) -> FreeFlowError {
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => FreeFlowError::AuthenticationFailed,
        StatusCode::TOO_MANY_REQUESTS => FreeFlowError::RateLimited,
        _ => {
            let parsed = serde_json::from_str::<Value>(body).ok();
            let message = parsed
                .as_ref()
                .and_then(|value| value.pointer("/error/message"))
                .and_then(Value::as_str)
                .unwrap_or("the service returned an error");
            let message: String = message.chars().take(MAX_ERROR_MESSAGE_CHARS).collect();
            FreeFlowError::Api {
                status: status.as_u16(),
                message,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_authentication_and_rate_limits_without_returning_bodies() {
        assert_eq!(
            map_api_error(StatusCode::UNAUTHORIZED, "secret"),
            FreeFlowError::AuthenticationFailed
        );
        assert_eq!(
            map_api_error(StatusCode::TOO_MANY_REQUESTS, "secret"),
            FreeFlowError::RateLimited
        );
    }

    #[test]
    fn extracts_a_bounded_service_message() {
        let body = serde_json::json!({"error": {"message": "invalid model"}}).to_string();
        assert_eq!(
            map_api_error(StatusCode::BAD_REQUEST, &body),
            FreeFlowError::Api {
                status: 400,
                message: "invalid model".into()
            }
        );
    }

    #[test]
    fn constructs_http_and_websocket_endpoints() {
        let settings = AppSettings {
            api_base_url: "http://127.0.0.1:8080/v1/".into(),
            realtime_model: "test model".into(),
            ..AppSettings::default()
        };
        assert_eq!(
            OpenAIClient::endpoint(&settings, "audio/transcriptions")
                .unwrap()
                .as_str(),
            "http://127.0.0.1:8080/v1/audio/transcriptions"
        );
        assert_eq!(
            OpenAIClient::websocket_endpoint(&settings)
                .unwrap()
                .as_str(),
            "ws://127.0.0.1:8080/v1/realtime?model=test+model"
        );
    }
}
