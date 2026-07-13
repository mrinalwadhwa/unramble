import Foundation

@testable import FreeFlowKit

enum LocalModelTestSupport {
    static func directory(
        environmentVariable: String = "FREEFLOW_QWEN_MODEL_PATH"
    ) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[
            environmentVariable], !path.isEmpty
        else {
            throw LocalModelError.modelNotFound(
                "Set \(environmentVariable) to a local model directory")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
