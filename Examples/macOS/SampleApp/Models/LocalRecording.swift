import Foundation

/// A locally stored recording with metadata for display.
struct LocalRecording: Identifiable, Sendable {
    let id: UUID
    let fileURL: URL
    let duration: TimeInterval
    let createdAt: Date
    let isEncrypted: Bool
    let checksum: String

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    var fileName: String {
        fileURL.lastPathComponent
    }
}
