import Foundation

/// On-device LLM polish client using a local engine.
///
/// Bridge a `LocalLLMEngine` to the `PolishChatClient` protocol so
/// the polish pipeline can use a local model (e.g. MLX-backed Qwen3)
/// with the same interface as the cloud client. The `model` parameter
/// is ignored — the engine determines which model runs.
public struct MLXPolishClient: PolishChatClient {

    private let engine: any LocalLLMEngine
    private let timeoutSeconds: TimeInterval

    public init(engine: any LocalLLMEngine, timeoutSeconds: TimeInterval = 10) {
        self.engine = engine
        self.timeoutSeconds = timeoutSeconds
    }

    public func complete(
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        if !engine.isReady {
            Log.debug("[MLXPolish] Loading LLM engine \(engine.name)...")
            try await engine.load()
            Log.debug("[MLXPolish] LLM engine loaded")
        }

        // Prepend /no_think to suppress Qwen3's chain-of-thought mode.
        let effectivePrompt = "/no_think\n" + userPrompt

        let result: String? = await withTimeout(seconds: timeoutSeconds) {
            guard let text = try? await engine.complete(
                systemPrompt: systemPrompt,
                userPrompt: effectivePrompt,
                maxTokens: 512
            ) else { return "" }
            return Self.stripThinkingTags(
                text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let text = result, !text.isEmpty else { return "" }
        return text
    }

    /// Strip `<think>...</think>` reasoning blocks that some models
    /// (e.g. Qwen3) emit by default.
    private static func stripThinkingTags(_ text: String) -> String {
        // Remove <think>...</think> blocks (including newlines).
        var result = text
        while let start = result.range(of: "<think>"),
              let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex)
        {
            result.removeSubrange(start.lowerBound...end.upperBound)
        }
        // Also strip a leading <think> without a closing tag (truncated).
        if let start = result.range(of: "<think>") {
            result.removeSubrange(start.lowerBound..<result.endIndex)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
