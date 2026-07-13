import Foundation

/// Locate optional model directories stored outside the app bundle.
///
/// The app checks its bundled model pack first, then uses this Application
/// Support location for manually provisioned models.
public struct LocalModelManager: Sendable {

    /// Root directory where model directories are stored.
    public let modelsDirectory: URL

    /// Create a manager with the default Application Support location.
    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("freeflow")
            .appendingPathComponent("models")
        self.init(modelsDirectory: dir)
    }

    /// Create a locator with a custom models directory.
    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    /// Return the path where a model's files are stored.
    public func modelPath(for modelID: String) -> URL {
        modelsDirectory.appendingPathComponent(modelID)
    }
}
