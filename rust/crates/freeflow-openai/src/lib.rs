//! OpenAI-compatible cloud providers for FreeFlow.

mod batch;
mod client;
mod polish;
mod realtime;

pub use batch::OpenAIBatchProvider;
pub use client::{OPENAI_API_KEY_CREDENTIAL, OpenAIClient};
pub use polish::OpenAIPolishProvider;
pub use realtime::OpenAIRealtimeProvider;

use std::sync::Arc;

use freeflow_core::{AppSettings, CredentialStore};

/// Construct the cloud providers around shared settings and credentials.
#[derive(Clone)]
pub struct OpenAIProviders {
    pub batch: Arc<OpenAIBatchProvider>,
    pub realtime: Arc<OpenAIRealtimeProvider>,
    pub polish: Arc<OpenAIPolishProvider>,
    client: OpenAIClient,
}

impl OpenAIProviders {
    #[must_use]
    pub fn new(settings: AppSettings, credentials: Arc<dyn CredentialStore>) -> Self {
        let client = OpenAIClient::new(settings, credentials);
        Self {
            batch: Arc::new(OpenAIBatchProvider::new(client.clone())),
            realtime: Arc::new(OpenAIRealtimeProvider::new(client.clone())),
            polish: Arc::new(OpenAIPolishProvider::new(client.clone())),
            client,
        }
    }

    pub async fn update_settings(&self, settings: AppSettings) -> freeflow_core::Result<()> {
        self.client.update_settings(settings).await
    }
}
