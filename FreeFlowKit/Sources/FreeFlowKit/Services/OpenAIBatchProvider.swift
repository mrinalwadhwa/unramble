import Foundation

/// Dictation provider that calls OpenAI's audio transcription endpoint
/// and optionally runs the local polish pipeline on the result.
///
/// Send a complete WAV file to the `/v1/audio/transcriptions` endpoint,
/// receive the raw transcript, then run it through `PolishPipeline` for
/// regex substitution, skip-heuristic, and (if a chat client is provided)
/// LLM refinement. When no polish chat client is provided, the raw
/// transcript is returned after regex preprocessing only.
public struct OpenAIBatchProvider: BatchDictationProviding {

    private let apiKeyProvider: @Sendable () -> String
    private let model: String
    private let endpoint: URL
    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String
    private let session: URLSession

    /// Language code for polish prompt selection (e.g. "en", "fr").
    public var language: String?

    public init(
        apiKey: @autoclosure @escaping @Sendable () -> String,
        model: String = "gpt-4o-mini-transcribe",
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        polishChatClient: (any PolishChatClient)?,
        polishModel: String = PolishPipeline.polishModel,
        session: URLSession? = nil
    ) {
        self.apiKeyProvider = apiKey
        self.model = model
        self.endpoint = endpoint
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - BatchDictationProviding

    public func dictate(audio: Data, context: AppContext) async throws -> String {
        guard !audio.isEmpty else {
            throw DictationError.emptyAudio
        }

        let rawTranscript = try await transcribe(audio: audio)
        try Task.checkCancellation()
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }

        return await polish(trimmed, context: context)
    }

    // MARK: - Transcription

    private func transcribe(audio: Data) async throws -> String {
        let boundary = "FreeFlowKit-" + UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKeyProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = Self.buildMultipartBody(
            audio: audio, model: model, boundary: boundary)

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
                OpenAIChatClient.extractErrorMessage(data)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw DictationError.requestFailed(
                statusCode: http.statusCode, message: message)
        }
    }

    /// Build a multipart/form-data body containing the audio file and model field.
    static func buildMultipartBody(
        audio: Data, model: String, boundary: String
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

    // MARK: - Polishing

    /// Run the polish pipeline on the raw transcript.
    ///
    /// Deterministic preprocessing always runs. LLM polish only runs
    /// when a chat client is configured. LLM failures fall back to the
    /// preprocessed text.
    private func polish(_ raw: String, context: AppContext) async -> String {
        let casual = PolishPipeline.toneLabel(for: context.bundleID) == "casual"
        let substituted = PolishPipeline.substituteDictatedPunctuation(
            raw, casual: casual,
            precedingText: context.focusedFieldContent)
        let stripped = PolishPipeline.stripKeepTags(
            substituted, casual: casual)

        guard let polishChatClient else {
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }

        let systemPrompt = PolishPipeline.buildCloudSystemPrompt(
            context: context, language: language)
        let userPrompt = PolishPipeline.buildUserPrompt(
            substituted, context: context, language: language)

        do {
            let polished = try await polishChatClient.complete(
                model: polishModel,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt)
            if polished.isEmpty {
                return PolishPipeline.normalizeFormatting(
                    stripped, casual: casual)
            }
            let untagged = PolishPipeline.stripKeepTags(
                polished, casual: casual)
            let normalized = PolishPipeline.normalizeFormatting(
                untagged, casual: casual)
            return PolishPipeline.matchInputCasing(
                normalized, preprocessedInput: substituted,
                casual: casual)
        } catch {
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }
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
