import Foundation
import Testing

@testable import FreeFlowKit

@Suite("LocalModelManager")
struct LocalModelManagerTests {

    // MARK: - Helpers

    /// Create a manager using a temporary directory.
    private func makeManager() throws -> (LocalModelManager, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        let manager = LocalModelManager(modelsDirectory: tmp)
        return (manager, tmp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Model path

    @Test("Returns path under models directory for model ID")
    func modelPath() throws {
        let (manager, tmp) = try makeManager()
        defer { cleanup(tmp) }

        let path = manager.modelPath(for: "parakeet-tdt-0.6b")
        #expect(path.lastPathComponent == "parakeet-tdt-0.6b")
        #expect(path.deletingLastPathComponent().path == tmp.path)
    }

    // MARK: - isDownloaded

    @Test("Reports not downloaded when directory missing")
    func notDownloaded() throws {
        let (manager, tmp) = try makeManager()
        defer { cleanup(tmp) }

        #expect(!manager.isDownloaded("nonexistent-model"))
    }

    @Test("Reports downloaded when directory exists")
    func downloaded() throws {
        let (manager, tmp) = try makeManager()
        defer { cleanup(tmp) }

        let modelDir = tmp.appendingPathComponent("test-model")
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)

        #expect(manager.isDownloaded("test-model"))
    }

    // MARK: - Delete

    @Test("Deletes model directory")
    func deleteModel() throws {
        let (manager, tmp) = try makeManager()
        defer { cleanup(tmp) }

        let modelDir = tmp.appendingPathComponent("test-model")
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        // Add a file inside to confirm recursive delete.
        try "test".write(
            to: modelDir.appendingPathComponent("weights.bin"),
            atomically: true, encoding: .utf8)

        #expect(manager.isDownloaded("test-model"))
        try manager.delete(modelID: "test-model")
        #expect(!manager.isDownloaded("test-model"))
    }

    @Test("Delete is a no-op when model does not exist")
    func deleteNonexistent() throws {
        let (manager, tmp) = try makeManager()
        defer { cleanup(tmp) }

        // Should not throw.
        try manager.delete(modelID: "nonexistent")
    }

    // MARK: - Models directory creation

    @Test("Creates models directory on init if missing")
    func createsDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-test-\(UUID().uuidString)")
        defer { cleanup(tmp) }

        // Directory does not exist yet.
        #expect(!FileManager.default.fileExists(atPath: tmp.path))

        _ = LocalModelManager(modelsDirectory: tmp)

        #expect(FileManager.default.fileExists(atPath: tmp.path))
    }

    // MARK: - Available disk space

    @Test("Reports available disk space as non-negative")
    func availableDiskSpace() throws {
        let (manager, tmp) = try makeManager()
        defer { cleanup(tmp) }

        let space = manager.availableDiskSpaceBytes
        #expect(space >= 0)
    }
}
