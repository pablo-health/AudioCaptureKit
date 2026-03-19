use thiserror::Error;

/// Errors that can occur during audio capture operations.
///
/// Maps 1:1 to Swift `CaptureError` enum.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CaptureError {
    #[error("permission denied")]
    PermissionDenied,

    #[error("device not available")]
    DeviceNotAvailable,

    #[error("configuration failed: {0}")]
    ConfigurationFailed(String),

    #[error("encoding failed: {0}")]
    EncodingFailed(String),

    #[error("encryption failed: {0}")]
    EncryptionFailed(String),

    #[error("storage error: {0}")]
    StorageError(String),

    #[error("timeout")]
    Timeout,

    #[error("unknown error: {0}")]
    Unknown(String),
}
