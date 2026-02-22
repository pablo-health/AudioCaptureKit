import Foundation
import os

/// A simple URLSession wrapper for communicating with the sample backend.
@MainActor
final class APIClient: Sendable {
    private let logger = Logger(subsystem: "com.macos-sample", category: "APIClient")

    nonisolated var baseURL: URL {
        URL(string: _baseURLString)!
    }

    private let _baseURLString: String

    init(baseURL: String = "http://localhost:8000") {
        self._baseURLString = baseURL
    }

    /// Checks if the backend is reachable.
    func healthCheck() async throws -> Bool {
        let url = baseURL.appendingPathComponent("health")
        let (_, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }

    /// Uploads a recording file to the backend via multipart form data.
    /// Returns a progress-reporting async stream and the final upload response.
    func uploadRecording(
        fileURL: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> UploadResponse {
        let url = baseURL.appendingPathComponent("api/recordings/upload")

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let fileData = try Data(contentsOf: fileURL)
        let body = createMultipartBody(
            fileData: fileData,
            fileName: fileURL.lastPathComponent,
            boundary: boundary
        )
        request.httpBody = body

        logger.info("Uploading \(fileURL.lastPathComponent) (\(fileData.count) bytes)")

        // Simulate incremental progress since URLSession data tasks
        // don't provide upload progress natively without a delegate.
        onProgress(0.3)

        let (data, response) = try await URLSession.shared.data(for: request)

        onProgress(1.0)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Upload failed: \(httpResponse.statusCode) — \(body)")
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: body)
        }

        let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
        logger.info("Upload successful: \(decoded.id)")
        return decoded
    }

    private func createMultipartBody(
        fileData: Data,
        fileName: String,
        boundary: String
    ) -> Data {
        var body = Data()

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        return body
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}

struct UploadResponse: Codable, Sendable {
    let id: String
    let status: String
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
