use tokio::sync::{RwLock, broadcast};

use crate::{FreeFlowError, RecordingState, Result};

/// Serialize and validate recording lifecycle transitions.
pub struct RecordingStateMachine {
    state: RwLock<RecordingState>,
    changes: broadcast::Sender<RecordingState>,
}

impl Default for RecordingStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl RecordingStateMachine {
    #[must_use]
    pub fn new() -> Self {
        let (changes, _) = broadcast::channel(64);
        Self {
            state: RwLock::new(RecordingState::Idle),
            changes,
        }
    }

    pub async fn current(&self) -> RecordingState {
        *self.state.read().await
    }

    #[must_use]
    pub fn subscribe(&self) -> broadcast::Receiver<RecordingState> {
        self.changes.subscribe()
    }

    /// Begin a new recording without racing duplicate shortcut events.
    pub async fn begin_preparing(&self) -> bool {
        let mut state = self.state.write().await;
        if !matches!(
            *state,
            RecordingState::Idle | RecordingState::Failed | RecordingState::InjectionFailed
        ) {
            return false;
        }
        *state = RecordingState::Preparing;
        let _ = self.changes.send(*state);
        true
    }

    pub async fn transition(&self, next: RecordingState) -> Result<()> {
        let mut state = self.state.write().await;
        if !Self::is_valid_transition(*state, next) {
            return Err(FreeFlowError::InvalidState(format!(
                "{:?} -> {next:?}",
                *state
            )));
        }
        *state = next;
        let _ = self.changes.send(next);
        Ok(())
    }

    pub async fn reset(&self) {
        let mut state = self.state.write().await;
        if *state != RecordingState::Idle {
            *state = RecordingState::Idle;
            let _ = self.changes.send(RecordingState::Idle);
        }
    }

    #[must_use]
    pub fn is_valid_transition(from: RecordingState, to: RecordingState) -> bool {
        use RecordingState::{
            Failed, Finalizing, Idle, Injecting, InjectionFailed, Polishing, Preparing, Recording,
            Transcribing,
        };

        matches!(
            (from, to),
            (Idle, Preparing | Injecting)
                | (Preparing, Recording | Failed | Idle)
                | (Recording, Finalizing | Failed | Idle)
                | (Finalizing, Transcribing | Failed | Idle)
                | (Transcribing, Polishing | Injecting | Failed | Idle)
                | (Polishing, Injecting | Failed | Idle)
                | (Injecting, Idle | InjectionFailed | Failed)
                | (InjectionFailed, Injecting | Preparing | Idle)
                | (Failed, Preparing | Transcribing | Idle)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn full_cycle_is_valid() {
        let state = RecordingStateMachine::new();
        assert!(state.begin_preparing().await);
        state.transition(RecordingState::Recording).await.unwrap();
        state.transition(RecordingState::Finalizing).await.unwrap();
        state
            .transition(RecordingState::Transcribing)
            .await
            .unwrap();
        state.transition(RecordingState::Polishing).await.unwrap();
        state.transition(RecordingState::Injecting).await.unwrap();
        state.transition(RecordingState::Idle).await.unwrap();
        assert_eq!(state.current().await, RecordingState::Idle);
    }

    #[tokio::test]
    async fn duplicate_begin_is_ignored() {
        let state = RecordingStateMachine::new();
        assert!(state.begin_preparing().await);
        assert!(!state.begin_preparing().await);
        assert_eq!(state.current().await, RecordingState::Preparing);
    }

    #[tokio::test]
    async fn invalid_release_does_not_mutate_state() {
        let state = RecordingStateMachine::new();
        let error = state
            .transition(RecordingState::Finalizing)
            .await
            .unwrap_err();
        assert!(matches!(error, FreeFlowError::InvalidState(_)));
        assert_eq!(state.current().await, RecordingState::Idle);
    }

    #[tokio::test]
    async fn injection_failure_allows_retry_and_new_recording() {
        let state = RecordingStateMachine::new();
        state.transition(RecordingState::Injecting).await.unwrap();
        state
            .transition(RecordingState::InjectionFailed)
            .await
            .unwrap();
        state.transition(RecordingState::Injecting).await.unwrap();
        state
            .transition(RecordingState::InjectionFailed)
            .await
            .unwrap();
        assert!(state.begin_preparing().await);
    }
}
