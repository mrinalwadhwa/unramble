import Foundation
import Testing

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Stubbed unit tests verify multipart request construction and error mapping
// without hitting the network. Live tests (gated by FREEFLOW_TEST_OPENAI=1)
// call the real OpenAI transcriptions endpoint with a short silent WAV.
// ---------------------------------------------------------------------------

// MARK: - Helpers

/// Build a short silent mono 16-bit WAV for test transcription requests.
private func silentWAV(seconds: Double = 0.5, sampleRate: Int = 16000) -> Data {
    let sampleCount = Int(seconds * Double(sampleRate))
    let pcm = Data(count: sampleCount * 2)  // 16-bit mono
    return WAVEncoder.encode(
        pcmData: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
}

/// Build a WAV containing a 1 kHz tone for live transcription tests.
private func toneWAV(seconds: Double = 1.0, sampleRate: Int = 16000) -> Data {
    let sampleCount = Int(seconds * Double(sampleRate))
    var pcm = Data(capacity: sampleCount * 2)
    for i in 0..<sampleCount {
        let t = Double(i) / Double(sampleRate)
        let value = Int16(3000.0 * sin(2.0 * .pi * 1000.0 * t))
        pcm.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }
    return WAVEncoder.encode(
        pcmData: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
}

private actor BatchPolishSpy: PolishChatClient {
    private(set) var models: [String] = []

    func complete(
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        models.append(model)
        return "polished fallback."
    }
}

// MARK: - Stubbed tests

@Suite("OpenAIBatchProvider – stubbed")
struct OpenAIBatchProviderStubbedTests {

    @Test("POST to audio/transcriptions endpoint")
    func endpointURL() async throws {
        var capturedRequest: URLRequest?
        let session = stubbedSession { request in
            capturedRequest = request
            let body = #"{"text":"hello world"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "sk-test",
            polishChatClient: nil,
            session: session)
        _ = try await provider.dictate(audio: silentWAV(), context: AppContext.empty)

        let request = try #require(capturedRequest)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
    }

    @Test("Bearer auth header from API key")
    func authHeader() async throws {
        var capturedRequest: URLRequest?
        let session = stubbedSession { request in
            capturedRequest = request
            let body = #"{"text":"ok"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "sk-my-key",
            polishChatClient: nil,
            session: session)
        _ = try await provider.dictate(audio: silentWAV(), context: AppContext.empty)

        let request = try #require(capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-my-key")
    }

    @Test("multipart content type with boundary")
    func contentType() async throws {
        var capturedRequest: URLRequest?
        let session = stubbedSession { request in
            capturedRequest = request
            let body = #"{"text":"ok"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: nil,
            session: session)
        _ = try await provider.dictate(audio: silentWAV(), context: AppContext.empty)

        let request = try #require(capturedRequest)
        let ct = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
    }

    @Test("multipart body contains file and model fields")
    func bodyFields() {
        let audio = silentWAV()
        let body = OpenAIBatchProvider.buildMultipartBody(
            audio: audio,
            model: "gpt-4o-mini-transcribe",
            boundary: "BOUNDARY")
        // Body contains binary WAV data with null bytes; search as bytes
        // instead of converting the whole thing to a UTF-8 string.
        func contains(_ s: String) -> Bool {
            body.range(of: s.data(using: .utf8)!) != nil
        }
        #expect(contains("--BOUNDARY"))
        #expect(contains("name=\"file\""))
        #expect(contains("filename=\"recording.wav\""))
        #expect(contains("Content-Type: audio/wav"))
        #expect(contains("name=\"model\""))
        #expect(contains("gpt-4o-mini-transcribe"))
        #expect(contains("name=\"response_format\""))
        #expect(contains("--BOUNDARY--\r\n"))
    }

    @Test("multipart body contains audio bytes")
    func bodyAudioBytes() {
        // Use a small audio payload with a recognizable marker.
        let marker: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let audio = Data(marker)
        let body = OpenAIBatchProvider.buildMultipartBody(
            audio: audio,
            model: "m",
            boundary: "B")
        // Verify the raw bytes appear somewhere in the body.
        let found = body.range(of: Data(marker))
        #expect(found != nil)
    }

    @Test("empty audio throws without calling network")
    func emptyAudio() async {
        let session = stubbedSession { _ in
            Issue.record("network should not be called for empty audio")
            throw URLError(.badServerResponse)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: nil,
            session: session)
        await #expect(throws: DictationError.self) {
            try await provider.dictate(audio: Data(), context: AppContext.empty)
        }
    }

    @Test("401 maps to authenticationFailed")
    func unauthorized() async {
        let session = stubbedSession { request in
            let body = #"{"error":{"message":"bad key"}}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "bad",
            polishChatClient: nil,
            session: session)
        await #expect(throws: DictationError.authenticationFailed) {
            try await provider.dictate(audio: silentWAV(), context: AppContext.empty)
        }
    }

    @Test("500 maps to requestFailed with detail")
    func serverError() async throws {
        let session = stubbedSession { request in
            let body = #"{"error":{"message":"boom"}}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: nil,
            session: session)
        do {
            _ = try await provider.dictate(audio: silentWAV(), context: AppContext.empty)
            Issue.record("expected error")
        } catch DictationError.requestFailed(let status, let message) {
            #expect(status == 500)
            #expect(message.contains("boom"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("429 maps to rateLimited")
    func rateLimited() async throws {
        let session = stubbedSession { request in
            let body = #"{"error":{"message":"rate limit exceeded"}}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: nil,
            session: session)
        do {
            _ = try await provider.dictate(audio: silentWAV(), context: AppContext.empty)
            Issue.record("expected error")
        } catch DictationError.rateLimited {
            // Expected.
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("malformed 200 response maps to invalidResponse")
    func malformedResponse() async {
        let session = stubbedSession { request in
            let body = #"not json at all"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: nil,
            session: session)
        await #expect(throws: DictationError.self) {
            try await provider.dictate(audio: silentWAV(), context: AppContext.empty)
        }
    }

    @Test("200 with missing text field maps to invalidResponse")
    func missingTextField() async {
        let session = stubbedSession { request in
            let body = #"{"result":"no text key here"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: nil,
            session: session)
        await #expect(throws: DictationError.self) {
            try await provider.dictate(audio: silentWAV(), context: AppContext.empty)
        }
    }

    @Test("already-clean transcript passes through without LLM")
    func cleanTranscriptPassthrough() async throws {
        // When polish client is nil AND the transcript is already clean,
        // the regex preprocessing runs (may capitalize first letter) and
        // the skip heuristic returns the result unchanged.
        let session = stubbedSession { request in
            let body = #"{"text":"The deployment went smoothly."}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: nil,
            session: session)
        let result = try await provider.dictate(
            audio: silentWAV(), context: AppContext.empty)
        #expect(result == "The deployment went smoothly.")
    }

    @Test("batch fallback retains chat polish")
    func batchFallbackPolish() async throws {
        let session = stubbedSession { request in
            let body = #"{"text":"Um this needs cleanup"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let polish = BatchPolishSpy()
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: polish,
            polishModel: "batch-polish-model",
            session: session)

        let result = try await provider.dictate(
            audio: silentWAV(), context: .empty)

        #expect(result == "polished fallback.")
        #expect(await polish.models == ["batch-polish-model"])
    }

    @Test("dictated punctuation substituted when polish client is nil")
    func dictatedPunctuationWithoutLLM() async throws {
        // "hello comma world" → "Hello, world" via regex substitution
        // even without LLM.
        let session = stubbedSession { request in
            let body = #"{"text":"hello comma world"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: nil,
            session: session)
        let result = try await provider.dictate(
            audio: silentWAV(), context: AppContext.empty)
        #expect(result == "Hello, world")
    }

    @Test("empty transcript returns empty string")
    func emptyTranscriptResponse() async throws {
        let session = stubbedSession { request in
            let body = #"{"text":""}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIBatchProvider(
            apiKey: "k",
            polishChatClient: nil,
            session: session)
        let result = try await provider.dictate(
            audio: silentWAV(), context: AppContext.empty)
        #expect(result == "")
    }
}

// MARK: - Live integration (gated)

@Suite(
    "OpenAIBatchProvider – live",
    .disabled(if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI"] != "1"))
struct OpenAIBatchProviderLiveTests {

    private var apiKey: String {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    @Test("live: tone WAV returns a response (possibly empty transcript)")
    func liveTone() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let provider = OpenAIBatchProvider(
            apiKey: apiKey, polishChatClient: nil)
        // A 1 kHz tone is not speech, so the transcript will likely be empty
        // or a short placeholder. We just verify the call succeeds.
        _ = try await provider.dictate(audio: toneWAV(), context: AppContext.empty)
    }

    @Test("live: short silent WAV handled")
    func liveSilent() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let provider = OpenAIBatchProvider(
            apiKey: apiKey, polishChatClient: nil)
        _ = try await provider.dictate(
            audio: silentWAV(seconds: 0.5), context: AppContext.empty)
    }

    @Test("live: batch dictate with polish pipeline")
    func liveWithPolish() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let polish = OpenAIChatClient(apiKey: apiKey)
        let provider = OpenAIBatchProvider(
            apiKey: apiKey, polishChatClient: polish)
        // Silent audio should produce an empty transcript → polish returns ""
        let result = try await provider.dictate(
            audio: silentWAV(), context: AppContext.empty)
        // Just assert the call completes without throwing.
        _ = result
    }
}
