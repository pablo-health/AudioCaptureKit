import SwiftUI

/// Displays a list of past recordings with metadata and upload controls.
struct RecordingListView: View {
    let recordings: [LocalRecording]
    let uploadProgress: [UUID: Double]
    let uploadingIDs: Set<UUID>
    let playingRecordingID: UUID?
    let onUpload: (LocalRecording) -> Void
    let onPlay: (LocalRecording) -> Void
    let onStopPlayback: () -> Void

    var body: some View {
        Group {
            if recordings.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform",
                    description: Text("Start recording to see your recordings here.")
                )
            } else {
                List(recordings) { recording in
                    RecordingRow(
                        recording: recording,
                        uploadProgress: uploadProgress[recording.id],
                        isUploading: uploadingIDs.contains(recording.id),
                        isPlaying: playingRecordingID == recording.id,
                        onUpload: { onUpload(recording) },
                        onPlay: { onPlay(recording) },
                        onStopPlayback: onStopPlayback
                    )
                }
            }
        }
    }
}

struct RecordingRow: View {
    let recording: LocalRecording
    let uploadProgress: Double?
    let isUploading: Bool
    let isPlaying: Bool
    let onUpload: () -> Void
    let onPlay: () -> Void
    let onStopPlayback: () -> Void

    var body: some View {
        HStack {
            Button(action: isPlaying ? onStopPlayback : onPlay) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(isPlaying ? "Stop" : "Play")

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.fileName)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Label(recording.formattedDuration, systemImage: "clock")
                    Label(recording.formattedDate, systemImage: "calendar")
                    if recording.isEncrypted {
                        Label("Encrypted", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if recording.isUploaded {
                Label("Uploaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if isUploading {
                VStack(spacing: 2) {
                    ProgressView(value: uploadProgress ?? 0)
                        .frame(width: 80)
                    Text("\(Int((uploadProgress ?? 0) * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Upload", action: onUpload)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
