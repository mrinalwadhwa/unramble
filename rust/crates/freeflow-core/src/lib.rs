//! Platform-independent application behavior for FreeFlow.

pub mod audio;
pub mod error;
pub mod models;
pub mod pipeline;
pub mod polish;
pub mod state;
pub mod traits;
pub mod transcript;

pub use error::{FreeFlowError, Result};
pub use models::*;
pub use pipeline::{DictationOutcome, DictationPipeline, PipelineServices};
pub use state::RecordingStateMachine;
pub use traits::*;
pub use transcript::TranscriptBuffer;
