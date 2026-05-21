import Foundation
import Testing

@testable import FreeFlowKit

@Suite("LocalModelStreamingProvider")
struct LocalModelStreamingProviderTests {

    // MARK: - Helpers

    private func makeProvider(
        sttEngine: MockLocalSTTEngine = MockLocalSTTEngine(),
        polishClient: StreamingMockPolishClient? = nil
    ) -> (LocalModelStreamingProvider, MockLocalSTTEngine, StreamingMockPolishClient?) {
        let provider = LocalModelStreamingProvider(
            sttEngine: sttEngine,
            polishChatClient: polishClient)
        return (provider, sttEngine, polishClient)
    }

    /// Build a PCM chunk of the given byte count.
    private func makePCM(bytes: Int = 64) -> Data {
        Data(repeating: 0x42, count: bytes)
    }

    // MARK: - Audio accumulation

    @Test("Accumulates PCM chunks sent via sendAudio")
    func accumulatesAudio() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "accumulated"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 100))
        try await provider.sendAudio(makePCM(bytes: 200))
        _ = try await provider.finishStreaming()

        // Engine should receive a single WAV with all accumulated PCM.
        #expect(engine.transcribeCallCount == 1)
        let receivedWAV = engine.receivedAudio[0]
        // WAV header (44) + accumulated PCM (100 + 200 = 300).
        #expect(receivedWAV.count == WAVEncoder.headerSize + 300)
    }

    // MARK: - WAV encoding on finish

    @Test("Encodes accumulated PCM as WAV before transcribing")
    func encodesAsWAV() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "test"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 64))
        _ = try await provider.finishStreaming()

        let wav = engine.receivedAudio[0]
        // Verify RIFF header magic bytes.
        #expect(wav[0] == 0x52)  // R
        #expect(wav[1] == 0x49)  // I
        #expect(wav[2] == 0x46)  // F
        #expect(wav[3] == 0x46)  // F
    }

    // MARK: - Cancel clears buffer

    @Test("Cancel clears accumulated audio")
    func cancelClearsBuffer() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "should not appear"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 100))
        await provider.cancelStreaming()

        // Start a new session — buffer should be empty from the cancel.
        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        let result = try await provider.finishStreaming()

        // No audio to transcribe — should return empty.
        #expect(result == "")
        #expect(engine.transcribeCallCount == 0)
    }

    // MARK: - Empty buffer returns empty

    @Test("Returns empty string when no audio was sent")
    func emptyBufferReturnsEmpty() async throws {
        let engine = MockLocalSTTEngine()
        let (provider, _, _) = makeProvider(sttEngine: engine)

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        let result = try await provider.finishStreaming()

        #expect(result == "")
        #expect(engine.transcribeCallCount == 0)
    }

    // MARK: - uncommittedAudioDuration

    @Test("Reports uncommitted audio duration based on accumulated bytes")
    func uncommittedAudioDuration() async throws {
        let (provider, _, _) = makeProvider()

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        // 32,000 bytes = 1 second at 16 kHz, 16-bit mono.
        try await provider.sendAudio(makePCM(bytes: 32_000))

        let duration = provider.uncommittedAudioDuration
        #expect(duration >= 0.99 && duration <= 1.01)
    }

    // MARK: - Engine load on first use

    @Test("Loads engine on first streaming session")
    func loadsEngineOnFirstUse() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedIsReady = false
        engine.stubbedTranscription = "loaded"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)

        #expect(engine.loadCallCount == 1)
    }

    // MARK: - Polish integration

    @Test("Polishes transcription through pipeline")
    func polishesResult() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "hello world"
        let polishClient = StreamingMockPolishClient()
        polishClient.stubbedResult = "Hello, world."
        let (provider, _, _) = makeProvider(
            sttEngine: engine, polishClient: polishClient)

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 64))
        let result = try await provider.finishStreaming()

        #expect(result == "Hello, world.")
        #expect(polishClient.completeCallCount == 1)
    }

    // MARK: - Polish failure fallback

    @Test("Falls back to deterministic polish when client throws")
    func fallsBackOnPolishError() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "hello world"
        let polishClient = StreamingMockPolishClient()
        polishClient.stubbedError = LocalModelError.completionFailed("fail")
        let (provider, _, _) = makeProvider(
            sttEngine: engine, polishClient: polishClient)

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 64))
        let result = try await provider.finishStreaming()

        #expect(result == "Hello world")
    }
}

// MARK: - StreamingMockPolishClient

/// Minimal mock for PolishChatClient used by streaming provider tests.
private final class StreamingMockPolishClient: PolishChatClient, @unchecked Sendable {

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
