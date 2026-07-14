//! Persist ordinary FreeFlow configuration without platform APIs.

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use directories::ProjectDirs;
use freeflow_core::{AppSettings, FreeFlowError, Result, SettingsStore};

#[derive(Debug, Clone)]
pub struct JsonSettingsStore {
    path: PathBuf,
}

impl JsonSettingsStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn for_current_user() -> Result<Self> {
        let directories = ProjectDirs::from("", "", "freeflow").ok_or_else(|| {
            FreeFlowError::Configuration("the user configuration directory is unavailable".into())
        })?;
        Ok(Self::new(directories.config_dir().join("config.json")))
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    fn load_sync(path: &Path) -> Result<AppSettings> {
        match std::fs::read(path) {
            Ok(contents) => {
                let settings: AppSettings = serde_json::from_slice(&contents).map_err(|error| {
                    FreeFlowError::Configuration(format!("could not parse settings: {error}"))
                })?;
                settings.validate()?;
                Ok(settings)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok(AppSettings::default())
            }
            Err(error) => Err(FreeFlowError::Configuration(format!(
                "could not read settings: {error}"
            ))),
        }
    }

    fn save_sync(path: &Path, settings: &AppSettings) -> Result<()> {
        settings.validate()?;
        let parent = path.parent().ok_or_else(|| {
            FreeFlowError::Configuration("settings path has no parent directory".into())
        })?;
        std::fs::create_dir_all(parent).map_err(|error| {
            FreeFlowError::Configuration(format!("could not create settings directory: {error}"))
        })?;
        set_directory_permissions(parent)?;
        let temporary = path.with_extension("json.tmp");
        let contents = serde_json::to_vec_pretty(settings)
            .map_err(|error| FreeFlowError::Internal(error.to_string()))?;
        write_private_file(&temporary, &contents)?;
        std::fs::rename(&temporary, path).map_err(|error| {
            FreeFlowError::Configuration(format!("could not replace settings: {error}"))
        })?;
        Ok(())
    }
}

#[async_trait]
impl SettingsStore for JsonSettingsStore {
    async fn load(&self) -> Result<AppSettings> {
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || Self::load_sync(&path))
            .await
            .map_err(|error| FreeFlowError::Internal(error.to_string()))?
    }

    async fn save(&self, settings: &AppSettings) -> Result<()> {
        let path = self.path.clone();
        let settings = settings.clone();
        tokio::task::spawn_blocking(move || Self::save_sync(&path, &settings))
            .await
            .map_err(|error| FreeFlowError::Internal(error.to_string()))?
    }

    async fn reset(&self) -> Result<AppSettings> {
        let settings = AppSettings::default();
        self.save(&settings).await?;
        Ok(settings)
    }
}

#[cfg(unix)]
fn set_directory_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).map_err(|error| {
        FreeFlowError::Configuration(format!("could not secure settings directory: {error}"))
    })
}

#[cfg(not(unix))]
fn set_directory_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn write_private_file(path: &Path, contents: &[u8]) -> Result<()> {
    use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt};

    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| {
            FreeFlowError::Configuration(format!("could not open settings: {error}"))
        })?;
    file.write_all(contents).map_err(|error| {
        FreeFlowError::Configuration(format!("could not write settings: {error}"))
    })?;
    file.sync_all()
        .map_err(|error| FreeFlowError::Configuration(format!("could not flush settings: {error}")))
}

#[cfg(not(unix))]
fn write_private_file(path: &Path, contents: &[u8]) -> Result<()> {
    std::fs::write(path, contents)
        .map_err(|error| FreeFlowError::Configuration(format!("could not write settings: {error}")))
}

#[cfg(test)]
mod tests {
    use std::{
        sync::atomic::{AtomicUsize, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    use super::*;

    static NEXT_DIRECTORY: AtomicUsize = AtomicUsize::new(0);

    fn temporary_store() -> JsonSettingsStore {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        JsonSettingsStore::new(std::env::temp_dir().join(format!(
            "freeflow-settings-{}-{suffix}-{}/config.json",
            std::process::id(),
            NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed)
        )))
    }

    #[tokio::test]
    async fn missing_file_returns_defaults() {
        let store = temporary_store();
        assert_eq!(store.load().await.unwrap(), AppSettings::default());
    }

    #[tokio::test]
    async fn round_trips_settings_without_credentials() {
        let store = temporary_store();
        let settings = AppSettings {
            language: "es".into(),
            polish_enabled: false,
            ..AppSettings::default()
        };
        store.save(&settings).await.unwrap();
        assert_eq!(store.load().await.unwrap(), settings);
        let contents = std::fs::read_to_string(store.path()).unwrap();
        assert!(!contents.contains("apiKey"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn creates_a_private_configuration_file() {
        use std::os::unix::fs::PermissionsExt;

        let store = temporary_store();
        store.save(&AppSettings::default()).await.unwrap();
        assert_eq!(
            std::fs::metadata(store.path())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
