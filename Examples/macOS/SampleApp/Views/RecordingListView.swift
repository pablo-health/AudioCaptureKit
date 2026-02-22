import SwiftUI

/// Displays a list of past recordings with metadata and playback controls.
struct RecordingListView: View {
    let recordings: [LocalRecording]
    let playingRecordingID: UUID?
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
                        isPlaying: playingRecordingID == recording.id,
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
    let isPlaying: Bool
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
        }
        .padding(.vertical, 4)
    }
}
