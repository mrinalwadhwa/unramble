import Foundation

/// Exact-WAV fallback that calls OpenAI's audio transcription endpoint.
///
/// Send a complete WAV file to the `/v1/audio/transcriptions` endpoint,
/// receive the raw transcript, then apply deterministic English punctuation
/// and formatting cleanup. Other languages pass through unchanged after
/// trimming so English-specific rules cannot delete valid words. The fallback
/// deliberately has no second model-polish request: Realtime remains the only
/// cloud polish architecture.
public struct OpenAIFileTranscriber: BatchDictationProviding {

    /// OpenAI requires transcription uploads to be strictly smaller than 25 MB.
    static let maximumAudioBytes = 24_999_999

    private let apiKeyProvider: @Sendable () -> String
    private let model: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: @autoclosure @escaping @Sendable () -> String,
        model: String = "gpt-4o-mini-transcribe",
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        session: URLSession? = nil
    ) {
        self.apiKeyProvider = apiKey
        self.model = model
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            self.session = URLSession(
                configuration: Self.defaultSessionConfiguration())
        }
    }

    /// Bound both inactivity and total transfer time so the pipeline's cloud
    /// recovery reserve cannot be consumed indefinitely by a trickling body.
    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    // MARK: - BatchDictationProviding

    public func dictate(
        audio: Data,
        context: AppContext,
        language: String?
    ) async throws -> String {
        guard !audio.isEmpty else {
            throw DictationError.emptyAudio
        }
        guard audio.count <= Self.maximumAudioBytes else {
            throw DictationError.audioTooLarge(
                maximumBytes: Self.maximumAudioBytes,
                actualBytes: audio.count)
        }

        let configuredLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let language = configuredLanguage?.isEmpty == false
            ? configuredLanguage : nil
        let rawTranscript = try await transcribe(
            audio: audio, language: language)
        try Task.checkCancellation()
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }

        return Self.cleanUp(trimmed, context: context, language: language)
    }

    // MARK: - Transcription

    private func transcribe(audio: Data, language: String?) async throws -> String {
        let boundary = "FreeFlowKit-" + UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKeyProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = Self.buildMultipartBody(
            audio: audio, model: model, language: language, boundary: boundary)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DictationError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DictationError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            return try parseTranscript(from: data)
        case 401:
            throw DictationError.authenticationFailed
        case 429:
            throw DictationError.rateLimited
        default:
            let message =
                Self.extractErrorMessage(data)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw DictationError.requestFailed(
                statusCode: http.statusCode, message: message)
        }
    }

    /// Build the multipart/form-data transcription request body.
    static func buildMultipartBody(
        audio: Data,
        model: String,
        language: String? = nil,
        boundary: String
    ) -> Data {
        let crlf = "\r\n"
        var body = Data()

        // Audio file field.
        body.appendString("--\(boundary)\(crlf)")
        body.appendString(
            "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\(crlf)")
        body.appendString("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(audio)
        body.appendString(crlf)

        // Model field.
        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)")
        body.appendString("\(model)\(crlf)")

        // Response format field — request plain JSON with a `text` key.
        body.appendString("--\(boundary)\(crlf)")
        body.appendString(
            "Content-Disposition: form-data; name=\"response_format\"\(crlf)\(crlf)")
        body.appendString("json\(crlf)")

        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
            !language.isEmpty
        {
            body.appendString("--\(boundary)\(crlf)")
            body.appendString(
                "Content-Disposition: form-data; name=\"language\"\(crlf)\(crlf)")
            body.appendString("\(language)\(crlf)")
        }

        // Closing boundary.
        body.appendString("--\(boundary)--\(crlf)")

        return body
    }

    /// Extract the `text` field from a successful transcription response.
    private func parseTranscript(from data: Data) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw DictationError.invalidResponse
        }
        return text
    }

    private static func extractErrorMessage(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return nil
        }
        return message
    }

    /// Apply only deterministic cleanup to degraded fallback output.
    private static func cleanUp(
        _ raw: String, context: AppContext, language: String?
    ) -> String {
        guard language == "en" else {
            return raw
        }
        let casual = PolishPipeline.toneLabel(for: context.bundleID) == "casual"
        let substituted = PolishPipeline.substituteDictatedPunctuation(
            raw, casual: casual,
            precedingText: context.focusedFieldContent)
        let stripped = PolishPipeline.stripKeepTags(
            substituted, casual: casual)
        return PolishPipeline.normalizeFormatting(stripped, casual: casual)
    }
}

// MARK: - Data helper

extension Data {
    fileprivate mutating func appendString(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            assertionFailure("UTF-8 encoding failed for valid String")
            return
        }
        append(data)
    }
}
