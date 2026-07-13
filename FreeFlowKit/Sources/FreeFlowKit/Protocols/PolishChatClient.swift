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
}
