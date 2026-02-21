import { useState } from "react";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "./components/ui/tabs";
import RecordingControls from "./components/RecordingControls";
import RecordingList from "./components/RecordingList";
import SettingsPanel from "./components/SettingsPanel";
import { useRecording } from "./hooks/useRecording";

export default function App() {
  const {
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
  } = useRecording();

  // Settings state
  const [selectedMicId, setSelectedMicId] = useState<string | null>(null);
  const [enableMic, setEnableMic] = useState(true);
  const [enableSystem, setEnableSystem] = useState(true);
  const [encrypt, setEncrypt] = useState(false);

  const handleStart = () => {
    startRecording({
      micDeviceId: selectedMicId,
      enableMic,
      enableSystem,
      encrypt,
    });
  };

  return (
    <div className="min-h-screen p-4">
      <header className="mb-4">
        <h1 className="text-2xl font-bold tracking-tight">Audio Capture</h1>
        <p className="text-sm text-muted-foreground">
          Mic + system audio recording demo
        </p>
      </header>

      {error && (
        <div className="mb-4 rounded-lg border border-destructive/50 bg-destructive/10 p-3 text-sm text-destructive">
          {error}
        </div>
      )}

      <Tabs defaultValue="recorder" className="w-full">
        <TabsList className="w-full">
          <TabsTrigger value="recorder" className="flex-1">
            Recorder
          </TabsTrigger>
          <TabsTrigger value="settings" className="flex-1">
            Settings
          </TabsTrigger>
        </TabsList>

        <TabsContent value="recorder">
          <div className="space-y-4">
            <RecordingControls
              state={state}
              duration={duration}
              micLevel={levels.micLevel}
              systemLevel={levels.systemLevel}
              onStart={handleStart}
              onPause={pauseRecording}
              onResume={resumeRecording}
              onStop={stopRecording}
            />
            <RecordingList
              recordings={recordings}
              onDelete={deleteRecording}
            />
          </div>
        </TabsContent>

        <TabsContent value="settings">
          <SettingsPanel
            state={state}
            selectedMicId={selectedMicId}
            onMicChange={setSelectedMicId}
            enableMic={enableMic}
            onEnableMicChange={setEnableMic}
            enableSystem={enableSystem}
            onEnableSystemChange={setEnableSystem}
            encrypt={encrypt}
            onEncryptChange={setEncrypt}
          />
        </TabsContent>
      </Tabs>
    </div>
  );
}
