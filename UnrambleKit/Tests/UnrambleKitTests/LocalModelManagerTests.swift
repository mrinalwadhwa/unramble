import Foundation
import Testing

@testable import UnrambleKit

@Suite("LocalModelManager")
struct LocalModelManagerTests {

    @Test("Maps model IDs under a custom root without creating it")
    func customRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unramble-test-\(UUID().uuidString)")
        let manager = LocalModelManager(modelsDirectory: root)

        #expect(
            manager.modelPath(for: "test-model")
                == root.appendingPathComponent("test-model"))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Defaults to the Application Support model root")
    func defaultRoot() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
        let expected = appSupport
            .appendingPathComponent("unramble")
            .appendingPathComponent("models")

        #expect(LocalModelManager().modelsDirectory == expected)
    }

    // MARK: - resolveModelDirectory

    /// Create a unique temporary directory for a test.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unramble-model-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write an empty file at `<root>/<modelID>/<file>`.
    private func writeModelFile(root: URL, modelID: String, file: String) throws {
        let fileURL = root
            .appendingPathComponent(modelID)
            .appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: fileURL)
    }

    @Test("Resolves the bundled directory when the model is present there")
    func resolvesBundled() throws {
        let bundled = try makeTempDir()
        let appSupport = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: appSupport)
        }
        try writeModelFile(root: bundled, modelID: "m", file: "model.bin")

        let manager = LocalModelManager(modelsDirectory: appSupport)
        let resolved = manager.resolveModelDirectory(
            modelID: "m", file: "model.bin", bundledModelsRoot: bundled)

        #expect(resolved == bundled.appendingPathComponent("m").path)
    }

    @Test("Falls back to Application Support when the model is not bundled")
    func fallsBackToAppSupport() throws {
        let bundled = try makeTempDir()
        let appSupport = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: appSupport)
        }
        try writeModelFile(root: appSupport, modelID: "m", file: "model.bin")

        let manager = LocalModelManager(modelsDirectory: appSupport)
        let resolved = manager.resolveModelDirectory(
            modelID: "m", file: "model.bin", bundledModelsRoot: bundled)

        #expect(resolved == appSupport.appendingPathComponent("m").path)
    }

    @Test("Prefers the bundled directory over Application Support")
    func prefersBundledOverAppSupport() throws {
        let bundled = try makeTempDir()
        let appSupport = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: appSupport)
        }
        try writeModelFile(root: bundled, modelID: "m", file: "model.bin")
        try writeModelFile(root: appSupport, modelID: "m", file: "model.bin")

        let manager = LocalModelManager(modelsDirectory: appSupport)
        let resolved = manager.resolveModelDirectory(
            modelID: "m", file: "model.bin", bundledModelsRoot: bundled)

        #expect(resolved == bundled.appendingPathComponent("m").path)
    }

    @Test("Uses Application Support when there is no bundled root")
    func usesAppSupportWithoutBundledRoot() throws {
        let appSupport = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        try writeModelFile(root: appSupport, modelID: "m", file: "model.bin")

        let manager = LocalModelManager(modelsDirectory: appSupport)
        let resolved = manager.resolveModelDirectory(
            modelID: "m", file: "model.bin", bundledModelsRoot: nil)

        #expect(resolved == appSupport.appendingPathComponent("m").path)
    }

    @Test("Returns nil when the model is missing from both locations")
    func missingReturnsNil() throws {
        let bundled = try makeTempDir()
        let appSupport = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let manager = LocalModelManager(modelsDirectory: appSupport)
        let resolved = manager.resolveModelDirectory(
            modelID: "m", file: "model.bin", bundledModelsRoot: bundled)

        #expect(resolved == nil)
    }

    @Test("Requires the named file, not merely the model directory")
    func requiresNamedFile() throws {
        let bundled = try makeTempDir()
        let appSupport = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: appSupport)
        }
        try writeModelFile(root: bundled, modelID: "m", file: "other.bin")

        let manager = LocalModelManager(modelsDirectory: appSupport)
        let resolved = manager.resolveModelDirectory(
            modelID: "m", file: "model.bin", bundledModelsRoot: bundled)

        #expect(resolved == nil)
    }
}
