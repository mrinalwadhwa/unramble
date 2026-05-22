import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Pipeline integration with mocks")
struct PipelineIntegrationTests {

    @Test("Full mock pipeline: read context then inject")
    func mockPipelineFlow() async throws {
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.Notes",
                appName: "Notes",
                windowTitle: "My Note",
                focusedFieldContent: "Dear team,",
                cursorPosition: 10
            )
        )
        let injector = MockTextInjector()
        let audioProvider = MockAudioProvider()

        // Simulate hotkey press: start recording + read context.
        try await audioProvider.startRecording()
        let context = await contextProvider.readContext()

        #expect(audioProvider.isRecording)
        #expect(context.bundleID == "com.apple.Notes")
        #expect(context.focusedFieldContent == "Dear team,")

        // Simulate hotkey release: stop recording + inject.
        let buffer = try await audioProvider.stopRecording()
        #expect(!audioProvider.isRecording)
        #expect(buffer.duration == 1.0)

        // Simulate STT result and inject.
        let transcribedText = "I wanted to follow up on our discussion."
        try await injector.inject(text: transcribedText, into: context)

        #expect(injector.injectionCount == 1)
        #expect(injector.lastInjectedText == transcribedText)
        #expect(injector.injections[0].context.windowTitle == "My Note")
    }

    @Test("Mock pipeline handles multiple recording cycles")
    func multipleCycles() async throws {
        let contextProvider = MockAppContextProvider()
        let injector = MockTextInjector()
        let audioProvider = MockAudioProvider()

        for i in 1...3 {
            try await audioProvider.startRecording()
            _ = await contextProvider.readContext()
            _ = try await audioProvider.stopRecording()
            try await injector.inject(text: "Text \(i)", into: .stub)
        }

        #expect(audioProvider.startCallCount == 3)
        #expect(audioProvider.stopCallCount == 3)
        #expect(contextProvider.readContextCallCount == 3)
        #expect(injector.injectionCount == 3)
    }

    @Test("Mock pipeline with browser context includes URL")
    func browserPipeline() async throws {
        let browserContext = AppContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "GitHub",
            browserURL: "https://github.com",
            focusedFieldContent: "",
            cursorPosition: 0
        )
        let contextProvider = MockAppContextProvider(context: browserContext)
        let injector = MockTextInjector()

        let context = await contextProvider.readContext()
        #expect(context.browserURL == "https://github.com")

        try await injector.inject(text: "search query", into: context)
        #expect(injector.injections[0].context.browserURL == "https://github.com")
    }

    @Test("Context read and audio capture run concurrently")
    func concurrentContextAndAudio() async throws {
        let audioProvider = MockAudioProvider()
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.mail",
                appName: "Mail",
                windowTitle: "New Message",
                focusedFieldContent: "Dear ",
                cursorPosition: 5
            )
        )

        try await audioProvider.startRecording()

        async let contextRead = contextProvider.readContext()

        let context = await contextRead
        let buffer = try await audioProvider.stopRecording()

        #expect(context.bundleID == "com.apple.mail")
        #expect(buffer.duration > 0)
        #expect(audioProvider.startCallCount == 1)
        #expect(audioProvider.stopCallCount == 1)
        #expect(contextProvider.readContextCallCount == 1)
    }

    @Test("Pipeline handles context with no focused field")
    func pipelineNoFocusedField() async throws {
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.finder",
                appName: "Finder",
                windowTitle: "Documents"
            )
        )
        let injector = MockTextInjector()

        let context = await contextProvider.readContext()

        #expect(context.focusedFieldContent == nil)
        #expect(context.cursorPosition == nil)

        try await injector.inject(text: "some text", into: context)
        #expect(injector.injectionCount == 1)
    }

    @Test("Hotkey provider drives the full pipeline via press and release")
    func hotkeyDrivesPipeline() async throws {
        let hotkeyProvider = MockHotkeyProvider()
        let audioProvider = MockAudioProvider()
        let contextProvider = MockAppContextProvider()
        let injector = MockTextInjector()

        nonisolated(unsafe) var pipelineCompleted = false

        try hotkeyProvider.register { event in
            Task {
                switch event {
                case .pressed:
                    try await audioProvider.startRecording()
                    _ = await contextProvider.readContext()
                case .released:
                    _ = try await audioProvider.stopRecording()
                    try await injector.inject(text: "result", into: .stub)
                    pipelineCompleted = true

                }
            }
        }

        hotkeyProvider.simulatePress()
        try await Task.sleep(nanoseconds: 200_000_000)

        hotkeyProvider.simulateRelease()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(audioProvider.startCallCount == 1)
        #expect(audioProvider.stopCallCount == 1)
        #expect(injector.injectionCount == 1)
        #expect(pipelineCompleted)

        hotkeyProvider.unregister()
    }
}

@Suite("DictationPipeline integration")
struct DictationPipelineIntegrationTests {

    private func makePipeline(
        audioProvider: MockAudioProvider = MockAudioProvider(),
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        batchProvider: MockBatchDictationProvider = MockBatchDictationProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator()
    ) -> (
        DictationPipeline, MockAudioProvider, MockAppContextProvider, MockBatchDictationProvider,
        MockTextInjector, RecordingCoordinator
    ) {
        let pipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: contextProvider,
            batchProvider: batchProvider,
            textInjector: textInjector,
            coordinator: coordinator
        )
        return (
            pipeline, audioProvider, contextProvider, batchProvider, textInjector, coordinator
        )
    }

    @Test("Full cycle transcribes audio and injects text")
    func fullCycleTranscribes() async {
        let dictation = MockBatchDictationProvider(stubbedText: "Hello world")
        let (pipeline, _, _, _, injector, coordinator) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        let recording = await coordinator.state
        #expect(recording == .recording)

        await pipeline.complete()
        let idle = await coordinator.state
        #expect(idle == .idle)

        #expect(dictation.dictateCallCount == 1)
        #expect(injector.injectionCount == 1)
        #expect(injector.lastInjectedText == "Hello world")
    }

    @Test("Dictation receives audio data captured by the provider")
    func dictationReceivesAudioData() async {
        let dictation = MockBatchDictationProvider(stubbedText: "test")
        let (pipeline, _, _, _, _, _) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        #expect(dictation.dictateCallCount == 1)
        #expect(dictation.lastReceivedAudio != nil)
        #expect(dictation.lastReceivedAudio!.isEmpty == false)
    }

    @Test("Dictation failure enters recovery state")
    func dictationFailureEntersRecovery() async {
        let dictation = MockBatchDictationProvider()
        dictation.stubbedError = DictationError.requestFailed(
            statusCode: 502, message: "bad gateway")
        let (pipeline, _, _, _, injector, coordinator) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .dictationFailed)
        #expect(injector.injectionCount == 0)
    }

    @Test("Empty dictation result skips injection")
    func emptyDictationSkipsInjection() async {
        let dictation = MockBatchDictationProvider(stubbedText: "   ")
        let (pipeline, _, _, _, injector, coordinator) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .idle)
        #expect(dictation.dictateCallCount == 1)
        #expect(injector.injectionCount == 0)
    }

    @Test("Context is passed to text injector")
    func contextPassedToInjector() async {
        let ctx = AppContext(
            bundleID: "com.apple.Notes",
            appName: "Notes",
            windowTitle: "My Note",
            focusedFieldContent: "Dear team,",
            cursorPosition: 10
        )
        let dictation = MockBatchDictationProvider(stubbedText: "transcribed text")
        let (pipeline, _, _, _, injector, _) = makePipeline(
            contextProvider: MockAppContextProvider(context: ctx),
            batchProvider: dictation
        )

        await pipeline.activate()
        await pipeline.complete()

        #expect(injector.injectionCount == 1)
        #expect(injector.injections[0].context.bundleID == "com.apple.Notes")
        #expect(injector.injections[0].context.windowTitle == "My Note")
    }

    @Test("Cancel during recording skips dictation")
    func cancelDuringRecordingSkipsDictation() async {
        let dictation = MockBatchDictationProvider(stubbedText: "should not appear")
        let (pipeline, _, _, _, injector, coordinator) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        let recording = await coordinator.state
        #expect(recording == .recording)

        await pipeline.cancel()
        let state = await coordinator.state
        #expect(state == .idle)
        #expect(dictation.dictateCallCount == 0)
        #expect(injector.injectionCount == 0)
    }

    @Test("Multiple cycles with different transcriptions")
    func multipleCyclesWithDifferentTranscriptions() async {
        let dictation = MockBatchDictationProvider(stubbedText: "first")
        let (pipeline, _, _, _, injector, _) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()
        #expect(injector.lastInjectedText == "first")

        dictation.stubbedText = "second"
        await pipeline.activate()
        await pipeline.complete()
        #expect(injector.lastInjectedText == "second")

        dictation.stubbedText = "third"
        await pipeline.activate()
        await pipeline.complete()
        #expect(injector.lastInjectedText == "third")

        #expect(dictation.dictateCallCount == 3)
        #expect(injector.injectionCount == 3)
    }
}

@Suite("Timeout helper")
struct TimeoutHelperTests {

    @Test("Return value when operation completes in time")
    func completesInTime() async {
        let result = await withTimeout(seconds: 1.0) {
            return 42
        }
        #expect(result == 42)
    }

    @Test("Return nil when operation exceeds deadline")
    func exceedsDeadline() async {
        let result = await withTimeout(seconds: 0.01) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return 42
        }
        #expect(result == nil)
    }

    @Test("Return string value promptly")
    func returnsStringPromptly() async {
        let result = await withTimeout(seconds: 1.0) {
            return "hello"
        }
        #expect(result == "hello")
    }
}

@Suite("Pipeline transcript buffer integration")
struct PipelineTranscriptBufferIntegrationTests {

    private func makePipeline(
        audioProvider: MockAudioProvider = MockAudioProvider(),
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        batchProvider: MockBatchDictationProvider = MockBatchDictationProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        transcriptBuffer: TranscriptBuffer = TranscriptBuffer()
    ) -> (
        DictationPipeline, MockAudioProvider, MockAppContextProvider, MockBatchDictationProvider,
        MockTextInjector, RecordingCoordinator, TranscriptBuffer
    ) {
        let pipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: contextProvider,
            batchProvider: batchProvider,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer
        )
        return (
            pipeline, audioProvider, contextProvider, batchProvider, textInjector, coordinator,
            transcriptBuffer
        )
    }

    @Test("Successful cycle stores transcript in buffer")
    func successfulCycleStoresTranscript() async {
        let dictation = MockBatchDictationProvider(stubbedText: "Hello from buffer")
        let (pipeline, _, _, _, _, _, buffer) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        #expect(stored == "Hello from buffer")
    }

    @Test("Buffer holds trimmed transcript text")
    func bufferHoldsTrimmedText() async {
        let dictation = MockBatchDictationProvider(stubbedText: "  trimmed text  ")
        let (pipeline, _, _, _, _, _, buffer) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        #expect(stored == "trimmed text")
    }

    @Test("Injection failure leaves transcript in buffer for recovery")
    func injectionFailurePreservesBuffer() async {
        let dictation = MockBatchDictationProvider(stubbedText: "preserved text")
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let (pipeline, _, _, _, _, coordinator, buffer) = makePipeline(
            batchProvider: dictation, textInjector: injector)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .injectionFailed)

        let stored = await buffer.lastTranscript
        #expect(stored == "preserved text")
    }

    @Test("Injection failure transitions coordinator to injectionFailed")
    func injectionFailureTransitionsState() async {
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let (pipeline, _, _, _, _, coordinator, _) = makePipeline(textInjector: injector)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .injectionFailed)
    }

    @Test("Successful injection returns to idle, not injectionFailed")
    func successfulInjectionReturnsToIdle() async {
        let dictation = MockBatchDictationProvider(stubbedText: "good text")
        let (pipeline, _, _, _, _, coordinator, _) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .idle)
    }

    @Test("Buffer updated across multiple cycles")
    func bufferUpdatedAcrossCycles() async {
        let dictation = MockBatchDictationProvider(stubbedText: "first")
        let (pipeline, _, _, _, _, _, buffer) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()
        var stored = await buffer.lastTranscript
        #expect(stored == "first")

        dictation.stubbedText = "second"
        await pipeline.activate()
        await pipeline.complete()
        stored = await buffer.lastTranscript
        #expect(stored == "second")
    }

    @Test("Empty dictation result skips buffer store")
    func emptyDictationSkipsBuffer() async {
        let dictation = MockBatchDictationProvider(stubbedText: "   ")
        let (pipeline, _, _, _, _, _, buffer) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        #expect(stored == nil)
    }

    @Test("Dictation failure does not store in buffer")
    func dictationFailureSkipsBuffer() async {
        let dictation = MockBatchDictationProvider()
        dictation.stubbedError = DictationError.requestFailed(statusCode: 500, message: "fail")
        let (pipeline, _, _, _, _, _, buffer) = makePipeline(batchProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        #expect(stored == nil)
    }

    @Test("Cancel does not store in buffer")
    func cancelSkipsBuffer() async {
        let (pipeline, _, _, _, _, _, buffer) = makePipeline()

        await pipeline.activate()
        await pipeline.cancel()

        let stored = await buffer.lastTranscript
        #expect(stored == nil)
    }

    @Test("Full cycle after injection failure and reset works normally")
    func cycleAfterFailureAndReset() async {
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let dictation = MockBatchDictationProvider(stubbedText: "first attempt")
        let coordinator = RecordingCoordinator()
        let (pipeline, _, _, _, _, _, buffer) = makePipeline(
            batchProvider: dictation, textInjector: injector, coordinator: coordinator)

        // First cycle fails injection.
        await pipeline.activate()
        await pipeline.complete()
        var state = await coordinator.state
        #expect(state == .injectionFailed)

        // User dismisses no-target state.
        await coordinator.reset()
        state = await coordinator.state
        #expect(state == .idle)

        // Second cycle succeeds.
        injector.stubbedError = nil
        dictation.stubbedText = "second attempt"
        await pipeline.activate()
        await pipeline.complete()
        state = await coordinator.state
        #expect(state == .idle)

        #expect(injector.injectionCount == 1)
        let stored = await buffer.lastTranscript
        #expect(stored == "second attempt")
    }

    @Test("Consume clears buffer after recovery paste")
    func consumeClearsBuffer() async {
        let dictation = MockBatchDictationProvider(stubbedText: "to be consumed")
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let (pipeline, _, _, _, _, _, buffer) = makePipeline(
            batchProvider: dictation, textInjector: injector)

        await pipeline.activate()
        await pipeline.complete()

        // Simulate no-target recovery: consume the transcript.
        let consumed = await buffer.consume()
        #expect(consumed == "to be consumed")

        // Buffer is now empty.
        let remaining = await buffer.lastTranscript
        #expect(remaining == nil)
    }
}
