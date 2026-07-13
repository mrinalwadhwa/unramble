use std::{
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

use async_trait::async_trait;
use axum::{
    Router,
    extract::{
        Query, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::Value;
use tokio::{net::TcpListener, sync::broadcast, task::JoinHandle};
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};
use uuid::Uuid;

use crate::{JsonRpcRequest, JsonRpcResponse, RpcError, RpcNotification};

#[async_trait]
pub trait RpcHandler: Send + Sync + 'static {
    async fn handle(&self, method: &str, params: Value) -> Result<Value, RpcError>;
    fn notifications(&self) -> broadcast::Receiver<RpcNotification>;
}

#[derive(Clone)]
struct ServerState {
    handler: Arc<dyn RpcHandler>,
    token: Arc<str>,
    connected: Arc<AtomicBool>,
}

#[derive(Debug, Deserialize)]
struct Authentication {
    token: String,
}

pub struct RpcServer;

pub struct RpcServerHandle {
    pub address: SocketAddr,
    pub token: String,
    shutdown: CancellationToken,
    task: JoinHandle<()>,
}

impl RpcServer {
    pub async fn start(handler: Arc<dyn RpcHandler>) -> std::io::Result<RpcServerHandle> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let address = listener.local_addr()?;
        let token = Uuid::new_v4().simple().to_string();
        let state = ServerState {
            handler,
            token: Arc::from(token.clone()),
            connected: Arc::new(AtomicBool::new(false)),
        };
        let router = Router::new().route("/rpc", get(upgrade)).with_state(state);
        let shutdown = CancellationToken::new();
        let shutdown_signal = shutdown.clone();
        let task = tokio::spawn(async move {
            if let Err(error) = axum::serve(listener, router)
                .with_graceful_shutdown(shutdown_signal.cancelled_owned())
                .await
            {
                warn!(%error, "RPC server stopped unexpectedly");
            }
        });
        Ok(RpcServerHandle {
            address,
            token,
            shutdown,
            task,
        })
    }
}

impl RpcServerHandle {
    #[must_use]
    pub fn websocket_url(&self) -> String {
        format!("ws://{}/rpc?token={}", self.address, self.token)
    }

    pub async fn shutdown(self) {
        self.shutdown.cancel();
        let _ = self.task.await;
    }
}

async fn upgrade(
    State(state): State<ServerState>,
    Query(authentication): Query<Authentication>,
    websocket: WebSocketUpgrade,
) -> Response {
    if authentication.token.as_bytes() != state.token.as_bytes() {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if state.connected.swap(true, Ordering::SeqCst) {
        return StatusCode::CONFLICT.into_response();
    }
    websocket
        .on_upgrade(move |socket| serve_connection(socket, state))
        .into_response()
}

async fn serve_connection(socket: WebSocket, state: ServerState) {
    debug!("desktop RPC client connected");
    let (mut sender, mut receiver) = socket.split();
    let mut notifications = state.handler.notifications();
    loop {
        tokio::select! {
            message = receiver.next() => {
                let Some(message) = message else { break };
                match message {
                    Ok(Message::Text(text)) => {
                        let response = process_request(&*state.handler, &text).await;
                        if let Some(response) = response {
                            let Ok(json) = serde_json::to_string(&response) else {
                                break;
                            };
                            if sender.send(Message::Text(json.into())).await.is_err() {
                                break;
                            }
                        }
                    }
                    Ok(Message::Close(_)) | Err(_) => break,
                    Ok(_) => {}
                }
            }
            notification = notifications.recv() => match notification {
                Ok(notification) => {
                    let Ok(json) = serde_json::to_string(&notification) else {
                        break;
                    };
                    if sender.send(Message::Text(json.into())).await.is_err() {
                        break;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(count)) => {
                    warn!(dropped_notifications = count, "desktop RPC client lagged");
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    }
    state.connected.store(false, Ordering::SeqCst);
    debug!("desktop RPC client disconnected");
}

async fn process_request(handler: &dyn RpcHandler, text: &str) -> Option<JsonRpcResponse> {
    let request = match serde_json::from_str::<JsonRpcRequest>(text) {
        Ok(request) => request,
        Err(error) => {
            return Some(JsonRpcResponse::failure(
                Value::Null,
                RpcError::parse(format!("invalid JSON: {error}")),
            ));
        }
    };
    let id = request.id.clone();
    if request.jsonrpc != "2.0" || request.method.trim().is_empty() {
        return id.map(|id| {
            JsonRpcResponse::failure(id, RpcError::invalid_request("invalid JSON-RPC request"))
        });
    }
    let Some(id) = id else {
        let _ = handler.handle(&request.method, request.params).await;
        return None;
    };
    match handler.handle(&request.method, request.params).await {
        Ok(result) => Some(JsonRpcResponse::success(id, result)),
        Err(error) => Some(JsonRpcResponse::failure(id, error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{SinkExt, StreamExt};
    use serde_json::json;
    use tokio_tungstenite::{connect_async, tungstenite::Message as ClientMessage};

    struct TestHandler {
        notifications: broadcast::Sender<RpcNotification>,
    }

    #[async_trait]
    impl RpcHandler for TestHandler {
        async fn handle(&self, method: &str, params: Value) -> Result<Value, RpcError> {
            match method {
                "echo" => Ok(params),
                _ => Err(RpcError::method_not_found(method)),
            }
        }

        fn notifications(&self) -> broadcast::Receiver<RpcNotification> {
            self.notifications.subscribe()
        }
    }

    fn handler() -> Arc<TestHandler> {
        let (notifications, _) = broadcast::channel(8);
        Arc::new(TestHandler { notifications })
    }

    #[tokio::test]
    async fn rejects_an_invalid_session_token() {
        let server = RpcServer::start(handler()).await.unwrap();
        let url = format!("ws://{}/rpc?token=wrong", server.address);
        let error = connect_async(url).await.unwrap_err();
        let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
            panic!("expected an HTTP handshake error");
        };
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        server.shutdown().await;
    }

    #[tokio::test]
    async fn serves_requests_errors_and_notifications() {
        let handler = handler();
        let server = RpcServer::start(handler.clone()).await.unwrap();
        let (mut socket, _) = connect_async(server.websocket_url()).await.unwrap();
        socket
            .send(ClientMessage::Text(
                json!({"jsonrpc":"2.0","id":1,"method":"echo","params":{"ok":true}})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        let response = socket.next().await.unwrap().unwrap().into_text().unwrap();
        let response: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(response.get("result"), Some(&json!({"ok": true})));

        socket
            .send(ClientMessage::Text(
                json!({"jsonrpc":"2.0","id":2,"method":"missing"})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        let response = socket.next().await.unwrap().unwrap().into_text().unwrap();
        let response: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(response.pointer("/error/code"), Some(&json!(-32601)));

        handler
            .notifications
            .send(RpcNotification::new(
                "status.changed",
                json!({"state":"idle"}),
            ))
            .unwrap();
        let notification = socket.next().await.unwrap().unwrap().into_text().unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&notification).unwrap()["method"],
            "status.changed"
        );
        socket.close(None).await.unwrap();
        server.shutdown().await;
    }

    #[tokio::test]
    async fn admits_only_one_desktop_connection() {
        let server = RpcServer::start(handler()).await.unwrap();
        let (first, _) = connect_async(server.websocket_url()).await.unwrap();
        let error = connect_async(server.websocket_url()).await.unwrap_err();
        let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
            panic!("expected an HTTP handshake error");
        };
        assert_eq!(response.status(), StatusCode::CONFLICT);
        drop(first);
        server.shutdown().await;
    }
}
