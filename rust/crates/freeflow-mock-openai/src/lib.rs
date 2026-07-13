//! Serve deterministic OpenAI-compatible responses without paid API calls.

use std::{net::SocketAddr, str::FromStr, sync::Arc, time::Duration};

use axum::{
    Json, Router,
    extract::{
        Multipart, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    net::TcpListener,
    sync::{Mutex, oneshot},
};

pub const TEST_API_KEY: &str = "freeflow-test-key";
pub const TEST_TRANSCRIPT: &str = "FreeFlow deterministic transcript.";
pub const TEST_POLISHED_TRANSCRIPT: &str = "FreeFlow deterministic transcript.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Scenario {
    #[default]
    Success,
    RealtimeDisconnect,
    RealtimeError,
    BatchFallback,
    AuthenticationFailure,
    RateLimit,
    Delayed,
    Malformed,
    PolishFailure,
}

impl FromStr for Scenario {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "success" => Ok(Self::Success),
            "realtime-disconnect" => Ok(Self::RealtimeDisconnect),
            "realtime-error" => Ok(Self::RealtimeError),
            "batch-fallback" => Ok(Self::BatchFallback),
            "authentication-failure" => Ok(Self::AuthenticationFailure),
            "rate-limit" => Ok(Self::RateLimit),
            "delayed" => Ok(Self::Delayed),
            "malformed" => Ok(Self::Malformed),
            "polish-failure" => Ok(Self::PolishFailure),
            _ => Err(format!("unknown mock scenario: {value}")),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestMetrics {
    pub batch_requests: usize,
    pub polish_requests: usize,
    pub realtime_connections: usize,
    pub realtime_audio_bytes: usize,
    pub realtime_model: Option<String>,
}

#[derive(Clone)]
struct MockState {
    scenario: Scenario,
    metrics: Arc<Mutex<RequestMetrics>>,
}

pub struct MockServer {
    pub address: SocketAddr,
    pub api_base_url: String,
    metrics: Arc<Mutex<RequestMetrics>>,
    shutdown: Option<oneshot::Sender<()>>,
}

impl MockServer {
    pub async fn start(scenario: Scenario) -> std::io::Result<Self> {
        Self::bind(([127, 0, 0, 1], 0).into(), scenario).await
    }

    pub async fn bind(address: SocketAddr, scenario: Scenario) -> std::io::Result<Self> {
        let listener = TcpListener::bind(address).await?;
        let address = listener.local_addr()?;
        let metrics = Arc::new(Mutex::new(RequestMetrics::default()));
        let state = MockState {
            scenario,
            metrics: metrics.clone(),
        };
        let app = Router::new()
            .route("/v1/audio/transcriptions", post(transcribe))
            .route("/v1/chat/completions", post(polish))
            .route("/v1/realtime", get(realtime))
            .with_state(state);
        let (shutdown_sender, shutdown_receiver) = oneshot::channel();
        tokio::spawn(async move {
            let _ = axum::serve(listener, app)
                .with_graceful_shutdown(async {
                    let _ = shutdown_receiver.await;
                })
                .await;
        });
        Ok(Self {
            address,
            api_base_url: format!("http://{address}/v1"),
            metrics,
            shutdown: Some(shutdown_sender),
        })
    }

    pub async fn metrics(&self) -> RequestMetrics {
        self.metrics.lock().await.clone()
    }
}

impl Drop for MockServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

async fn transcribe(
    State(state): State<MockState>,
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Response {
    if let Some(response) = gate_request(&state, &headers).await {
        return response;
    }
    state.metrics.lock().await.batch_requests += 1;
    let mut found_audio = false;
    while let Ok(Some(field)) = multipart.next_field().await {
        if field.name() == Some("file") {
            found_audio = field
                .bytes()
                .await
                .is_ok_and(|bytes| bytes.starts_with(b"RIFF"));
        }
    }
    if !found_audio {
        return api_error(StatusCode::BAD_REQUEST, "missing WAV audio");
    }
    if state.scenario == Scenario::Malformed {
        return (StatusCode::OK, "not-json").into_response();
    }
    Json(json!({"text": TEST_TRANSCRIPT})).into_response()
}

async fn polish(
    State(state): State<MockState>,
    headers: HeaderMap,
    Json(_body): Json<Value>,
) -> Response {
    if let Some(response) = gate_request(&state, &headers).await {
        return response;
    }
    state.metrics.lock().await.polish_requests += 1;
    if state.scenario == Scenario::PolishFailure {
        return api_error(StatusCode::INTERNAL_SERVER_ERROR, "scripted polish failure");
    }
    if state.scenario == Scenario::Malformed {
        return Json(json!({"choices": []})).into_response();
    }
    Json(json!({
        "choices": [{"message": {"content": TEST_POLISHED_TRANSCRIPT}}]
    }))
    .into_response()
}

async fn realtime(
    State(state): State<MockState>,
    headers: HeaderMap,
    websocket: WebSocketUpgrade,
) -> Response {
    if let Some(response) = gate_request(&state, &headers).await {
        return response;
    }
    state.metrics.lock().await.realtime_connections += 1;
    websocket
        .on_upgrade(move |socket| realtime_session(socket, state))
        .into_response()
}

async fn realtime_session(socket: WebSocket, state: MockState) {
    let (mut sender, mut receiver) = socket.split();
    if matches!(
        state.scenario,
        Scenario::RealtimeDisconnect | Scenario::BatchFallback
    ) {
        let _ = sender.send(Message::Close(None)).await;
        return;
    }
    while let Some(Ok(message)) = receiver.next().await {
        let Message::Text(text) = message else {
            continue;
        };
        let Ok(event) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        match event.get("type").and_then(Value::as_str) {
            Some("session.update") => {
                let model = event
                    .pointer("/session/audio/input/transcription/model")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
                state.metrics.lock().await.realtime_model = model;
                if state.scenario == Scenario::RealtimeError {
                    let _ = sender
                        .send(Message::Text(
                            json!({
                                "type": "error",
                                "error": {"message": "scripted realtime failure"}
                            })
                            .to_string()
                            .into(),
                        ))
                        .await;
                    let _ = sender.send(Message::Close(None)).await;
                    return;
                }
                let _ = sender
                    .send(Message::Text(
                        json!({"type": "session.updated"}).to_string().into(),
                    ))
                    .await;
            }
            Some("input_audio_buffer.append") => {
                if let Some(audio) = event.get("audio").and_then(Value::as_str) {
                    use base64::Engine;
                    if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(audio) {
                        state.metrics.lock().await.realtime_audio_bytes += bytes.len();
                    }
                }
            }
            Some("input_audio_buffer.commit") => {
                if state.scenario == Scenario::Delayed {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
                if state.scenario == Scenario::Malformed {
                    let _ = sender.send(Message::Text("not-json".into())).await;
                    continue;
                }
                let _ = sender
                    .send(Message::Text(
                        json!({
                            "type": "conversation.item.input_audio_transcription.delta",
                            "delta": "FreeFlow deterministic "
                        })
                        .to_string()
                        .into(),
                    ))
                    .await;
                let _ = sender
                    .send(Message::Text(
                        json!({
                            "type": "conversation.item.input_audio_transcription.completed",
                            "transcript": TEST_TRANSCRIPT
                        })
                        .to_string()
                        .into(),
                    ))
                    .await;
            }
            _ => {}
        }
    }
}

async fn gate_request(state: &MockState, headers: &HeaderMap) -> Option<Response> {
    if state.scenario == Scenario::Delayed {
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    if state.scenario == Scenario::AuthenticationFailure
        || headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            != Some(&format!("Bearer {TEST_API_KEY}"))
    {
        return Some(api_error(StatusCode::UNAUTHORIZED, "invalid API key"));
    }
    if state.scenario == Scenario::RateLimit {
        return Some(api_error(StatusCode::TOO_MANY_REQUESTS, "rate limit"));
    }
    None
}

fn api_error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({"error": {"message": message}}))).into_response()
}
