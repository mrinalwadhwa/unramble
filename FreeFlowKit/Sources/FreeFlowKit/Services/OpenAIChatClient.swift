import Foundation

/// Call the OpenAI Chat Completions API.
///
/// Send a system prompt and user prompt to a chat model and return the
/// assistant's reply as a plain string. The client performs a single
/// non-streaming request and extracts the content from the first choice.
public struct OpenAIChatClient: PolishChatClient {

    /// Errors thrown by the chat client.
    public enum ChatError: Error, LocalizedError {
        case httpError(statusCode: Int, message: String?)
        case networkError(String)
        case invalidResponse
        case emptyContent

        public var errorDescription: String? {
            switch self {
            case .httpError(let status, let message):
                return "OpenAI chat error \(status): \(message ?? "no details")"
            case .networkError(let message):
                return "OpenAI chat network error: \(message)"
            case .invalidResponse:
                return "Invalid OpenAI chat response"
            case .emptyContent:
                return "OpenAI chat response contained no content"
            }
        }
    }

    private let apiKeyProvider: @Sendable () -> String
    private let session: URLSession
    private let endpoint: URL

    public init(
        apiKey: @autoclosure @escaping @Sendable () -> String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        session: URLSession? = nil
    ) {
        self.apiKeyProvider = apiKey
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            self.session = URLSession(
                configuration: Self.defaultSessionConfiguration())
        }
    }

    /// Bound both inactivity and total transfer time so batch transcription
    /// always leaves a finite polish stage inside the recovery reserve.
    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    /// Send a two-message chat completion and return the assistant's reply.
    ///
    /// - Parameters:
    ///   - model: Model identifier (e.g. `gpt-5.4-nano`).
    ///   - systemPrompt: System message content.
    ///   - userPrompt: User message content.
    /// - Returns: The assistant's reply, trimmed of leading/trailing whitespace.
    /// - Throws: `ChatError` on HTTP failure or malformed response.
    public func complete(
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKeyProvider())", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractErrorMessage(data)
            throw ChatError.httpError(statusCode: http.statusCode, message: message)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw ChatError.invalidResponse
        }
        guard let content = message["content"] as? String else {
            throw ChatError.emptyContent
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract an error message from an OpenAI error response body.
    static func extractErrorMessage(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return nil
        }
        return message
    }
}
