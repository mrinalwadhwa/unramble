use std::sync::Arc;

use async_trait::async_trait;
use freeflow_core::{CredentialStore, Result};
use freeflow_openai::OPENAI_API_KEY_CREDENTIAL;
use freeflow_platform_linux::SecretServiceCredentialStore;
use tokio::sync::RwLock;

pub struct DaemonCredentialStore {
    persistent: Arc<SecretServiceCredentialStore>,
    session_api_key: RwLock<Option<String>>,
}

impl DaemonCredentialStore {
    pub fn new(persistent: Arc<SecretServiceCredentialStore>) -> Self {
        Self {
            persistent,
            session_api_key: RwLock::new(None),
        }
    }

    pub async fn set_session_api_key(&self, value: Option<String>) {
        *self.session_api_key.write().await = value;
    }

    pub async fn persist_api_key(&self, value: &str) -> Result<()> {
        self.persistent
            .write(OPENAI_API_KEY_CREDENTIAL, value)
            .await?;
        self.set_session_api_key(None).await;
        Ok(())
    }
}

#[async_trait]
impl CredentialStore for DaemonCredentialStore {
    async fn read(&self, key: &str) -> Result<Option<String>> {
        if key == OPENAI_API_KEY_CREDENTIAL
            && let Some(value) = self.session_api_key.read().await.clone()
        {
            return Ok(Some(value));
        }
        self.persistent.read(key).await
    }

    async fn write(&self, key: &str, value: &str) -> Result<()> {
        self.persistent.write(key, value).await
    }

    async fn delete(&self, key: &str) -> Result<()> {
        if key == OPENAI_API_KEY_CREDENTIAL {
            self.set_session_api_key(None).await;
        }
        self.persistent.delete(key).await
    }

    async fn is_available(&self) -> bool {
        self.persistent.is_available().await
    }
}
