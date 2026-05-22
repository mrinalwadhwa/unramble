import Foundation
import Testing

@testable import FreeFlowKit

@Suite("MockBatchDictationProvider")
struct MockBatchDictationProviderTests {

    @Test("Default returns stubbed text")
    func defaultReturnsStubbedText() async throws {
        let provider = MockBatchDictationProvider(stubbedText: "hello world")
        let result = try await provider.dictate(
            audio: Data([0x01, 0x02]),
            context: .empty
        )
        #expect(result == "hello world")
        #expect(provider.dictateCallCount == 1)
    }

    @Test("Stubbed error is thrown")
    func stubbedErrorThrown() async {
        let provider = MockBatchDictationProvider()
        provider.stubbedError = DictationError.requestFailed(
            statusCode: 502, message: "bad gateway")

        do {
            _ = try await provider.dictate(audio: Data([0x01]), context: .empty)
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is DictationError)
        }
        #expect(provider.dictateCallCount == 1)
    }

    @Test("Records received audio and contexts")
    func recordsArguments() async throws {
        let provider = MockBatchDictationProvider()
        let context = AppContext(
            bundleID: "com.apple.mail",
            appName: "Mail",
            windowTitle: "New Message"
        )

        let audio1 = Data([0x01, 0x02])
        let audio2 = Data([0x03, 0x04])
        _ = try await provider.dictate(audio: audio1, context: .empty)
        _ = try await provider.dictate(audio: audio2, context: context)

        #expect(provider.dictateCallCount == 2)
        #expect(provider.receivedAudioData == [audio1, audio2])
        #expect(provider.lastReceivedAudio == audio2)
        #expect(provider.lastReceivedContext == context)
    }

    @Test("Reset clears all recorded state")
    func resetClearsState() async throws {
        let provider = MockBatchDictationProvider()
        _ = try await provider.dictate(audio: Data([0x01]), context: .empty)
        #expect(provider.dictateCallCount == 1)

        provider.reset()
        #expect(provider.dictateCallCount == 0)
        #expect(provider.receivedAudioData.isEmpty)
        #expect(provider.receivedContexts.isEmpty)
        #expect(provider.lastReceivedAudio == nil)
        #expect(provider.lastReceivedContext == nil)
    }

    @Test("Changing stubbedText between calls returns different results")
    func changingStubbedText() async throws {
        let provider = MockBatchDictationProvider(stubbedText: "first")
        var result = try await provider.dictate(audio: Data([0x01]), context: .empty)
        #expect(result == "first")

        provider.stubbedText = "second"
        result = try await provider.dictate(audio: Data([0x02]), context: .empty)
        #expect(result == "second")
        #expect(provider.dictateCallCount == 2)
    }
}

@Suite("Pipeline dictation")
struct PipelineDictationTests {

    private func makePipeline(
        audioProvider: MockAudioProvider = MockAudioProvider(),
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        batchProvider: MockBatchDictationProvider = MockBatchDictationProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        transcriptBuffer: TranscriptBuffer = TranscriptBuffer()
    ) -> (
        DictationPipeline, MockBatchDictationProvider, MockTextInjector,
        RecordingCoordinator, TranscriptBuffer
    ) {
        let pipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: contextProvider,
            batchProvider: batchProvider,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer
        )
        return (pipeline, batchProvider, textInjector, coordinator, transcriptBuffer)
    }

    @Test("Pipeline injects dictated text")
    func injectsDictatedText() async {
        let dictation = MockBatchDictationProvider(
            stubbedText: "I think we should meet tomorrow.")
        let (pipeline, _, injector, coordinator, _) = makePipeline(
            batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .idle)
        #expect(injector.lastInjectedText == "I think we should meet tomorrow.")
    }

    @Test("Buffer stores dictated text")
    func bufferStoresDictatedText() async {
        let dictation = MockBatchDictationProvider(stubbedText: "Stored text.")
        let (pipeline, _, _, _, buffer) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.consume()
        #expect(stored == "Stored text.")
    }

    @Test("Empty text skips injection")
    func emptyTextSkipsInjection() async {
        let dictation = MockBatchDictationProvider(stubbedText: "   ")
        let (pipeline, _, injector, coordinator, _) = makePipeline(
            batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .idle)
        #expect(injector.injectionCount == 0)
    }

    @Test("Dictation failure enters recovery state without injecting")
    func dictationFailureEntersRecovery() async {
        let dictation = MockBatchDictationProvider()
        dictation.stubbedError = DictationError.networkError("connection refused")
        let (pipeline, _, injector, coordinator, buffer) = makePipeline(
            batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .dictationFailed)
        #expect(injector.injectionCount == 0)
        let stored = await buffer.lastTranscript
        #expect(stored == nil)
    }

    @Test("Injection failure stores text for recovery")
    func injectionFailureStoresText() async {
        let dictation = MockBatchDictationProvider(stubbedText: "Test.")
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let (pipeline, _, _, coordinator, buffer) = makePipeline(
            batchProvider: dictation, textInjector: injector)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .injectionFailed)
        let stored = await buffer.consume()
        #expect(stored == "Test.")
    }
}
