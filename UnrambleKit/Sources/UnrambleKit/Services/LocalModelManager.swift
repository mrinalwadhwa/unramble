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
            .appendingPathComponent("unramble")
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

    /// Resolve the directory holding a model, preferring the bundled model pack
    /// and then this Application Support location. `bundledModelsRoot` is the
    /// app bundle's `models` directory, or nil when the app has no resource
    /// bundle. Return the directory path where `file` is present, or nil if the
    /// model is missing from both locations.
    public func resolveModelDirectory(
        modelID: String,
        file: String,
        bundledModelsRoot: URL?
    ) -> String? {
        if let bundledModelsRoot {
            let bundled = bundledModelsRoot.appendingPathComponent(modelID)
            if FileManager.default.fileExists(
                atPath: bundled.appendingPathComponent(file).path) {
                return bundled.path
            }
        }
        let appSupport = modelPath(for: modelID)
        if FileManager.default.fileExists(
            atPath: appSupport.appendingPathComponent(file).path) {
            return appSupport.path
        }
        return nil
    }
}
