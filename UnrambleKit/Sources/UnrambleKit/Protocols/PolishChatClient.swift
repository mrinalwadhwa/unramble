import Foundation

/// Send a system + user prompt to a chat model and return the reply.
///
/// Cloud and on-device clients conform to this protocol, allowing the
/// polish pipeline to use either backend without changing its orchestration.
public protocol PolishChatClient: Sendable {

    /// Complete a two-message prompt and return the assistant's reply.
    ///
    /// - Parameters:
    ///   - model: Model identifier. Cloud implementations use this to
    ///     select the model; on-device implementations may ignore it.
    ///   - systemPrompt: System message content.
    ///   - userPrompt: User message content.
    /// - Returns: The assistant's reply, trimmed of whitespace.
    func complete(
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String

    /// Complete a prompt at a given sampling temperature, used to resample a
    /// unit that failed a polish guard. The default ignores the temperature
    /// and reuses the greedy completion, so a client that does not sample
    /// simply repeats its answer.
    func complete(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double
    ) async throws -> String
}

public extension PolishChatClient {
    func complete(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double
    ) async throws -> String {
        try await complete(
            model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
    }
}
