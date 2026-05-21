import Foundation

/// Run a local LLM for text completion.
///
/// Implementations wrap a specific ML runtime (MLX, Core ML, etc.)
/// and expose a simple two-message chat completion interface. The
/// engine must be loaded before use; callers check `isReady` or call
/// `load()` to ensure the model is in memory.
public protocol LocalLLMEngine: Sendable {

    /// Display name for diagnostics (e.g. "Qwen3 0.6B").
    var name: String { get }

    /// Whether the engine is loaded and ready to generate.
    var isReady: Bool { get }

    /// Load the model into memory.
    ///
    /// No-op if already loaded. Throws on failure (download error,
    /// unsupported hardware, etc.).
    func load() async throws

    /// Unload the model and release memory.
    func unload() async

    /// Complete a two-message prompt (system + user) and return the
    /// assistant's reply.
    ///
    /// - Parameters:
    ///   - systemPrompt: System message content.
    ///   - userPrompt: User message content.
    ///   - maxTokens: Maximum tokens to generate.
    /// - Returns: The generated text.
    func complete(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String
}
