use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use freeflow_core::{
    AudioChunk, FreeFlowError, MicProximity, REALTIME_SAMPLE_RATE, Result,
    StreamingDictationProvider, StreamingSession,
    audio::{StreamingResampler, normalized_to_i16},
};
use futures_util::{SinkExt, StreamExt, stream::SplitSink};
use serde_json::{Value, json};
use tokio::{
    net::TcpStream,
    sync::{Mutex, broadcast, mpsc},
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{
        Message,
        client::IntoClientRequest,
        http::{HeaderValue, header::AUTHORIZATION},
    },
};
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use crate::{OpenAIClient, client::map_api_error};

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;
type SocketSink = SplitSink<Socket, Message>;

const MAX_CONNECT_ATTEMPTS: usize = 3;
const MAX_AUDIO_CHUNK_SAMPLES: usize = 96_000;

#[derive(Clone)]
pub struct OpenAIRealtimeProvider {
    client: OpenAIClient,
}

impl OpenAIRealtimeProvider {
    #[must_use]
    pub fn new(client: OpenAIClient) -> Self {
        Self { client }
    }

    async fn connect(
        &self,
        language: &str,
        cancellation: CancellationToken,
    ) -> Result<OpenAIRealtimeSession> {
        let settings = self.client.settings().await;
        let key = self.client.api_key().await?;
        let endpoint = OpenAIClient::websocket_endpoint(&settings)?;
        let mut last_error = None;

        for attempt in 0..MAX_CONNECT_ATTEMPTS {
            if cancellation.is_cancelled() {
                return Err(FreeFlowError::Cancelled);
            }
            let mut request = endpoint.as_str().into_client_request().map_err(|error| {
                FreeFlowError::Configuration(format!("invalid realtime URL: {error}"))
            })?;
            let authorization = HeaderValue::from_str(&format!("Bearer {key}"))
                .map_err(|_| FreeFlowError::Configuration("invalid API credential".into()))?;
            request.headers_mut().insert(AUTHORIZATION, authorization);

            let connection = tokio::select! {
                () = cancellation.cancelled() => return Err(FreeFlowError::Cancelled),
                result = connect_async(request) => result,
            };
            match connection {
                Ok((socket, _)) => {
                    debug!(attempt = attempt + 1, "realtime connection established");
                    return OpenAIRealtimeSession::initialize(
                        socket,
                        language,
                        &settings.realtime_model,
                        settings.request_timeout_seconds,
                        cancellation,
                    )
                    .await;
                }
                Err(error) => {
                    let mapped = map_websocket_error(error);
                    if matches!(
                        mapped,
                        FreeFlowError::AuthenticationFailed | FreeFlowError::RateLimited
                    ) {
                        return Err(mapped);
                    }
                    warn!(
                        attempt = attempt + 1,
                        category = mapped.category(),
                        "realtime connection failed"
                    );
                    last_error = Some(mapped);
                    if attempt + 1 < MAX_CONNECT_ATTEMPTS {
                        let delay = Duration::from_millis(200_u64 << attempt);
                        tokio::select! {
                            () = cancellation.cancelled() => return Err(FreeFlowError::Cancelled),
                            () = tokio::time::sleep(delay) => {}
                        }
                    }
                }
            }
        }
        Err(last_error.unwrap_or_else(|| {
            FreeFlowError::Network("realtime connection could not be established".into())
        }))
    }
}

#[async_trait]
impl StreamingDictationProvider for OpenAIRealtimeProvider {
    async fn begin(
        &self,
        language: &str,
        _proximity: MicProximity,
        cancellation: CancellationToken,
    ) -> Result<Arc<dyn StreamingSession>> {
        Ok(Arc::new(self.connect(language, cancellation).await?))
    }
}

pub struct OpenAIRealtimeSession {
    sink: Mutex<SocketSink>,
    resampler: Mutex<Option<(u32, StreamingResampler)>>,
    partial_sender: broadcast::Sender<String>,
    final_receiver: Mutex<mpsc::Receiver<Result<String>>>,
    terminal_error: Arc<Mutex<Option<FreeFlowError>>>,
    cancellation: CancellationToken,
    request_timeout: Duration,
}

impl OpenAIRealtimeSession {
    async fn initialize(
        socket: Socket,
        language: &str,
        model: &str,
        request_timeout_seconds: u64,
        cancellation: CancellationToken,
    ) -> Result<Self> {
        let (mut sink, mut source) = socket.split();
        let transcription = if language.trim().is_empty() || language == "auto" {
            json!({"model": model})
        } else {
            json!({"model": model, "language": language})
        };
        let update = json!({
            "type": "session.update",
            "session": {
                "type": "transcription",
                "audio": {
                    "input": {
                        "format": {"type": "audio/pcm", "rate": REALTIME_SAMPLE_RATE},
                        "transcription": transcription,
                        "turn_detection": null
                    }
                }
            }
        });
        sink.send(Message::Text(update.to_string().into()))
            .await
            .map_err(map_websocket_error)?;

        let (partial_sender, _) = broadcast::channel(64);
        let partials = partial_sender.clone();
        let (final_sender, final_receiver) = mpsc::channel(4);
        let terminal_error = Arc::new(Mutex::new(None));
        let reader_terminal_error = terminal_error.clone();
        let reader_cancellation = cancellation.clone();
        tokio::spawn(async move {
            loop {
                let message = tokio::select! {
                    () = reader_cancellation.cancelled() => {
                        report_terminal_error(
                            &reader_terminal_error,
                            &final_sender,
                            FreeFlowError::Cancelled,
                        ).await;
                        break;
                    }
                    message = source.next() => message,
                };
                let Some(message) = message else {
                    report_terminal_error(
                        &reader_terminal_error,
                        &final_sender,
                        FreeFlowError::Network(
                            "realtime connection closed before a final transcript".into(),
                        ),
                    )
                    .await;
                    break;
                };
                match message {
                    Ok(Message::Text(text)) => {
                        let Ok(event) = serde_json::from_str::<Value>(&text) else {
                            continue;
                        };
                        match event.get("type").and_then(Value::as_str) {
                            Some("conversation.item.input_audio_transcription.delta") => {
                                if let Some(delta) = event.get("delta").and_then(Value::as_str)
                                    && !delta.is_empty()
                                {
                                    let _ = partials.send(delta.to_owned());
                                }
                            }
                            Some("conversation.item.input_audio_transcription.completed") => {
                                if let Some(transcript) =
                                    event.get("transcript").and_then(Value::as_str)
                                {
                                    let transcript = transcript.trim();
                                    let result = if transcript.is_empty() {
                                        Err(FreeFlowError::SilentAudio)
                                    } else {
                                        Ok(transcript.to_owned())
                                    };
                                    let _ = final_sender.send(result).await;
                                }
                            }
                            Some("error") => {
                                let message = event
                                    .pointer("/error/message")
                                    .and_then(Value::as_str)
                                    .unwrap_or("the realtime service returned an error");
                                report_terminal_error(
                                    &reader_terminal_error,
                                    &final_sender,
                                    FreeFlowError::Api {
                                        status: 0,
                                        message: message.chars().take(300).collect(),
                                    },
                                )
                                .await;
                                break;
                            }
                            _ => {}
                        }
                    }
                    Ok(Message::Close(_)) => {
                        report_terminal_error(
                            &reader_terminal_error,
                            &final_sender,
                            FreeFlowError::Network(
                                "realtime connection closed before a final transcript".into(),
                            ),
                        )
                        .await;
                        break;
                    }
                    Ok(_) => {}
                    Err(error) => {
                        report_terminal_error(
                            &reader_terminal_error,
                            &final_sender,
                            map_websocket_error(error),
                        )
                        .await;
                        break;
                    }
                }
            }
        });

        Ok(Self {
            sink: Mutex::new(sink),
            resampler: Mutex::new(None),
            partial_sender,
            final_receiver: Mutex::new(final_receiver),
            terminal_error,
            cancellation,
            request_timeout: Duration::from_secs(request_timeout_seconds),
        })
    }

    async fn send_message(&self, message: Message) -> Result<()> {
        if let Some(error) = self.terminal_error.lock().await.clone() {
            return Err(error);
        }
        let result = self.sink.lock().await.send(message).await;
        match result {
            Ok(()) => Ok(()),
            Err(error) => {
                if let Some(terminal) = self.terminal_error.lock().await.clone() {
                    Err(terminal)
                } else {
                    Err(map_websocket_error(error))
                }
            }
        }
    }

    async fn send_pcm(&self, samples: &[i16]) -> Result<()> {
        if let Some(error) = self.terminal_error.lock().await.clone() {
            return Err(error);
        }
        if samples.is_empty() {
            return Ok(());
        }
        let mut bytes = Vec::with_capacity(samples.len() * 2);
        for sample in samples {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        let append = json!({
            "type": "input_audio_buffer.append",
            "audio": BASE64.encode(bytes)
        });
        self.send_message(Message::Text(append.to_string().into()))
            .await
    }
}

#[async_trait]
impl StreamingSession for OpenAIRealtimeSession {
    async fn send_audio(&self, audio: AudioChunk) -> Result<()> {
        if self.cancellation.is_cancelled() {
            return Err(FreeFlowError::Cancelled);
        }
        if audio.samples.len() > MAX_AUDIO_CHUNK_SAMPLES {
            return Err(FreeFlowError::Audio(
                "audio chunk exceeded the realtime limit".into(),
            ));
        }
        if audio.sample_rate == 0 {
            return Err(FreeFlowError::Audio(
                "audio chunk had an invalid sample rate".into(),
            ));
        }
        let normalized: Vec<f32> = audio
            .samples
            .iter()
            .map(|sample| f32::from(*sample) / 32_768.0)
            .collect();
        let output = {
            let mut state = self.resampler.lock().await;
            if state
                .as_ref()
                .is_some_and(|(rate, _)| *rate != audio.sample_rate)
            {
                return Err(FreeFlowError::Audio(
                    "audio sample rate changed during realtime transcription".into(),
                ));
            }
            let (_, resampler) = state.get_or_insert_with(|| {
                (
                    audio.sample_rate,
                    StreamingResampler::new(audio.sample_rate, REALTIME_SAMPLE_RATE),
                )
            });
            normalized_to_i16(&resampler.process(&normalized))
        };
        self.send_pcm(&output).await
    }

    async fn finish(&self) -> Result<String> {
        if self.cancellation.is_cancelled() {
            return Err(FreeFlowError::Cancelled);
        }
        let tail = {
            let mut state = self.resampler.lock().await;
            state.as_mut().map_or_else(Vec::new, |(_, resampler)| {
                normalized_to_i16(&resampler.finish())
            })
        };
        self.send_pcm(&tail).await?;
        self.send_message(Message::Text(
            json!({"type": "input_audio_buffer.commit"})
                .to_string()
                .into(),
        ))
        .await?;
        debug!("committed realtime audio buffer");

        let result = tokio::time::timeout(
            self.request_timeout,
            self.final_receiver.lock().await.recv(),
        )
        .await
        .map_err(|_| FreeFlowError::Timeout("realtime transcription".into()))?
        .ok_or_else(|| {
            FreeFlowError::Network("realtime transcript channel closed unexpectedly".into())
        })?;
        let _ = self.sink.lock().await.close().await;
        result
    }

    async fn cancel(&self) {
        self.cancellation.cancel();
        let _ = self.sink.lock().await.close().await;
    }

    fn partials(&self) -> broadcast::Receiver<String> {
        self.partial_sender.subscribe()
    }
}

async fn report_terminal_error(
    terminal_error: &Mutex<Option<FreeFlowError>>,
    final_sender: &mpsc::Sender<Result<String>>,
    error: FreeFlowError,
) {
    let mut terminal = terminal_error.lock().await;
    if terminal.is_some() {
        return;
    }
    *terminal = Some(error.clone());
    drop(terminal);
    let _ = final_sender.send(Err(error)).await;
}

fn map_websocket_error(error: tokio_tungstenite::tungstenite::Error) -> FreeFlowError {
    if let tokio_tungstenite::tungstenite::Error::Http(response) = &error {
        let body = response
            .body()
            .as_ref()
            .map_or("", |bytes| std::str::from_utf8(bytes).unwrap_or(""));
        return map_api_error(response.status(), body);
    }
    FreeFlowError::Network(error.to_string())
}
