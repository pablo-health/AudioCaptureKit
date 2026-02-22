import { invoke } from "@tauri-apps/api/core";

export interface DeviceInfo {
  id: string;
  name: string;
  is_default: boolean;
}

export interface RecordingConfig {
  micDeviceId: string | null;
  enableMic: boolean;
  enableSystem: boolean;
  encrypt: boolean;
}

export interface RecordingInfo {
  filePath: string;
  fileName: string;
  sizeBytes: number;
  isEncrypted: boolean;
  createdAt: string;
}

export interface DiagnosticsInfo {
  micCallbackCount: number;
  systemCallbackCount: number;
  micSamplesTotal: number;
  systemSamplesTotal: number;
  micFormat: string;
  systemFormat: string;
  bytesWritten: number;
  mixCycles: number;
}

export const commands = {
  listCaptureDevices: () =>
    invoke<DeviceInfo[]>("list_capture_devices"),

  listRenderDevices: () =>
    invoke<DeviceInfo[]>("list_render_devices"),

  startRecording: (config: RecordingConfig) =>
    invoke<void>("start_recording", { config }),

  pauseRecording: () =>
    invoke<void>("pause_recording"),

  resumeRecording: () =>
    invoke<void>("resume_recording"),

  stopRecording: () =>
    invoke<RecordingInfo>("stop_recording"),

  getRecordings: () =>
    invoke<RecordingInfo[]>("get_recordings"),

  deleteRecording: (path: string) =>
    invoke<void>("delete_recording", { path }),

  getDiagnostics: () =>
    invoke<DiagnosticsInfo>("get_diagnostics"),
};
