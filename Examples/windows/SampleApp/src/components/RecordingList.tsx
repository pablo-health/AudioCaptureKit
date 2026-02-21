import { Play, Trash2, Lock } from "lucide-react";
import { open } from "@tauri-apps/plugin-shell";
import { Button } from "./ui/button";
import { Badge } from "./ui/badge";
import { Card, CardContent } from "./ui/card";
import type { RecordingInfo } from "../lib/tauri";

interface Props {
  recordings: RecordingInfo[];
  onDelete: (path: string) => void;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function formatDate(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleDateString(undefined, {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return iso;
  }
}

export default function RecordingList({ recordings, onDelete }: Props) {
  if (recordings.length === 0) {
    return (
      <div className="py-8 text-center text-sm text-muted-foreground">
        No recordings yet. Click Record to start.
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <h3 className="text-sm font-medium text-muted-foreground px-1">
        Recordings ({recordings.length})
      </h3>
      {recordings.map((rec) => (
        <Card key={rec.filePath}>
          <CardContent className="flex items-center gap-3 p-3">
            <Button
              variant="ghost"
              size="icon"
              className="shrink-0"
              onClick={() => open(rec.filePath)}
              title="Play in system player"
            >
              <Play className="h-4 w-4" />
            </Button>

            <div className="flex-1 min-w-0">
              <p className="text-sm font-medium truncate">{rec.fileName}</p>
              <p className="text-xs text-muted-foreground">
                {formatBytes(rec.sizeBytes)} &middot; {formatDate(rec.createdAt)}
              </p>
            </div>

            {rec.isEncrypted && (
              <Badge variant="brand" className="shrink-0">
                <Lock className="h-3 w-3 mr-1" />
                Encrypted
              </Badge>
            )}

            <Button
              variant="ghost"
              size="icon"
              className="shrink-0 text-muted-foreground hover:text-destructive"
              onClick={() => onDelete(rec.filePath)}
              title="Delete recording"
            >
              <Trash2 className="h-4 w-4" />
            </Button>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
