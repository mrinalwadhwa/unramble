use async_trait::async_trait;
use freeflow_core::{CredentialStore, FreeFlowError, Result};

const SERVICE_NAME: &str = "com.freeflow.FreeFlow";

#[derive(Debug, Clone, Default)]
pub struct SecretServiceCredentialStore;

impl SecretServiceCredentialStore {
    #[must_use]
    pub fn new() -> Self {
        Self
    }

    fn entry(key: &str) -> Result<keyring::Entry> {
        keyring::Entry::new(SERVICE_NAME, key).map_err(|error| {
            FreeFlowError::CredentialUnavailable(format!(
                "Secret Service could not create an entry: {error}"
            ))
        })
    }
}

#[async_trait]
impl CredentialStore for SecretServiceCredentialStore {
    async fn read(&self, key: &str) -> Result<Option<String>> {
        let key = key.to_owned();
        tokio::task::spawn_blocking(move || {
            let entry = Self::entry(&key)?;
            match entry.get_password() {
                Ok(value) => Ok(Some(value)),
                Err(keyring::Error::NoEntry) => Ok(None),
                Err(error) => Err(FreeFlowError::CredentialUnavailable(format!(
                    "Secret Service could not read the credential: {error}"
                ))),
            }
        })
        .await
        .map_err(|error| FreeFlowError::Internal(error.to_string()))?
    }

    async fn write(&self, key: &str, value: &str) -> Result<()> {
        let key = key.to_owned();
        let value = value.to_owned();
        tokio::task::spawn_blocking(move || {
            Self::entry(&key)?.set_password(&value).map_err(|error| {
                FreeFlowError::CredentialUnavailable(format!(
                    "Secret Service could not save the credential: {error}"
                ))
            })
        })
        .await
        .map_err(|error| FreeFlowError::Internal(error.to_string()))?
    }

    async fn delete(&self, key: &str) -> Result<()> {
        let key = key.to_owned();
        tokio::task::spawn_blocking(move || {
            let entry = Self::entry(&key)?;
            match entry.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
                Err(error) => Err(FreeFlowError::CredentialUnavailable(format!(
                    "Secret Service could not delete the credential: {error}"
                ))),
            }
        })
        .await
        .map_err(|error| FreeFlowError::Internal(error.to_string()))?
    }

    async fn is_available(&self) -> bool {
        let result = tokio::task::spawn_blocking(|| {
            let entry = Self::entry("availability-probe")?;
            match entry.get_password() {
                Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
                Err(error) => Err(FreeFlowError::CredentialUnavailable(error.to_string())),
            }
        })
        .await;
        matches!(result, Ok(Ok(())))
    }
}
