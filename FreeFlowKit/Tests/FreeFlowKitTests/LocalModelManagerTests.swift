import Foundation
import Testing

@testable import FreeFlowKit

@Suite("LocalModelManager")
struct LocalModelManagerTests {

    @Test("Maps model IDs under a custom root without creating it")
    func customRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-test-\(UUID().uuidString)")
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
            .appendingPathComponent("freeflow")
            .appendingPathComponent("models")

        #expect(LocalModelManager().modelsDirectory == expected)
    }
}
