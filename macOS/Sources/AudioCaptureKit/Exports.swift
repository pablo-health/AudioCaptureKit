// Re-export the Foundation-only core so `import AudioCaptureKit` continues to
// surface the models, protocols and storage types exactly as it did before the
// split. Without this, every existing consumer would have to add a second
// import for types that never moved as far as they are concerned.
@_exported import AudioCaptureCore
