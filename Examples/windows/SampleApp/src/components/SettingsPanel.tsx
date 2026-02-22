import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "./ui/card";
import { Select, SelectTrigger, SelectContent, SelectItem, SelectValue } from "./ui/select";
import { Switch } from "./ui/switch";
import { useDevices } from "../hooks/useDevices";
import { commands, DiagnosticsInfo } from "../lib/tauri";
import type { RecordingState } from "../hooks/useRecording";

interface Props {
  state: RecordingState;
  selectedMicId: string | null;
  onMicChange: (id: string | null) => void;
  enableMic: boolean;
  onEnableMicChange: (v: boolean) => void;
  enableSystem: boolean;
  onEnableSystemChange: (v: boolean) => void;
  encrypt: boolean;
  onEncryptChange: (v: boolean) => void;
}

export default function SettingsPanel({
  state,
  selectedMicId,
  onMicChange,
  enableMic,
  onEnableMicChange,
  enableSystem,
  onEnableSystemChange,
  encrypt,
  onEncryptChange,
}: Props) {
  const { captureDevices } = useDevices();
  const isActive = state === "capturing" || state === "paused";
  const [diagnostics, setDiagnostics] = useState<DiagnosticsInfo | null>(null);

  // Poll diagnostics during recording
  useEffect(() => {
    if (!isActive) {
      setDiagnostics(null);
      return;
    }
    const interval = setInterval(async () => {
      try {
        const d = await commands.getDiagnostics();
        setDiagnostics(d);
      } catch {
        // session may not be active
      }
    }, 500);
    return () => clearInterval(interval);
  }, [isActive]);

  return (
    <div className="space-y-4">
      {/* Microphone */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Microphone</CardTitle>
        </CardHeader>
        <CardContent>
          <Select
            value={selectedMicId ?? "default"}
            onValueChange={(v) => onMicChange(v === "default" ? null : v)}
            disabled={isActive}
          >
            <SelectTrigger>
              <SelectValue placeholder="System Default" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="default">System Default</SelectItem>
              {captureDevices.map((d) => (
                <SelectItem key={d.id} value={d.id}>
                  {d.name}
                  {d.is_default ? " (Default)" : ""}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </CardContent>
      </Card>

      {/* Audio Format */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Audio Format</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-3 gap-4 text-sm">
            <div>
              <p className="text-muted-foreground">Sample Rate</p>
              <p className="font-medium">48 kHz</p>
            </div>
            <div>
              <p className="text-muted-foreground">Bit Depth</p>
              <p className="font-medium">16-bit</p>
            </div>
            <div>
              <p className="text-muted-foreground">Channels</p>
              <p className="font-medium">Stereo</p>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Encryption */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Encryption</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium">AES-256-GCM</p>
              <p className="text-xs text-muted-foreground">
                Demo key — not for production
              </p>
            </div>
            <Switch
              checked={encrypt}
              onCheckedChange={onEncryptChange}
              disabled={isActive}
            />
          </div>
        </CardContent>
      </Card>

      {/* Debug Toggles */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Debug</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-sm">Microphone capture</span>
            <Switch
              checked={enableMic}
              onCheckedChange={onEnableMicChange}
              disabled={isActive}
            />
          </div>
          <div className="flex items-center justify-between">
            <span className="text-sm">System audio capture</span>
            <Switch
              checked={enableSystem}
              onCheckedChange={onEnableSystemChange}
              disabled={isActive}
            />
          </div>
        </CardContent>
      </Card>

      {/* Diagnostics */}
      {isActive && diagnostics && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Live Diagnostics</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-xs font-mono">
              <span className="text-muted-foreground">Mic callbacks</span>
              <span>{diagnostics.micCallbackCount.toLocaleString()}</span>
              <span className="text-muted-foreground">Sys callbacks</span>
              <span>{diagnostics.systemCallbackCount.toLocaleString()}</span>
              <span className="text-muted-foreground">Bytes written</span>
              <span>{diagnostics.bytesWritten.toLocaleString()}</span>
              <span className="text-muted-foreground">Mix cycles</span>
              <span>{diagnostics.mixCycles.toLocaleString()}</span>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
