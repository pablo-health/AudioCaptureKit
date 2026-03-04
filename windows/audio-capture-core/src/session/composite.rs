use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use parking_lot::Mutex;

use crate::models::audio_models::{AudioLevels, AudioSource, CaptureSessionDiagnostics, ChannelBuffers};
use crate::models::config::CaptureConfiguration;
use crate::models::error::CaptureError;
use crate::models::mixing_strategy::MixingStrategy;
use crate::models::recording_result::{RecordingMetadata, RecordingResult};
use crate::models::state::CaptureState;
use crate::processing::ring_buffer::RingBuffer;
use crate::processing::stereo_mixer::StereoMixer;
use crate::processing::wav_format;
use crate::storage::encrypted_writer::EncryptedFileWriter;
use crate::traits::capture_delegate::CaptureDelegate;
use crate::traits::capture_provider::CaptureProvider;

pub type ChannelBufferCallback = Arc<dyn Fn(&ChannelBuffers) + Send + Sync + 'static>;

/// Parameters for mixing, diarization, and raw PCM export during processing.
struct ProcessingContext {
    enable_system: bool,
    chunk_size: usize,
    mixing_strategy: MixingStrategy,
    channel_buffer_callback: Option<ChannelBufferCallback>,
    export_raw_pcm: bool,
    mic_pcm_writer: Arc<Mutex<Option<std::fs::File>>>,
    system_pcm_writer: Arc<Mutex<Option<std::fs::File>>>,
}

/// Internal mutable session state, protected by `parking_lot::Mutex`.
struct SessionState {
    state: CaptureState,
    levels: AudioLevels,
    capture_start: Option<Instant>,
    paused_duration: Duration,
    last_pause_time: Option<Instant>,
    diagnostics: CaptureSessionDiagnostics,
    detected_mic_rate: Option<f64>,
}

impl SessionState {
    fn new() -> Self {
        Self {
            state: CaptureState::Idle,
            levels: AudioLevels::default(),
            capture_start: None,
            paused_duration: Duration::ZERO,
            last_pause_time: None,
            diagnostics: CaptureSessionDiagnostics::default(),
            detected_mic_rate: None,
        }
    }

    fn elapsed_duration(&self) -> f64 {
        let Some(start) = self.capture_start else {
            return 0.0;
        };
        let total = start.elapsed();
        let active = total - self.paused_duration;
        active.as_secs_f64()
    }
}

/// Platform-agnostic capture session orchestrator.
///
/// Generic over mic and system audio backends via `CaptureProvider` trait.
/// Handles mixing, buffering, encryption, and file output.
///
/// Ports Swift's `CompositeCaptureSession` with the same data flow:
/// ```text
/// [Mic Provider] → [Mic RingBuffer] ─┐
///                                     ├→ [StereoMixer] → [PCM] → [EncryptedFileWriter]
/// [System Provider] → [Sys RingBuffer]┘
/// ```
pub struct CompositeSession<M: CaptureProvider, S: CaptureProvider> {
    mic: M,
    system: S,
    mixer: StereoMixer,
    config: Option<CaptureConfiguration>,
    session_state: Arc<Mutex<SessionState>>,
    delegate: Option<Arc<dyn CaptureDelegate>>,

    // Ring buffers shared between capture callbacks and processing thread
    mic_buffer: Arc<Mutex<RingBuffer>>,
    system_buffer: Arc<Mutex<RingBuffer>>,

    // File writer (accessed from processing thread)
    writer: Arc<Mutex<Option<EncryptedFileWriter>>>,

    // Processing thread control
    processing_running: Arc<AtomicBool>,
    processing_handle: Option<thread::JoinHandle<()>>,

    // Duration timer thread control
    timer_running: Arc<AtomicBool>,
    timer_handle: Option<thread::JoinHandle<()>>,

    // Output file path for result
    file_path: Option<PathBuf>,

    // Channel buffer callback for raw per-channel audio delivery
    channel_buffer_callback: Option<ChannelBufferCallback>,

    // PCM sidecar writers (when export_raw_pcm is enabled)
    mic_pcm_writer: Arc<Mutex<Option<std::fs::File>>>,
    system_pcm_writer: Arc<Mutex<Option<std::fs::File>>>,
    mic_pcm_path: Option<PathBuf>,
    system_pcm_path: Option<PathBuf>,
}

impl<M: CaptureProvider, S: CaptureProvider> CompositeSession<M, S> {
    pub fn new(mic: M, system: S) -> Self {
        Self {
            mic,
            system,
            mixer: StereoMixer::new(48000.0),
            config: None,
            session_state: Arc::new(Mutex::new(SessionState::new())),
            delegate: None,
            mic_buffer: Arc::new(Mutex::new(RingBuffer::new(1))), // placeholder, resized on configure
            system_buffer: Arc::new(Mutex::new(RingBuffer::new(1))),
            writer: Arc::new(Mutex::new(None)),
            processing_running: Arc::new(AtomicBool::new(false)),
            processing_handle: None,
            timer_running: Arc::new(AtomicBool::new(false)),
            timer_handle: None,
            file_path: None,
            channel_buffer_callback: None,
            mic_pcm_writer: Arc::new(Mutex::new(None)),
            system_pcm_writer: Arc::new(Mutex::new(None)),
            mic_pcm_path: None,
            system_pcm_path: None,
        }
    }

    pub fn set_channel_buffer_callback(&mut self, cb: ChannelBufferCallback) {
        self.channel_buffer_callback = Some(cb);
    }

    pub fn set_delegate(&mut self, delegate: Arc<dyn CaptureDelegate>) {
        self.delegate = Some(delegate);
    }

    pub fn state(&self) -> CaptureState {
        self.session_state.lock().state.clone()
    }

    pub fn current_levels(&self) -> AudioLevels {
        self.session_state.lock().levels
    }

    pub fn diagnostics(&self) -> CaptureSessionDiagnostics {
        self.session_state.lock().diagnostics.clone()
    }

    pub fn available_audio_sources(&self) -> Result<Vec<AudioSource>, CaptureError> {
        let mut sources = Vec::new();
        if self.mic.is_available() {
            sources.push(self.mic.device_info());
        }
        if self.system.is_available() {
            sources.push(self.system.device_info());
        }
        Ok(sources)
    }

    /// Apply configuration. Transitions: idle → configuring → ready.
    pub fn configure(&mut self, config: CaptureConfiguration) -> Result<(), CaptureError> {
        {
            let state = &self.session_state.lock().state;
            if !state.is_idle() {
                return Err(CaptureError::ConfigurationFailed(
                    "can only configure from idle state".into(),
                ));
            }
        }

        config.validate().map_err(CaptureError::ConfigurationFailed)?;

        self.set_state(CaptureState::Configuring);

        self.mixer = StereoMixer::new(config.sample_rate);

        // Size ring buffers for 5 seconds of audio
        let buffer_capacity = (config.sample_rate * 5.0) as usize;
        self.mic_buffer = Arc::new(Mutex::new(RingBuffer::new(buffer_capacity)));
        self.system_buffer = Arc::new(Mutex::new(RingBuffer::new(buffer_capacity * 2))); // stereo

        self.config = Some(config);
        self.set_state(CaptureState::Ready);
        Ok(())
    }

    /// Start capture. Transitions: ready → capturing.
    pub fn start_capture(&mut self) -> Result<(), CaptureError> {
        let config = self
            .config
            .as_ref()
            .ok_or(CaptureError::ConfigurationFailed("not configured".into()))?;

        {
            let state = &self.session_state.lock().state;
            if !matches!(state, CaptureState::Ready) {
                return Err(CaptureError::ConfigurationFailed(
                    "can only start from ready state".into(),
                ));
            }
        }

        let output_rate = config.sample_rate;

        // Set up file writer
        let file_name = format!("recording_{}", uuid::Uuid::new_v4());
        let file_ext = if config.encryptor.is_some() { "enc.wav" } else { "wav" };
        let file_path = config.output_directory.join(format!("{}.{}", file_name, file_ext));
        self.file_path = Some(file_path.clone());

        let mut writer = EncryptedFileWriter::new(file_path.clone(), config.encryptor.clone());
        writer.open(config)?;
        *self.writer.lock() = Some(writer);

        // Open PCM sidecar files if requested
        if config.export_raw_pcm {
            let mic_pcm_path = config.output_directory.join(format!("{}_mic.pcm", file_name));
            let system_pcm_path = config.output_directory.join(format!("{}_system.pcm", file_name));
            match std::fs::File::create(&mic_pcm_path) {
                Ok(f) => {
                    *self.mic_pcm_writer.lock() = Some(f);
                    self.mic_pcm_path = Some(mic_pcm_path);
                }
                Err(e) => log::error!("Failed to create mic PCM sidecar: {}", e),
            }
            match std::fs::File::create(&system_pcm_path) {
                Ok(f) => {
                    *self.system_pcm_writer.lock() = Some(f);
                    self.system_pcm_path = Some(system_pcm_path);
                }
                Err(e) => log::error!("Failed to create system PCM sidecar: {}", e),
            }
        }

        // Start mic capture
        if config.enable_mic_capture && self.mic.is_available() {
            let mic_buf = Arc::clone(&self.mic_buffer);
            let state = Arc::clone(&self.session_state);
            let mixer = self.mixer.clone();

            let callback = Arc::new(move |samples: &[f32], sample_rate: f64, channels: u16| {
                // Downmix to mono if needed
                let mono = if channels > 1 {
                    wav_format::downmix_to_mono(samples, channels as usize)
                } else {
                    samples.to_vec()
                };

                // Resample to output rate
                let resampled = mixer.resample(&mono, sample_rate);

                // Update levels
                let rms = StereoMixer::rms_level(&resampled);
                let peak = StereoMixer::peak_level(&resampled);
                {
                    let mut s = state.lock();
                    s.levels.mic_level = rms;
                    s.levels.peak_mic_level = peak;
                    s.diagnostics.mic_callback_count += 1;
                    s.diagnostics.mic_samples_total += resampled.len() as u64;
                }

                // Write to ring buffer
                mic_buf.lock().write(&resampled);
            });

            self.mic.start(callback)?;
        }

        // Start system audio capture
        if config.enable_system_capture && self.system.is_available() {
            let sys_buf = Arc::clone(&self.system_buffer);
            let state = Arc::clone(&self.session_state);
            let mixer = self.mixer.clone();

            let callback = Arc::new(move |samples: &[f32], sample_rate: f64, channels: u16| {
                // Resample stereo or mono→stereo
                let resampled = if channels >= 2 {
                    mixer.resample_stereo(samples, sample_rate)
                } else {
                    let mono = mixer.resample(samples, sample_rate);
                    mixer.interleave(&mono, &mono)
                };

                // Update levels (use left channel for RMS)
                let left_samples: Vec<f32> = resampled.iter().step_by(2).copied().collect();
                let rms = StereoMixer::rms_level(&left_samples);
                let peak = StereoMixer::peak_level(&left_samples);
                {
                    let mut s = state.lock();
                    s.levels.system_level = rms;
                    s.levels.peak_system_level = peak;
                    s.diagnostics.system_callback_count += 1;
                    s.diagnostics.system_samples_total += resampled.len() as u64;
                }

                // Write to ring buffer (stereo interleaved)
                sys_buf.lock().write(&resampled);
            });

            self.system.start(callback)?;
        }

        // Mark capturing
        {
            let mut s = self.session_state.lock();
            s.capture_start = Some(Instant::now());
            s.paused_duration = Duration::ZERO;
        }
        self.set_state(CaptureState::Capturing { duration_secs: 0.0 });

        // Start processing loop (100ms intervals)
        self.start_processing_loop(output_rate);

        // Start duration timer (250ms intervals)
        self.start_duration_timer();

        Ok(())
    }

    /// Pause capture. Transitions: capturing → paused.
    pub fn pause_capture(&mut self) -> Result<(), CaptureError> {
        let duration = {
            let s = self.session_state.lock();
            match &s.state {
                CaptureState::Capturing { duration_secs } => *duration_secs,
                _ => {
                    return Err(CaptureError::ConfigurationFailed(
                        "can only pause from capturing state".into(),
                    ))
                }
            }
        };

        {
            let mut s = self.session_state.lock();
            s.last_pause_time = Some(Instant::now());
        }
        self.set_state(CaptureState::Paused {
            duration_secs: duration,
        });
        Ok(())
    }

    /// Resume capture. Transitions: paused → capturing.
    pub fn resume_capture(&mut self) -> Result<(), CaptureError> {
        let duration = {
            let s = self.session_state.lock();
            match &s.state {
                CaptureState::Paused { duration_secs } => *duration_secs,
                _ => {
                    return Err(CaptureError::ConfigurationFailed(
                        "can only resume from paused state".into(),
                    ))
                }
            }
        };

        {
            let mut s = self.session_state.lock();
            if let Some(pause_start) = s.last_pause_time.take() {
                s.paused_duration += pause_start.elapsed();
            }
        }
        self.set_state(CaptureState::Capturing {
            duration_secs: duration,
        });
        Ok(())
    }

    /// Stop capture, finalize file, return result.
    /// Transitions: capturing/paused → stopping → completed/failed.
    pub fn stop_capture(&mut self) -> Result<RecordingResult, CaptureError> {
        {
            let s = self.session_state.lock();
            if !s.state.is_capturing() && !s.state.is_paused() {
                return Err(CaptureError::ConfigurationFailed(
                    "can only stop from capturing or paused state".into(),
                ));
            }
        }

        self.set_state(CaptureState::Stopping);

        // Stop capture providers
        let _ = self.mic.stop();
        let _ = self.system.stop();

        // Stop processing and timer threads
        self.processing_running.store(false, Ordering::SeqCst);
        self.timer_running.store(false, Ordering::SeqCst);

        if let Some(handle) = self.processing_handle.take() {
            let _ = handle.join();
        }
        if let Some(handle) = self.timer_handle.take() {
            let _ = handle.join();
        }

        // Flush remaining buffers one final time
        self.process_buffers_once();

        // Finalize file
        let config = self.config.as_ref().unwrap();
        let file_path = self.file_path.as_ref().unwrap().clone();
        let detected_rate = self.session_state.lock().detected_mic_rate;
        let actual_rate = detected_rate.map(|r| r.min(config.sample_rate));

        let checksum = {
            let mut writer_guard = self.writer.lock();
            if let Some(ref mut writer) = *writer_guard {
                let cs = writer.close(actual_rate, config.channels, config.bit_depth)?;
                *writer_guard = None;
                cs
            } else {
                return Err(CaptureError::StorageError("file writer not available".into()));
            }
        };

        let duration = self.session_state.lock().elapsed_duration();

        let metadata = match config.mixing_strategy {
            MixingStrategy::Separated => RecordingMetadata::new_separated(
                duration,
                &file_path.to_string_lossy(),
                &checksum,
                config.encryptor.is_some(),
                config.encryptor.as_ref().map(|e| e.algorithm().to_string()),
                config
                    .encryptor
                    .as_ref()
                    .and_then(|e| e.key_metadata().get("keyId").cloned()),
            ),
            MixingStrategy::Blended | MixingStrategy::Multichannel => RecordingMetadata::new_stereo(
                duration,
                &file_path.to_string_lossy(),
                &checksum,
                config.encryptor.is_some(),
                config.encryptor.as_ref().map(|e| e.algorithm().to_string()),
                config
                    .encryptor
                    .as_ref()
                    .and_then(|e| e.key_metadata().get("keyId").cloned()),
            ),
        };

        // Close PCM sidecar files
        *self.mic_pcm_writer.lock() = None;
        *self.system_pcm_writer.lock() = None;

        // Collect PCM sidecar paths
        let mut raw_pcm_file_paths = Vec::new();
        if config.export_raw_pcm {
            if let Some(ref p) = self.mic_pcm_path {
                raw_pcm_file_paths.push(p.clone());
            }
            if let Some(ref p) = self.system_pcm_path {
                raw_pcm_file_paths.push(p.clone());
            }
        }

        let result = RecordingResult {
            file_path: file_path.clone(),
            duration_secs: duration,
            metadata,
            checksum,
            raw_pcm_file_paths,
        };

        self.set_state(CaptureState::Completed(Box::new(result.clone())));

        if let Some(ref delegate) = self.delegate {
            delegate.on_capture_finished(&result);
        }

        // Reset for next session
        self.session_state.lock().state = CaptureState::Idle;

        Ok(result)
    }

    // --- Internal helpers ---

    fn set_state(&self, new_state: CaptureState) {
        {
            let mut s = self.session_state.lock();
            s.state = new_state.clone();
        }
        if let Some(ref delegate) = self.delegate {
            delegate.on_state_changed(&new_state);
        }
    }

    /// Start the background processing loop that reads ring buffers,
    /// mixes audio, and writes to the encrypted file.
    fn start_processing_loop(&mut self, output_rate: f64) {
        self.processing_running.store(true, Ordering::SeqCst);

        let running = Arc::clone(&self.processing_running);
        let session_state = Arc::clone(&self.session_state);
        let mic_buf = Arc::clone(&self.mic_buffer);
        let sys_buf = Arc::clone(&self.system_buffer);
        let writer = Arc::clone(&self.writer);
        let mixer = self.mixer.clone();
        let ctx = ProcessingContext {
            enable_system: self.config.as_ref().map(|c| c.enable_system_capture).unwrap_or(false),
            chunk_size: (output_rate * 0.1) as usize, // 100ms of frames
            mixing_strategy: self
                .config
                .as_ref()
                .map(|c| c.mixing_strategy.clone())
                .unwrap_or_default(),
            channel_buffer_callback: self.channel_buffer_callback.clone(),
            export_raw_pcm: self.config.as_ref().map(|c| c.export_raw_pcm).unwrap_or(false),
            mic_pcm_writer: Arc::clone(&self.mic_pcm_writer),
            system_pcm_writer: Arc::clone(&self.system_pcm_writer),
        };

        let handle = thread::Builder::new()
            .name("audio-processing".into())
            .spawn(move || {
                while running.load(Ordering::SeqCst) {
                    thread::sleep(Duration::from_millis(100));

                    // Only process during capturing state
                    let is_capturing = {
                        let s = session_state.lock();
                        s.state.is_capturing()
                    };
                    if !is_capturing {
                        continue;
                    }

                    Self::process_buffers_inner(&mic_buf, &sys_buf, &writer, &mixer, &session_state, &ctx);
                }
            })
            .expect("failed to spawn processing thread");

        self.processing_handle = Some(handle);
    }

    /// Start the duration update timer (250ms).
    fn start_duration_timer(&mut self) {
        self.timer_running.store(true, Ordering::SeqCst);

        let running = Arc::clone(&self.timer_running);
        let session_state = Arc::clone(&self.session_state);
        let delegate = self.delegate.clone();

        let handle = thread::Builder::new()
            .name("duration-timer".into())
            .spawn(move || {
                while running.load(Ordering::SeqCst) {
                    thread::sleep(Duration::from_millis(250));

                    let mut s = session_state.lock();
                    if let CaptureState::Capturing { .. } = &s.state {
                        let dur = s.elapsed_duration();
                        s.state = CaptureState::Capturing { duration_secs: dur };
                        let levels = s.levels;
                        drop(s);

                        if let Some(ref d) = delegate {
                            d.on_levels_updated(&levels);
                        }
                    }
                }
            })
            .expect("failed to spawn timer thread");

        self.timer_handle = Some(handle);
    }

    /// One-shot buffer processing (for final flush).
    fn process_buffers_once(&self) {
        let config = match &self.config {
            Some(c) => c,
            None => return,
        };

        let ctx = ProcessingContext {
            enable_system: config.enable_system_capture,
            chunk_size: (config.sample_rate * 0.1) as usize,
            mixing_strategy: config.mixing_strategy.clone(),
            channel_buffer_callback: self.channel_buffer_callback.clone(),
            export_raw_pcm: config.export_raw_pcm,
            mic_pcm_writer: Arc::clone(&self.mic_pcm_writer),
            system_pcm_writer: Arc::clone(&self.system_pcm_writer),
        };

        Self::process_buffers_inner(
            &self.mic_buffer,
            &self.system_buffer,
            &self.writer,
            &self.mixer,
            &self.session_state,
            &ctx,
        );
    }

    /// Core buffer processing: read ring buffers → mix → convert to PCM → write.
    fn process_buffers_inner(
        mic_buf: &Mutex<RingBuffer>,
        sys_buf: &Mutex<RingBuffer>,
        writer: &Mutex<Option<EncryptedFileWriter>>,
        mixer: &StereoMixer,
        session_state: &Mutex<SessionState>,
        ctx: &ProcessingContext,
    ) {
        let mic_samples: Vec<f32>;
        let system_samples: Vec<f32>;

        if ctx.enable_system {
            // System audio drives timing
            let system_frames_available = sys_buf.lock().count() / 2;
            let frames_to_process = system_frames_available.min(ctx.chunk_size);
            if frames_to_process == 0 {
                return;
            }

            system_samples = sys_buf.lock().read(frames_to_process * 2);
            mic_samples = mic_buf.lock().read(frames_to_process);
        } else {
            // Mic-only mode
            mic_samples = mic_buf.lock().read(ctx.chunk_size);
            system_samples = Vec::new();
            if mic_samples.is_empty() {
                return;
            }
        }

        // Deliver raw channel buffers before mixing
        if let Some(ref cb) = ctx.channel_buffer_callback {
            let buffers = ChannelBuffers {
                mic_samples: mic_samples.clone(),
                system_samples: system_samples.clone(),
                sample_rate: mixer.target_sample_rate,
                timestamp_unix_secs: {
                    use std::time::{SystemTime, UNIX_EPOCH};
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .map(|d| d.as_secs_f64())
                        .unwrap_or(0.0)
                },
            };
            cb(&buffers);
        }

        // Write raw PCM sidecars if enabled
        if ctx.export_raw_pcm {
            let mic_pcm = mixer.convert_to_int16_pcm(&mic_samples);
            let system_pcm = mixer.convert_to_int16_pcm(&system_samples);
            if let Some(ref mut f) = *ctx.mic_pcm_writer.lock() {
                use std::io::Write;
                let _ = f.write_all(&mic_pcm);
            }
            if let Some(ref mut f) = *ctx.system_pcm_writer.lock() {
                use std::io::Write;
                let _ = f.write_all(&system_pcm);
            }
        }

        // Mix according to strategy
        let stereo = mixer.mix(&mic_samples, &system_samples, &ctx.mixing_strategy);

        // Convert to 16-bit PCM
        let pcm = mixer.convert_to_int16_pcm(&stereo);

        // Update diagnostics
        {
            let mut s = session_state.lock();
            s.diagnostics.mix_cycles += 1;
            s.diagnostics.bytes_written += pcm.len() as u64;
        }

        // Write to file
        if let Some(ref mut w) = *writer.lock() {
            if let Err(e) = w.write(&pcm) {
                log::error!("Failed to write audio data: {}", e);
            }
        }
    }
}
