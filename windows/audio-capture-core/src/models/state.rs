use super::error::CaptureError;
use super::recording_result::RecordingResult;

/// Capture session state machine.
///
/// State transitions:
/// ```text
/// idle → configuring → ready → capturing ↔ paused
///                                  ↓        ↓
///                               stopping → completed / failed
/// ```
#[derive(Debug, Clone, PartialEq)]
pub enum CaptureState {
    Idle,
    Configuring,
    Ready,
    Capturing { duration_secs: f64 },
    Paused { duration_secs: f64 },
    Stopping,
    Completed(RecordingResult),
    Failed(CaptureError),
}

impl CaptureState {
    pub fn is_idle(&self) -> bool {
        matches!(self, Self::Idle)
    }

    pub fn is_capturing(&self) -> bool {
        matches!(self, Self::Capturing { .. })
    }

    pub fn is_paused(&self) -> bool {
        matches!(self, Self::Paused { .. })
    }

    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Completed(_) | Self::Failed(_))
    }

    /// Returns the current duration if in a state that tracks it.
    pub fn duration(&self) -> Option<f64> {
        match self {
            Self::Capturing { duration_secs } | Self::Paused { duration_secs } => {
                Some(*duration_secs)
            }
            Self::Completed(result) => Some(result.duration_secs),
            _ => None,
        }
    }
}
