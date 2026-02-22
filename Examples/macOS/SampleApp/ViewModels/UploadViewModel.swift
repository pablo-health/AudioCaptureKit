import Foundation
import os

/// Manages uploading recordings to the sample backend.
@MainActor
@Observable
final class UploadViewModel {
    var backendURL: String = "http://localhost:8000" {
        didSet { apiClient = APIClient(baseURL: backendURL) }
    }
    var isBackendReachable: Bool = false
    var uploadProgress: [UUID: Double] = [:]
    var uploadingRecordingIDs: Set<UUID> = []
    var errorMessage: String?
    var showError: Bool = false

    private var apiClient: APIClient
    private let logger = Logger(subsystem: "com.macos-sample", category: "UploadViewModel")

    init() {
        self.apiClient = APIClient()
    }

    func checkBackendHealth() async {
        do {
            isBackendReachable = try await apiClient.healthCheck()
            logger.info("Backend health check: \(self.isBackendReachable ? "OK" : "FAILED")")
        } catch {
            isBackendReachable = false
            logger.warning("Backend unreachable: \(error.localizedDescription)")
        }
    }

    func uploadRecording(
        _ recording: LocalRecording,
        onComplete: @escaping (UUID) -> Void
    ) async {
        guard !uploadingRecordingIDs.contains(recording.id) else { return }

        uploadingRecordingIDs.insert(recording.id)
        uploadProgress[recording.id] = 0.0
        logger.info("Starting upload for \(recording.id)")

        do {
            let _ = try await apiClient.uploadRecording(
                fileURL: recording.fileURL
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.uploadProgress[recording.id] = progress
                }
            }

            uploadProgress[recording.id] = 1.0
            uploadingRecordingIDs.remove(recording.id)
            onComplete(recording.id)
            logger.info("Upload complete for \(recording.id)")
        } catch {
            uploadingRecordingIDs.remove(recording.id)
            uploadProgress.removeValue(forKey: recording.id)
            logger.error("Upload failed for \(recording.id): \(error.localizedDescription)")
            errorMessage = "Upload failed: \(error.localizedDescription)"
            showError = true
        }
    }
}
