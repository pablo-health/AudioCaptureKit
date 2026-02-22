import SwiftUI

/// Recording controls with record/pause/stop buttons and audio level meters.
struct RecordingControlsView: View {
    let state: RecordingUIState
    let duration: TimeInterval
    let micLevel: Float
    let systemLevel: Float
    let systemAudioActive: Bool

    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Duration display
            Text(formattedDuration)
                .font(.system(size: 48, weight: .light, design: .monospaced))
                .foregroundStyle(state == .recording ? .primary : .secondary)

            // State label
            Text(stateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Audio level meters
            HStack(spacing: 24) {
                LevelMeter(label: "Mic", level: micLevel)
                LevelMeter(label: "System", level: systemLevel)
            }
            .frame(height: 100)
            .padding(.vertical, 8)

            // System audio status (visible while recording)
            if state == .recording || state == .paused {
                HStack(spacing: 6) {
                    Circle()
                        .fill(systemAudioActive ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(systemAudioActive ? "System Audio: Active" : "System Audio: Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Control buttons
            HStack(spacing: 20) {
                switch state {
                case .idle:
                    Button(action: onStart) {
                        Label("Record", systemImage: "record.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)

                case .recording:
                    Button(action: onPause) {
                        Label("Pause", systemImage: "pause.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)

                case .paused:
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                }
            }
        }
        .padding()
    }

    private var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var stateLabel: String {
        switch state {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .paused: return "Paused"
        }
    }
}

/// A vertical audio level meter.
struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(levelColor)
                        .frame(
                            height: max(
                                0,
                                geometry.size.height * CGFloat(clampedLevel)
                            )
                        )
                }
            }
            .frame(width: 24)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var clampedLevel: Float {
        min(max(level, 0), 1)
    }

    private var levelColor: Color {
        if clampedLevel > 0.8 {
            return .red
        } else if clampedLevel > 0.5 {
            return .yellow
        } else {
            return .green
        }
    }
}
