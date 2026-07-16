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

private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { return nil }
        if count == 0 { break }
        body.append(contentsOf: buffer.prefix(count))
    }
    return body
}

private final class MutableString: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String

    init(_ value: String) {
        storedValue = value
    }

    var value: String {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class AuthorizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [String] {
        lock.withLock { values }
    }
}

private final class APIKeyAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var value: String {
        lock.withLock {
            reads += 1
            return "sk-test"
        }
    }

    var readCount: Int {
        lock.withLock { reads }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        lock.withLock { self.request = request }
    }

    var snapshot: URLRequest? {
        lock.withLock { request }
    }
}

// MARK: - Stubbed tests

@Suite("OpenAIFileTranscriber – stubbed")
struct OpenAIFileTranscriberStubbedTests {

    @Test("default session bounds the complete transcription resource")
    func defaultSessionTotalTimeout() {
        let configuration = OpenAIFileTranscriber.defaultSessionConfiguration()

        #expect(configuration.timeoutIntervalForRequest == 60)
        #expect(configuration.timeoutIntervalForResource == 60)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.urlCache == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test("POST to audio/transcriptions endpoint")
    func endpointURL() async throws {
        let recorder = RequestRecorder()
        let session = stubbedSession { request in
            recorder.record(request)
            let body = #"{"text":"hello world"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "sk-test",
            session: session)
        _ = try await provider.dictate(audio: silentWAV(), context: AppContext.empty)

        let request = try #require(recorder.snapshot)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
    }

    @Test("Bearer auth header from API key")
    func authHeader() async throws {
        let recorder = RequestRecorder()
        let session = stubbedSession { request in
            recorder.record(request)
            let body = #"{"text":"ok"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "sk-my-key",
            session: session)
        _ = try await provider.dictate(audio: silentWAV(), context: AppContext.empty)

        let request = try #require(recorder.snapshot)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-my-key")
    }

    @Test("Reads a replacement API key without rebuilding the provider")
    func refreshedAuthHeader() async throws {
        let apiKey = MutableString("sk-expired")
        let recorder = AuthorizationRecorder()
        let session = stubbedSession { request in
            recorder.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let body = #"{"text":"ok"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIFileTranscriber(
            apiKey: apiKey.value,
            session: session)

        _ = try await provider.dictate(audio: silentWAV(), context: .empty)
        apiKey.value = "sk-replacement"
        _ = try await provider.dictate(audio: silentWAV(), context: .empty)

        #expect(
            recorder.snapshot
                == ["Bearer sk-expired", "Bearer sk-replacement"])
    }

    @Test("multipart content type with boundary")
    func contentType() async throws {
        let recorder = RequestRecorder()
        let session = stubbedSession { request in
            recorder.record(request)
            let body = #"{"text":"ok"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)
        _ = try await provider.dictate(audio: silentWAV(), context: AppContext.empty)

        let request = try #require(recorder.snapshot)
        let ct = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
    }

    @Test("multipart body contains file and model fields")
    func bodyFields() {
        let audio = silentWAV()
        let body = OpenAIFileTranscriber.buildMultipartBody(
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

    @Test("configured language is sent with the transcription request")
    func languageField() async throws {
        let recorder = RequestRecorder()
        let session = stubbedSession { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"bonjour"}"#.utf8))
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)

        _ = try await provider.dictate(
            audio: silentWAV(), context: .empty, language: "fr")

        let request = try #require(recorder.snapshot)
        let body = try #require(requestBody(request))
        #expect(body.range(of: Data("name=\"language\"".utf8)) != nil)
        #expect(body.range(of: Data("\r\n\r\nfr\r\n".utf8)) != nil)
    }

    @Test("uses the explicit language for each request")
    func explicitLanguageField() async throws {
        let recorder = RequestRecorder()
        let session = stubbedSession { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"bonjour"}"#.utf8))
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)

        _ = try await provider.dictate(
            audio: silentWAV(), context: .empty, language: "fr")

        let request = try #require(recorder.snapshot)
        let body = try #require(requestBody(request))
        #expect(body.range(of: Data("\r\n\r\nfr\r\n".utf8)) != nil)
        #expect(body.range(of: Data("\r\n\r\nen\r\n".utf8)) == nil)
    }

    @Test("multipart body contains audio bytes")
    func bodyAudioBytes() {
        // Use a small audio payload with a recognizable marker.
        let marker: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let audio = Data(marker)
        let body = OpenAIFileTranscriber.buildMultipartBody(
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
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)
        await #expect(throws: DictationError.self) {
            try await provider.dictate(audio: Data(), context: AppContext.empty)
        }
    }

    @Test("24,999,999-byte audio reaches request construction")
    func audioImmediatelyBelowUploadLimitIsAccepted() async throws {
        let recorder = RequestRecorder()
        let session = stubbedSession { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"ok"}"#.utf8))
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "sk-test",
            session: session)

        _ = try await provider.dictate(
            audio: Data(count: 24_999_999), context: .empty)

        let request = try #require(recorder.snapshot)
        #expect(request.httpMethod == "POST")
        #expect(request.httpBodyStream != nil)
    }

    @Test("25,000,000-byte audio is rejected before multipart construction or network")
    func audioAtExclusiveUploadLimitIsRejectedBeforeRequestConstruction() async {
        let apiKey = APIKeyAccessRecorder()
        let session = stubbedSession { _ in
            Issue.record("network should not be called for oversized audio")
            throw URLError(.badServerResponse)
        }
        let provider = OpenAIFileTranscriber(
            apiKey: apiKey.value,
            session: session)

        do {
            _ = try await provider.dictate(
                audio: Data(count: 25_000_000), context: .empty)
            Issue.record("expected oversized-audio error")
        } catch let error as DictationError {
            #expect(
                error == .audioTooLarge(
                    maximumBytes: 24_999_999,
                    actualBytes: 25_000_000))
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        // The API key is read at the start of request construction, before the
        // multipart body is allocated. Zero reads proves transcribe was not entered.
        #expect(apiKey.readCount == 0)
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
        let provider = OpenAIFileTranscriber(
            apiKey: "bad",
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
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
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
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
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
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
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
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)
        await #expect(throws: DictationError.self) {
            try await provider.dictate(audio: silentWAV(), context: AppContext.empty)
        }
    }

    @Test("already-clean transcript passes through without LLM")
    func cleanTranscriptPassthrough() async throws {
        // Deterministic cleanup leaves an already-clean transcript unchanged.
        let session = stubbedSession { request in
            let body = #"{"text":"The deployment went smoothly."}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)
        let result = try await provider.dictate(
            audio: silentWAV(), context: AppContext.empty)
        #expect(result == "The deployment went smoothly.")
    }

    @Test("dictated punctuation receives deterministic cleanup")
    func dictatedPunctuationCleanup() async throws {
        // "hello comma world" -> "Hello, world" without another model call.
        let session = stubbedSession { request in
            let body = #"{"text":"hello comma world"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)
        let result = try await provider.dictate(
            audio: silentWAV(), context: AppContext.empty, language: "en")
        #expect(result == "Hello, world")
    }

    @Test("Auto-language fallback preserves words with English filler spellings")
    func autoLanguageTranscriptPreservation() async throws {
        let session = stubbedSession { request in
            let body = #"{"text":"um dez minutos no total"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)

        let result = try await provider.dictate(
            audio: silentWAV(), context: AppContext.empty, language: nil)

        #expect(result == "um dez minutos no total")
    }

    @Test("non-English fallback preserves words that resemble English fillers")
    func nonEnglishTranscriptPreservation() async throws {
        let session = stubbedSession { request in
            let body = #"{"text":"um zehn Uhr"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)

        let result = try await provider.dictate(
            audio: silentWAV(), context: AppContext.empty, language: "de")

        #expect(result == "um zehn Uhr")
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
        let provider = OpenAIFileTranscriber(
            apiKey: "k",
            session: session)
        let result = try await provider.dictate(
            audio: silentWAV(), context: AppContext.empty)
        #expect(result == "")
    }
}

// MARK: - Live integration (gated)

@Suite(
    "OpenAIFileTranscriber – live",
    .disabled(if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI"] != "1"))
struct OpenAIFileTranscriberLiveTests {

    private var apiKey: String {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    @Test("live: tone WAV returns a response (possibly empty transcript)")
    func liveTone() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let provider = OpenAIFileTranscriber(apiKey: apiKey)
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
        let provider = OpenAIFileTranscriber(apiKey: apiKey)
        _ = try await provider.dictate(
            audio: silentWAV(seconds: 0.5), context: AppContext.empty)
    }

}
