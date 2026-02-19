import ScreenCaptureKit
import SwiftUI

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await requestScreenCapturePermission()
                }
        }
        .windowResizability(.contentMinSize)
    }

    /// Triggers the ScreenCaptureKit permission prompt, which reliably
    /// registers the app in System Settings > Privacy & Security >
    /// Screen & System Audio Recording.
    private func requestScreenCapturePermission() async {
        do {
            // This call triggers the system permission prompt on first launch.
            // It will throw if permission is denied, which is fine — we handle
            // that gracefully in the capture layer.
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            // Expected on first launch before permission is granted
        }
    }
}
