import { Mic, Square, Pause, Play } from "lucide-react";
import { Button } from "./ui/button";
import { Card, CardContent } from "./ui/card";
import type { RecordingState } from "../hooks/useRecording";

interface Props {
  state: RecordingState;
  duration: number;
  micLevel: number;
  systemLevel: number;
  onStart: () => void;
  onPause: () => void;
  onResume: () => void;
  onStop: () => void;
}

function formatDuration(secs: number): string {
  const m = Math.floor(secs / 60);
  const s = Math.floor(secs % 60);
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function stateLabel(state: RecordingState): string {
  switch (state) {
    case "capturing":
      return "Recording";
    case "paused":
      return "Paused";
    case "configuring":
    case "ready":
      return "Preparing...";
    case "stopping":
      return "Stopping...";
    default:
      return "Ready";
  }
}

function LevelMeter({ level, label }: { level: number; label: string }) {
  const height = Math.max(2, Math.min(100, level * 100));
  return (
    <div className="flex flex-col items-center gap-1.5">
      <div className="relative h-32 w-3 rounded-full bg-muted overflow-hidden">
        <div
          className="absolute bottom-0 left-0 right-0 rounded-full bg-brand transition-all duration-75"
          style={{ height: `${height}%` }}
        />
      </div>
      <span className="text-[10px] text-muted-foreground">{label}</span>
    </div>
  );
}

export default function RecordingControls({
  state,
  duration,
  micLevel,
  systemLevel,
  onStart,
  onPause,
  onResume,
  onStop,
}: Props) {
  return (
    <Card>
      <CardContent className="pt-5">
        <div className="flex flex-col items-center gap-5">
          {/* State label */}
          <p className="text-sm font-medium text-muted-foreground">
            {stateLabel(state)}
          </p>

          {/* Duration + level meters */}
          <div className="flex items-center gap-6">
            <LevelMeter level={micLevel} label="Mic" />
            <span className="font-mono text-4xl font-semibold tabular-nums tracking-tight">
              {formatDuration(duration)}
            </span>
            <LevelMeter level={systemLevel} label="Sys" />
          </div>

          {/* Debug: raw level values */}
          {(state === "capturing" || state === "paused") && (
            <p className="text-[10px] font-mono text-muted-foreground">
              mic: {micLevel.toFixed(4)} &middot; sys: {systemLevel.toFixed(4)}
            </p>
          )}

          {/* Controls */}
          <div className="flex items-center gap-3">
            {state === "idle" || state === "completed" || state === "failed" ? (
              <Button variant="brand" size="lg" onClick={onStart}>
                <Mic className="h-5 w-5" />
                Record
              </Button>
            ) : state === "capturing" ? (
              <>
                <Button variant="default" size="lg" onClick={onPause}>
                  <Pause className="h-5 w-5" />
                  Pause
                </Button>
                <Button variant="destructive" size="lg" onClick={onStop}>
                  <Square className="h-4 w-4" />
                  Stop
                </Button>
              </>
            ) : state === "paused" ? (
              <>
                <Button variant="default" size="lg" onClick={onResume}>
                  <Play className="h-5 w-5" />
                  Resume
                </Button>
                <Button variant="destructive" size="lg" onClick={onStop}>
                  <Square className="h-4 w-4" />
                  Stop
                </Button>
              </>
            ) : null}
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
