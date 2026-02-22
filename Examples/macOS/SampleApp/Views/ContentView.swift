import SwiftUI

/// Main view combining recording controls, recording list, and settings.
struct ContentView: View {
    @State private var recordingVM = RecordingViewModel()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // Recording tab
            VStack(spacing: 0) {
                RecordingControlsView(
                    state: recordingVM.recordingState,
                    duration: recordingVM.duration,
                    micLevel: recordingVM.micLevel,
                    systemLevel: recordingVM.systemLevel,
                    systemAudioActive: recordingVM.systemAudioActive,
                    onStart: {
                        Task { await recordingVM.startRecording() }
                    },
                    onPause: { recordingVM.pauseRecording() },
                    onResume: { recordingVM.resumeRecording() },
                    onStop: {
                        Task { await recordingVM.stopRecording() }
                    }
                )

                Divider()

                RecordingListView(
                    recordings: recordingVM.recordings,
                    playingRecordingID: recordingVM.playingRecordingID,
                    onPlay: { recording in
                        recordingVM.playRecording(recording)
                    },
                    onStopPlayback: {
                        recordingVM.stopPlayback()
                    }
                )
            }
            .tabItem {
                Label("Recorder", systemImage: "waveform")
            }
            .tag(0)

            // Settings tab
            SettingsView(
                selectedMicID: $recordingVM.selectedMicID,
                encryptionEnabled: $recordingVM.encryptionEnabled,
                debugEnableMic: $recordingVM.debugEnableMic,
                debugEnableSystem: $recordingVM.debugEnableSystem,
                availableMics: recordingVM.availableMics,
                bluetoothRoutingConflict: recordingVM.bluetoothRoutingConflict,
                bluetoothRecommendation: recordingVM.bluetoothRecommendation,
                systemAudioPermitted: recordingVM.systemAudioPermitted,
                recordingState: recordingVM.recordingState,
                diagnostics: recordingVM.debugDiagnostics,
                onGenerateTestTone: {
                    recordingVM.generateTestTone()
                }
            )
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(1)
        }
        .frame(minWidth: 500, minHeight: 600)
        .task {
            await recordingVM.loadAudioSources()
        }
        .alert(
            "Recording Error",
            isPresented: $recordingVM.showError,
            presenting: recordingVM.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}
