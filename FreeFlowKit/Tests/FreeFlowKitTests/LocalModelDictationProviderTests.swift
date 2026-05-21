import Foundation
import Testing

@testable import FreeFlowKit

@Suite("LocalModelDictationProvider")
struct LocalModelDictationProviderTests {

    // MARK: - Helpers

    /// Build a minimal WAV with a 44-byte header + PCM data.
    private func makeWAV(pcmBytes: Int = 100) -> Data {
        let pcm = Data(repeating: 0x42, count: pcmBytes)
        return WAVEncoder.encode(
            pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16)
    }

    private func makeProvider(
        sttEngine: MockLocalSTTEngine = MockLocalSTTEngine(),
        polishClient: MockPolishChatClient? = nil
    ) -> (LocalModelDictationProvider, MockLocalSTTEngine, MockPolishChatClient?) {
        let provider = LocalModelDictationProvider(
            sttEngine: sttEngine,
            polishChatClient: polishClient)
        return (provider, sttEngine, polishClient)
    }

    // MARK: - Empty audio

    @Test("Throws emptyAudio for data with only WAV header")
    func throwsOnEmptyAudio() async {
        let (provider, _, _) = makeProvider()
        // 44-byte WAV header with no PCM data.
        let headerOnly = Data(repeating: 0, count: 44)

        await #expect(throws: DictationError.self) {
            try await provider.dictate(audio: headerOnly, context: .empty)
        }
    }

    @Test("Throws emptyAudio for data shorter than WAV header")
    func throwsOnShortAudio() async {
        let (provider, _, _) = makeProvider()

        await #expect(throws: DictationError.self) {
            try await provider.dictate(audio: Data(repeating: 0, count: 10), context: .empty)
        }
    }

    // MARK: - Engine load on first use

    @Test("Loads engine on first dictation when not ready")
    func loadsEngineOnFirstUse() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedIsReady = false
        engine.stubbedTranscription = "hello"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        _ = try await provider.dictate(audio: makeWAV(), context: .empty)

        #expect(engine.loadCallCount == 1)
        #expect(engine.transcribeCallCount == 1)
    }

    @Test("Skips load when engine is already ready")
    func skipsLoadWhenReady() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedIsReady = true
        engine.stubbedTranscription = "hello"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        _ = try await provider.dictate(audio: makeWAV(), context: .empty)

        #expect(engine.loadCallCount == 0)
        #expect(engine.transcribeCallCount == 1)
    }

    // MARK: - Basic transcription

    @Test("Returns transcription when no polish client")
    func returnsRawTranscription() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "hello world"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        let result = try await provider.dictate(audio: makeWAV(), context: .empty)

        #expect(result == "Hello world")  // normalizeFormatting capitalizes
    }

    @Test("Returns empty string for empty transcription")
    func returnsEmptyForEmptyTranscription() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "   "
        let (provider, _, _) = makeProvider(sttEngine: engine)

        let result = try await provider.dictate(audio: makeWAV(), context: .empty)

        #expect(result == "")
    }

    @Test("Passes WAV data to engine")
    func passesAudioToEngine() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "test"
        let (provider, _, _) = makeProvider(sttEngine: engine)
        let wav = makeWAV(pcmBytes: 200)

        _ = try await provider.dictate(audio: wav, context: .empty)

        #expect(engine.receivedAudio.count == 1)
        #expect(engine.receivedAudio[0] == wav)
    }

    // MARK: - Polish pipeline integration

    @Test("Polishes transcription with client when available")
    func polishesWithClient() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "hello world"
        let polishClient = MockPolishChatClient()
        polishClient.stubbedResult = "Hello, world."
        let (provider, _, _) = makeProvider(
            sttEngine: engine, polishClient: polishClient)

        let result = try await provider.dictate(audio: makeWAV(), context: .empty)

        #expect(result == "Hello, world.")
        #expect(polishClient.completeCallCount == 1)
    }

    // MARK: - Polish failure fallback

    @Test("Falls back to deterministic polish when client throws")
    func fallsBackOnPolishError() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "hello world"
        let polishClient = MockPolishChatClient()
        polishClient.stubbedError = LocalModelError.completionFailed("timeout")
        let (provider, _, _) = makeProvider(
            sttEngine: engine, polishClient: polishClient)

        let result = try await provider.dictate(audio: makeWAV(), context: .empty)

        // Falls back to normalizeFormatting of the stripped text.
        #expect(result == "Hello world")
    }

    @Test("Falls back to deterministic polish when client returns empty")
    func fallsBackOnEmptyPolish() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "hello world"
        let polishClient = MockPolishChatClient()
        polishClient.stubbedResult = ""
        let (provider, _, _) = makeProvider(
            sttEngine: engine, polishClient: polishClient)

        let result = try await provider.dictate(audio: makeWAV(), context: .empty)

        #expect(result == "Hello world")
    }

    // MARK: - Engine errors

    @Test("Propagates engine transcription errors")
    func propagatesEngineErrors() async {
        let engine = MockLocalSTTEngine()
        engine.stubbedError = LocalModelError.transcriptionFailed("bad audio")
        let (provider, _, _) = makeProvider(sttEngine: engine)

        await #expect(throws: LocalModelError.self) {
            try await provider.dictate(audio: makeWAV(), context: .empty)
        }
    }
}

// MARK: - MockPolishChatClient

/// Minimal mock for PolishChatClient used by these tests.
private final class MockPolishChatClient: PolishChatClient, @unchecked Sendable {

    private let lock = NSLock()
    private var _completeCallCount = 0

    var stubbedResult = ""
    var stubbedError: (any Error)?

    var completeCallCount: Int {
        lock.withLock { _completeCallCount }
    }

    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        lock.withLock { _completeCallCount += 1 }
        if let error = stubbedError { throw error }
        return stubbedResult
    }
}
