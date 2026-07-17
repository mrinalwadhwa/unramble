import Foundation

@testable import UnrambleKit

enum LocalModelTestSupport {
    static func directory(
        environmentVariable: String = "UNRAMBLE_QWEN_MODEL_PATH"
    ) throws -> URL {
        if let path = ProcessInfo.processInfo.environment[
            environmentVariable], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // xcodebuild does not forward shell env to the test process, so fall
        // back to the app's pinned model pack (the default Qwen3 0.6B).
        if environmentVariable == "UNRAMBLE_QWEN_MODEL_PATH",
            let pack = findUpwards("UnrambleApp/Resources/models") {
            let qwen = pack.appendingPathComponent("qwen3-0.6b-4bit")
            if FileManager.default.fileExists(atPath: qwen.path) { return qwen }
        }
        throw LocalModelError.modelNotFound(
            "Set \(environmentVariable) to a local model directory")
    }

    private static func findUpwards(_ relative: String) -> URL? {
        var dir = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
