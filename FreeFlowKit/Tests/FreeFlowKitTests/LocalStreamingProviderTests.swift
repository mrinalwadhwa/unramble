import Foundation
import Testing

@testable import FreeFlowKit

@Suite("LocalStreamingProvider")
struct LocalStreamingProviderTests {

    // MARK: - Helpers

    private func makeProvider(
        sttEngine: MockLocalSTTEngine = MockLocalSTTEngine(),
        polishClient: StreamingMockPolishClient? = nil
    ) -> (LocalStreamingProvider, MockLocalSTTEngine, StreamingMockPolishClient?) {
        let provider = LocalStreamingProvider(
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

    // MARK: - Rolling injection

    @Test("Emits committed chunks live and returns only the tail")
    func rollingInjection() async throws {
        let engine = ProgressiveSTTEngine(results: [
            "Hi there.",
            "Hi there. This is a test.",
            "Hi there. This is a test. Almost done.",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            cycleInterval: 0.05)

        let collector = ChunkCollector()
        provider.setChunkHandler { text in await collector.append(text) }

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 32_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        try await provider.sendAudio(makePCM(bytes: 32_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        try await provider.sendAudio(makePCM(bytes: 32_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        // The pipeline clears the handler before finishing so late chunks
        // cannot inject during finishStreaming. The provider must still
        // return only the tail, not re-return the already-injected text.
        provider.setChunkHandler(nil)
        let tail = try await provider.finishStreaming()

        let chunks = await collector.all()

        // Rolling injection happened: at least one chunk was emitted.
        #expect(!chunks.isEmpty)
        // Chunks plus the returned tail reconstruct the full text, with
        // each sentence appearing exactly once (forward-only).
        let full = (chunks + [tail])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        #expect(full == "Hi there. This is a test. Almost done.")
        // The committed text is not re-returned from finishStreaming.
        #expect(!tail.contains("Hi there"))
    }

    // MARK: - Paragraph breaks

    @Test("A committed chunk carries a paragraph break")
    func paragraphBreakInChunk() async throws {
        let engine = ProgressiveSTTEngine(results: [
            "Alpha bravo.",
            "Alpha bravo. new paragraph charlie delta.",
            "Alpha bravo. new paragraph charlie delta. Echo foxtrot.",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: nil, cycleInterval: 0.05)

        let collector = ChunkCollector()
        provider.setChunkHandler { text in await collector.append(text) }

        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 32_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        try await provider.sendAudio(makePCM(bytes: 32_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        try await provider.sendAudio(makePCM(bytes: 32_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        provider.setChunkHandler(nil)
        let tail = try await provider.finishStreaming()

        let chunks = await collector.all()
        let all = (chunks + [tail]).joined(separator: "|")
        // "new paragraph" became a break, carried on a committed chunk,
        // with no stray space before it.
        #expect(all.contains("\n\n"),
            "a chunk should carry the paragraph break: \(all)")
        #expect(!all.contains(" \n\n"),
            "no stray space before the break: \(all)")
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

/// Collects chunks emitted through the streaming provider's chunk
/// handler for assertions.
private actor ChunkCollector {
    private var chunks: [String] = []
    func append(_ text: String) { chunks.append(text) }
    func all() -> [String] { chunks }
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

/// A polish client that echoes back its input unchanged.
/// Simulates a model that doesn't improve the text.
private final class EchoPolishClient: PolishChatClient, @unchecked Sendable {
    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        return userPrompt
    }
}

/// An STT engine that returns different results on successive calls.
/// Simulates Parakeet progressively transcribing more audio.
private final class ProgressiveSTTEngine: LocalSTTEngine, @unchecked Sendable {
    let name = "ProgressiveSTT"
    var isReady: Bool = true

    private let lock = NSLock()
    private var _callIndex = 0
    private let _results: [String]

    init(results: [String]) {
        self._results = results
    }

    func load() async throws {}
    func unload() async {}

    func transcribe(audio: Data) async throws -> String {
        lock.withLock {
            let idx = min(_callIndex, _results.count - 1)
            _callIndex += 1
            return _results[idx]
        }
    }
}

// MARK: - Preprocessing with sentence splitting

@Suite("LocalStreamingProvider – preprocessing")
struct LocalStreamingPreprocessingTests {

    private func makeProvider(
        sttResult: String
    ) -> (LocalStreamingProvider, MockLocalSTTEngine) {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = sttResult
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: nil)
        return (provider, engine)
    }

    private func makePCM(bytes: Int = 64) -> Data {
        Data(repeating: 0x42, count: bytes)
    }

    private func runPipeline(_ sttResult: String) async throws -> String {
        let (provider, _) = makeProvider(sttResult: sttResult)
        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 64))
        return try await provider.finishStreaming()
    }

    private func runPipelineWithEchoModel(_ sttResult: String) async throws -> String {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = sttResult
        let echoClient = EchoPolishClient()
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: echoClient)
        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 64))
        return try await provider.finishStreaming()
    }

    @Test("Filler um is stripped in finishStreaming output")
    func fillerUmStripped() async throws {
        let result = try await runPipeline(
            "Think about the key areas. Um for CTO roles and AI roles.")
        #expect(
            !result.contains("Um ") && !result.contains(" um "),
            "Filler 'um' should be stripped but got: \(result)")
    }

    @Test("Filler uh is stripped in finishStreaming output")
    func fillerUhStripped() async throws {
        let result = try await runPipeline(
            "I like the beginning of uh A but I want the product statement.")
        #expect(
            !result.contains(" uh "),
            "Filler 'uh' should be stripped but got: \(result)")
    }

    @Test("Trailing Mm-hmm is stripped in finishStreaming output")
    func trailingMmHmmStripped() async throws {
        let result = try await runPipeline(
            "We should add rate limiting to the API. Mm-hmm.")
        #expect(
            !result.contains("Mm-hmm"),
            "Trailing 'Mm-hmm' should be stripped but got: \(result)")
    }

    @Test("a.m./p.m. is preserved in finishStreaming output")
    func ampmPreserved() async throws {
        let result = try await runPipeline(
            "The meeting is at 3 p.m. in the large conference room.")
        #expect(
            result.contains("PM") || result.contains("p.m."),
            "a.m./p.m. should be preserved but got: \(result)")
        #expect(
            !result.contains("p.m in"),
            "a.m./p.m. period should not be stripped: \(result)")
    }

    @Test("Filler across background cache boundary is stripped")
    func fillerAcrossCacheBoundary() async throws {
        // Background cycle 1 sees: "Think about the key areas."
        // Background cycle 2 sees: "Think about the key areas. Um for CTO roles."
        // The "Um" starts a new sentence after the cache boundary.
        let engine = ProgressiveSTTEngine(results: [
            "Think about the key areas.",
            "Think about the key areas. Um for CTO roles and AI roles.",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            cycleInterval: 0.05)
        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 32_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        try await provider.sendAudio(makePCM(bytes: 32_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        let result = try await provider.finishStreaming()
        #expect(
            !result.contains("Um ") && !result.contains(" um "),
            "Filler should be stripped across cache boundary but got: \(result)")
    }

    @Test("Mid-sentence filler stripped in background polish")
    func midSentenceFillerInBackground() async throws {
        let engine = ProgressiveSTTEngine(results: [
            "I did all of those things, um but I think the details are too much.",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            cycleInterval: 0.05)
        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 32_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        let result = try await provider.finishStreaming()
        #expect(
            !result.contains(" um "),
            "Mid-sentence filler should be stripped but got: \(result)")
    }

    @Test("Filler stripped when echo model is used")
    func fillerStrippedWithEchoModel() async throws {
        // Echo model returns its input unchanged — fillers should
        // still be stripped by preprocessing before the model sees them.
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "I did all of those things, um but I think the details are too much."
        let echoClient = EchoPolishClient()
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: echoClient)
        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 64))
        let result = try await provider.finishStreaming()
        print("[TEST] Filler with echo model: \"\(result)\"")
        #expect(
            !result.contains(" um "),
            "Filler should be stripped before model sees it but got: \(result)")
    }

    @Test("Multiple fillers stripped with echo model")
    func multipleFillerWithEchoModel() async throws {
        let engine = MockLocalSTTEngine()
        engine.stubbedTranscription = "Read the first page of um autonomy docs. Um I think that gives us better vocabulary. Um The term is harness."
        let echoClient = EchoPolishClient()
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: echoClient)
        try await provider.startStreaming(
            context: .empty, language: nil, micProximity: .farField)
        try await provider.sendAudio(makePCM(bytes: 64))
        let result = try await provider.finishStreaming()
        print("[TEST] Multiple fillers with echo: \"\(result)\"")
        #expect(
            !result.lowercased().contains(" um ") && !result.contains("Um "),
            "All fillers should be stripped but got: \(result)")
    }

}
