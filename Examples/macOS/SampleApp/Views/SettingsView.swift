import CoreGraphics
import AudioCaptureKit
import SwiftUI

/// Settings panel for audio source selection and debug controls.
struct SettingsView: View {
    @Binding var selectedMicID: String?
    @Binding var encryptionEnabled: Bool
    @Binding var debugEnableMic: Bool
    @Binding var debugEnableSystem: Bool
    let availableMics: [AudioSource]
    let bluetoothRoutingConflict: Bool
    let bluetoothRecommendation: String?
    let systemAudioPermitted: Bool
    let recordingState: RecordingUIState
    let diagnostics: CaptureSessionDiagnostics
    let onGenerateTestTone: () -> Void

    var body: some View {
        Form {
            Section("System Audio") {
                HStack {
                    Circle()
                        .fill(systemAudioPermitted ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text(systemAudioPermitted
                         ? "Screen & System Audio Recording: Likely Granted"
                         : "Screen & System Audio Recording: Not Granted")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("System audio capture requires \"Screen & System Audio Recording\" permission. "
                     + "Enable this app in System Settings > Privacy & Security > Screen & System Audio Recording.")
                    .font(.caption)
                    .foregroundStyle(systemAudioPermitted ? Color.secondary : Color.orange)
            }

            Section("Microphone") {
                if availableMics.isEmpty {
                    Text("No microphones found")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Input Device", selection: $selectedMicID) {
                        ForEach(availableMics) { mic in
                            HStack(spacing: 6) {
                                if mic.transportType == .bluetooth || mic.transportType == .bluetoothLE {
                                    Image(systemName: "wave.3.right")
                                        .foregroundStyle(.blue)
                                }
                                Text(mic.name)
                            }
                            .tag(Optional(mic.id))
                        }
                    }

                    if bluetoothRoutingConflict, let bluetoothRecommendation {
                        Label {
                            Text(bluetoothRecommendation)
                                .font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("Audio Format") {
                LabeledContent("Sample Rate", value: "48,000 Hz")
                LabeledContent("Bit Depth", value: "16-bit")
                LabeledContent("Channels", value: "Stereo (Mic+System mixed)")
                Toggle("Encrypt recordings", isOn: $encryptionEnabled)
                if encryptionEnabled {
                    LabeledContent("Algorithm", value: "AES-256-GCM (Demo Key)")
                }
            }

            Section("Debug") {
                Toggle("Enable Mic Capture", isOn: $debugEnableMic)
                Toggle("Enable System Audio Capture", isOn: $debugEnableSystem)

                Button("Generate Test Tone (440Hz/880Hz)", action: onGenerateTestTone)
                    .buttonStyle(.bordered)

                Text("Test tone writes a 3s stereo sine wave directly to file. If it plays in both ears, the file/playback path works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if recordingState != .idle {
                    GroupBox("Live Diagnostics") {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Mic callbacks", value: "\(diagnostics.micCallbackCount)")
                            LabeledContent("Mic format", value: diagnostics.micFormat)
                            LabeledContent("Mic samples", value: "\(diagnostics.micSamplesTotal)")
                            Divider()
                            LabeledContent("System callbacks", value: "\(diagnostics.systemCallbackCount)")
                            LabeledContent("System format", value: diagnostics.systemFormat)
                            LabeledContent("System samples", value: "\(diagnostics.systemSamplesTotal)")
                            Divider()
                            LabeledContent("Mix cycles", value: "\(diagnostics.mixCycles)")
                            LabeledContent("Bytes written", value: ByteCountFormatter.string(fromByteCount: Int64(diagnostics.bytesWritten), countStyle: .file))
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 500)
    }
}
