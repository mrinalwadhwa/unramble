mod app;
mod credentials;

use std::sync::Arc;

use app::DaemonApp;
use freeflow_core::{AudioProvider, DictationProvider, SettingsStore};
use freeflow_openai::OpenAIProviders;
use freeflow_platform::JsonSettingsStore;
use freeflow_platform_linux::{LinuxAudioProvider, SecretServiceCredentialStore};
use freeflow_rpc::{PROTOCOL_VERSION, RpcServer, generate_typescript_contract};
use tokio_util::sync::CancellationToken;
use tracing::{error, info};
use tracing_subscriber::EnvFilter;

use crate::credentials::DaemonCredentialStore;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        error!(category = error.category(), %error, "daemon stopped with an error");
        eprintln!("FreeFlow daemon: {error}");
        std::process::exit(1);
    }
}

async fn run() -> freeflow_core::Result<()> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("freeflow=info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        Some("export-types") => {
            print!("{}", generate_typescript_contract());
            return Ok(());
        }
        Some("record") => return record_once().await,
        Some("serve") | None => {}
        Some("--help" | "-h") => {
            println!(
                "Usage: freeflow-daemon [serve|record|export-types]\n\n\
                 serve         Start the authenticated desktop RPC service\n\
                 record        Record until Enter and print a batch transcript\n\
                 export-types  Print the generated TypeScript RPC contract"
            );
            return Ok(());
        }
        Some(other) => {
            return Err(freeflow_core::FreeFlowError::Configuration(format!(
                "unknown daemon command: {other}"
            )));
        }
    }

    let settings_store = Arc::new(JsonSettingsStore::for_current_user()?);
    let settings = settings_store.load().await?;
    let persistent_credentials = Arc::new(SecretServiceCredentialStore::new());
    let credentials = Arc::new(DaemonCredentialStore::new(persistent_credentials));
    if let Ok(key) = std::env::var("OPENAI_API_KEY")
        && !key.trim().is_empty()
    {
        credentials.set_session_api_key(Some(key)).await;
    }
    let shutdown = CancellationToken::new();
    let app =
        Arc::new(DaemonApp::new(settings_store, settings, credentials, shutdown.clone()).await?);
    app.start_background_services().await;
    let rpc = RpcServer::start(app.clone()).await.map_err(|error| {
        freeflow_core::FreeFlowError::Internal(format!("could not bind RPC server: {error}"))
    })?;
    println!(
        "{}",
        serde_json::json!({
            "ready": true,
            "rpcPort": rpc.address.port(),
            "sessionToken": rpc.token,
            "protocolVersion": PROTOCOL_VERSION,
            "pid": std::process::id()
        })
    );
    info!(
        version = env!("CARGO_PKG_VERSION"),
        protocol_version = PROTOCOL_VERSION,
        "FreeFlow daemon ready"
    );

    tokio::select! {
        () = shutdown.cancelled() => {}
        result = tokio::signal::ctrl_c() => {
            if let Err(error) = result {
                error!(%error, "could not listen for shutdown signal");
            }
        }
        () = terminate_signal() => {}
    }
    app.shutdown().await;
    rpc.shutdown().await;
    info!("FreeFlow daemon stopped cleanly");
    Ok(())
}

#[cfg(unix)]
async fn terminate_signal() {
    use tokio::signal::unix::{SignalKind, signal};

    if let Ok(mut signal) = signal(SignalKind::terminate()) {
        signal.recv().await;
    } else {
        std::future::pending::<()>().await;
    }
}

#[cfg(not(unix))]
async fn terminate_signal() {
    std::future::pending::<()>().await;
}

async fn record_once() -> freeflow_core::Result<()> {
    let api_key =
        std::env::var("OPENAI_API_KEY").map_err(|_| freeflow_core::FreeFlowError::MissingApiKey)?;
    let settings_store = JsonSettingsStore::for_current_user()?;
    let settings = settings_store.load().await?;
    let persistent = Arc::new(SecretServiceCredentialStore::new());
    let credentials = Arc::new(DaemonCredentialStore::new(persistent));
    credentials.set_session_api_key(Some(api_key)).await;
    let providers = OpenAIProviders::new(settings.clone(), credentials);
    let audio = LinuxAudioProvider::new();
    if let Some(device) = settings.selected_audio_device.as_deref()
        && let Err(error) = audio.select_device(Some(device)).await
    {
        tracing::warn!(
            category = error.category(),
            "selected microphone is unavailable"
        );
    }
    let capture = audio.start().await?;
    eprintln!(
        "Recording from {} ({}). Press Enter to stop.",
        capture.device.name, capture.device.backend
    );
    tokio::task::spawn_blocking(|| {
        let mut line = String::new();
        std::io::stdin().read_line(&mut line)
    })
    .await
    .map_err(|error| freeflow_core::FreeFlowError::Internal(error.to_string()))?
    .map_err(|error| freeflow_core::FreeFlowError::Audio(error.to_string()))?;
    let buffer = audio.stop().await?;
    let transcript = providers
        .batch
        .transcribe(&buffer, &settings.language, CancellationToken::new())
        .await?;
    println!("{transcript}");
    Ok(())
}
