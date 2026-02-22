import { useCallback, useEffect, useRef, useState } from "react";
import { listen, UnlistenFn } from "@tauri-apps/api/event";
import { commands, RecordingConfig, RecordingInfo } from "../lib/tauri";

export type RecordingState =
  | "idle"
  | "configuring"
  | "ready"
  | "capturing"
  | "paused"
  | "stopping"
  | "completed"
  | "failed";

interface Levels {
  micLevel: number;
  systemLevel: number;
  peakMicLevel: number;
  peakSystemLevel: number;
}

interface StateChangedPayload {
  state: string;
  duration_secs: number;
}

interface LevelsPayload {
  mic_level: number;
  system_level: number;
  peak_mic_level: number;
  peak_system_level: number;
}

interface ErrorPayload {
  message: string;
}

export function useRecording() {
  const [state, setState] = useState<RecordingState>("idle");
  const [duration, setDuration] = useState(0);
  const [levels, setLevels] = useState<Levels>({
    micLevel: 0,
    systemLevel: 0,
    peakMicLevel: 0,
    peakSystemLevel: 0,
  });
  const [recordings, setRecordings] = useState<RecordingInfo[]>([]);
  const [error, setError] = useState<string | null>(null);

  // Local duration timer — the backend timer updates levels but not state-changed events
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const startTimeRef = useRef<number>(0);
  const pausedDurationRef = useRef<number>(0);

  useEffect(() => {
    if (state === "capturing") {
      if (!startTimeRef.current) {
        startTimeRef.current = Date.now();
      }
      timerRef.current = setInterval(() => {
        const elapsed = (Date.now() - startTimeRef.current) / 1000 - pausedDurationRef.current;
        setDuration(Math.max(0, elapsed));
      }, 250);
    } else if (state === "paused") {
      if (timerRef.current) {
        clearInterval(timerRef.current);
        timerRef.current = null;
      }
      const pauseStart = Date.now();
      // Track paused time when we resume
      const prevPaused = pausedDurationRef.current;
      pausedDurationRef.current = -1; // sentinel
      // Store pause start for resume calculation
      startTimeRef.current && (pausedDurationRef.current = prevPaused);
      // We'll fix the paused duration on resume
      const savedPauseStart = Date.now();
      pausedDurationRef.current = prevPaused;
      // Override: store pause start time in a separate ref
      (pausedDurationRef as any)._pauseStart = savedPauseStart;
    } else if (state === "idle" || state === "completed" || state === "failed") {
      if (timerRef.current) {
        clearInterval(timerRef.current);
        timerRef.current = null;
      }
      startTimeRef.current = 0;
      pausedDurationRef.current = 0;
    }
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [state]);

  // Load recordings on mount
  useEffect(() => {
    refreshRecordings();
  }, []);

  // Listen to Tauri events
  useEffect(() => {
    const unlisteners: UnlistenFn[] = [];

    const setup = async () => {
      unlisteners.push(
        await listen<StateChangedPayload>("audio://state-changed", (e) => {
          const newState = e.payload.state as RecordingState;
          setState((prev) => {
            // Track pause duration on resume
            if (prev === "paused" && newState === "capturing") {
              const pauseStart = (pausedDurationRef as any)._pauseStart || Date.now();
              pausedDurationRef.current += (Date.now() - pauseStart) / 1000;
            }
            return newState;
          });
        }),
      );

      unlisteners.push(
        await listen<LevelsPayload>("audio://levels-updated", (e) => {
          setLevels({
            micLevel: e.payload.mic_level,
            systemLevel: e.payload.system_level,
            peakMicLevel: e.payload.peak_mic_level,
            peakSystemLevel: e.payload.peak_system_level,
          });
        }),
      );

      unlisteners.push(
        await listen<ErrorPayload>("audio://error", (e) => {
          setError(e.payload.message);
        }),
      );

      unlisteners.push(
        await listen("audio://capture-finished", () => {
          refreshRecordings();
        }),
      );
    };

    setup();
    return () => {
      unlisteners.forEach((fn) => fn());
    };
  }, []);

  const refreshRecordings = useCallback(async () => {
    try {
      const list = await commands.getRecordings();
      setRecordings(list);
    } catch {
      // recordings dir may not exist yet
    }
  }, []);

  const startRecording = useCallback(async (config: RecordingConfig) => {
    setError(null);
    setDuration(0);
    startTimeRef.current = 0;
    pausedDurationRef.current = 0;
    setLevels({ micLevel: 0, systemLevel: 0, peakMicLevel: 0, peakSystemLevel: 0 });
    try {
      await commands.startRecording(config);
    } catch (e) {
      setError(String(e));
      setState("idle");
    }
  }, []);

  const pauseRecording = useCallback(async () => {
    try {
      await commands.pauseRecording();
    } catch (e) {
      setError(String(e));
    }
  }, []);

  const resumeRecording = useCallback(async () => {
    try {
      await commands.resumeRecording();
    } catch (e) {
      setError(String(e));
    }
  }, []);

  const stopRecording = useCallback(async () => {
    try {
      await commands.stopRecording();
      setState("idle");
      setDuration(0);
      setLevels({ micLevel: 0, systemLevel: 0, peakMicLevel: 0, peakSystemLevel: 0 });
      await refreshRecordings();
    } catch (e) {
      setError(String(e));
    }
  }, [refreshRecordings]);

  const deleteRecording = useCallback(
    async (path: string) => {
      try {
        await commands.deleteRecording(path);
        await refreshRecordings();
      } catch (e) {
        setError(String(e));
      }
    },
    [refreshRecordings],
  );

  return {
    state,
    duration,
    levels,
    recordings,
    error,
    startRecording,
    pauseRecording,
    resumeRecording,
    stopRecording,
    deleteRecording,
    refreshRecordings,
  };
}
