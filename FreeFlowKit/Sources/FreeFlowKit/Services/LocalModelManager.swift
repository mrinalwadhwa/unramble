import Foundation

/// Manage local model files stored outside the app bundle.
///
/// Model directories can be stored under the app's Application Support
/// directory. This manager provides an explicit path and archive
/// installation utility; it does not resolve remote registry IDs.
public final class LocalModelManager: @unchecked Sendable {

    /// Root directory where model directories are stored.
    public let modelsDirectory: URL

    /// Create a manager with the default Application Support location.
    public convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("freeflow")
            .appendingPathComponent("models")
        self.init(modelsDirectory: dir)
    }

    /// Create a manager with a custom models directory.
    ///
    /// Creates the directory if it does not exist.
    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
        try? FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true)
    }

    /// Return the path where a model's files are stored.
    public func modelPath(for modelID: String) -> URL {
        modelsDirectory.appendingPathComponent(modelID)
    }

    /// Whether a model's directory exists on disk.
    public func isDownloaded(_ modelID: String) -> Bool {
        FileManager.default.fileExists(
            atPath: modelPath(for: modelID).path)
    }

    /// Delete a model's directory and all its files.
    ///
    /// No-op if the model does not exist.
    public func delete(modelID: String) throws {
        let path = modelPath(for: modelID)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    /// Available disk space in bytes on the volume hosting the models
    /// directory.
    public var availableDiskSpaceBytes: Int64 {
        let values = try? modelsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Download a model archive from a URL and extract it.
    ///
    /// - Parameters:
    ///   - modelID: Identifier used as the directory name.
    ///   - url: HTTPS URL to a `.tar.gz` or `.zip` archive.
    ///   - expectedSHA256: Optional hex-encoded SHA256 hash to verify
    ///     the download. Pass nil to skip verification.
    ///   - progress: Called with download progress (0.0 to 1.0).
    public func download(
        modelID: String,
        from url: URL,
        expectedSHA256: String? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let destination = modelPath(for: modelID)

        // Download to a temporary .partial file.
        let partial = destination.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: partial) }

        let (localURL, _) = try await URLSession.shared.download(from: url) { sent, total in
            if total > 0 {
                progress(Double(sent) / Double(total))
            }
        }

        try FileManager.default.moveItem(at: localURL, to: partial)

        // Verify hash if provided.
        if let expectedSHA256 {
            let hash = try sha256(of: partial)
            guard hash == expectedSHA256.lowercased() else {
                throw LocalModelError.modelLoadFailed(
                    "SHA256 mismatch: expected \(expectedSHA256), got \(hash)")
            }
        }

        // Extract archive to the model directory.
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        try extractArchive(partial, to: destination)

        Log.debug("[LocalModelManager] Downloaded \(modelID) to \(destination.path)")
    }

    // MARK: - Archive Extraction

    private func extractArchive(_ archive: URL, to destination: URL) throws {
        let ext = archive.pathExtension
        if ext == "partial" {
            // Inspect file magic to determine type.
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            if data.starts(with: [0x1f, 0x8b]) {
                try extractTarGz(archive, to: destination)
            } else if data.starts(with: [0x50, 0x4b]) {
                try extractZip(archive, to: destination)
            } else {
                throw LocalModelError.modelLoadFailed(
                    "Unknown archive format")
            }
        }
    }

    private func extractTarGz(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xzf", archive.path, "-C", destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalModelError.modelLoadFailed(
                "tar extraction failed with status \(process.terminationStatus)")
        }
    }

    private func extractZip(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", archive.path, "-d", destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalModelError.modelLoadFailed(
                "unzip extraction failed with status \(process.terminationStatus)")
        }
    }

    // MARK: - SHA256

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // Use CryptoKit if available, otherwise fall back to CommonCrypto.
        return sha256Hex(data)
    }
}

// MARK: - SHA256 helper

import CommonCrypto

private func sha256Hex(_ data: Data) -> String {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { raw in
        _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
}

// MARK: - URLSession download with progress

private extension URLSession {

    func download(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                progress: progress,
                completion: { result in
                    continuation.resume(with: result)
                })
            let task = self.downloadTask(with: url)
            // Store delegate reference on the task to keep it alive.
            objc_setAssociatedObject(
                task, &DownloadDelegate.key, delegate,
                .OBJC_ASSOCIATION_RETAIN)
            task.delegate = delegate
            task.resume()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {

    static var key = 0

    private let progressHandler: @Sendable (Int64, Int64) -> Void
    private let completionHandler: (Result<(URL, URLResponse), any Error>) -> Void

    init(
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        completion: @escaping (Result<(URL, URLResponse), any Error>) -> Void
    ) {
        self.progressHandler = progress
        self.completionHandler = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move to a temporary location that won't be cleaned up immediately.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            completionHandler(.success((tmp, downloadTask.response!)))
        } catch {
            completionHandler(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            completionHandler(.failure(error))
        }
    }
}
