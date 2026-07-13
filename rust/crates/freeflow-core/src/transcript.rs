use tokio::sync::RwLock;

/// Retain the latest successful transcript until the user replaces or clears it.
#[derive(Default)]
pub struct TranscriptBuffer {
    value: RwLock<Option<String>>,
}

impl TranscriptBuffer {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn store(&self, transcript: impl Into<String>) {
        *self.value.write().await = Some(transcript.into());
    }

    pub async fn get(&self) -> Option<String> {
        self.value.read().await.clone()
    }

    pub async fn has_transcript(&self) -> bool {
        self.value.read().await.is_some()
    }

    pub async fn clear(&self) {
        *self.value.write().await = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn replacement_and_clear_are_atomic() {
        let buffer = TranscriptBuffer::new();
        assert!(!buffer.has_transcript().await);
        buffer.store("first").await;
        buffer.store("second").await;
        assert_eq!(buffer.get().await.as_deref(), Some("second"));
        buffer.clear().await;
        assert_eq!(buffer.get().await, None);
    }
}
