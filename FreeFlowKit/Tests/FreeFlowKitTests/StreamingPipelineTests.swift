import XCTest

@testable import FreeFlowKit

final class StreamingPipelineTests: XCTestCase {

    // MARK: - Helpers

    /// Build a MockAudioProvider that supports PCM streaming by default.
    private func makeStreamingAudioProvider() -> MockAudioProvider {
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        return audio
    }

    /// Build raw 16-bit PCM data with alternating ±3000 samples.
    private func makeNonSilentPCMChunk(sampleCount: Int = 1600) -> Data {
        var data = Data(capacity: sampleCount * 2)
        for i in 0..<sampleCount {
            let sample: Int16 = i % 2 == 0 ? 3000 : -3000
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Build a batch mock with a delay. Used as the default dictation
    /// provider in test pipelines where batch is not the focus.
    private func makeSlowBatchProvider() -> MockBatchProvider {
        let batch = MockBatchProvider()
        batch.stubbedDelay = 5.0
        return batch
    }

    private func makeStreamingPipeline(
        audioProvider: MockAudioProvider? = nil,
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        batchProvider: MockBatchProvider? = nil,
        streamingProvider: MockStreamingProvider = MockStreamingProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        transcriptBuffer: TranscriptBuffer? = nil
    ) -> (
        DictationPipeline, MockAudioProvider, MockAppContextProvider,
        MockBatchProvider, MockStreamingProvider,
        MockTextInjector, RecordingCoordinator
    ) {
        let audio = audioProvider ?? makeStreamingAudioProvider()
        let dictation = batchProvider ?? makeSlowBatchProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: contextProvider,
            batchProvider: dictation,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            streamingProvider: streamingProvider
        )
        return (
            pipeline, audio, contextProvider, dictation,
            streamingProvider, textInjector, coordinator
        )
    }

    /// Emit PCM chunks in the background so the forwarding task has data.
    private func emitChunksInBackground(
        _ audio: MockAudioProvider,
        count: Int = 2,
        sampleCount: Int = 1600,
        delayNanos: UInt64 = 20_000_000
    ) -> Task<Void, Never> {
        let chunks = (0..<count).map { _ in makeNonSilentPCMChunk(sampleCount: sampleCount) }
        return Task {
            for chunk in chunks {
                guard !Task.isCancelled else { break }
                audio.emitPCMChunk(chunk)
                try? await Task.sleep(nanoseconds: delayNanos)
            }
        }
    }

    // MARK: - Full streaming cycle

    func testStreamingFullCycleTransitionsToIdleAfterCompletion() async {
        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline()

        await pipeline.activate()
        var state = await coordinator.state
        XCTAssertEqual(state, .recording)

        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testStreamingFullCycleInjectsText() async {
        let streaming = MockStreamingProvider(stubbedText: "Hello streaming")
        let (pipeline, audio, _, _, _, injector, _) = makeStreamingPipeline(
            streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Hello streaming")
    }

    func testStreamingFullCycleStartsAndStopsAudioCapture() async {
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        // Audio setup now runs in a background task after activate() returns.
        // Wait briefly for the setup task to complete.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertTrue(audio.isRecording)

        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertFalse(audio.isRecording)
    }

    func testStreamingFullCycleCallsStartStreaming() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.startCallCount, 1)
    }

    func testStreamingFullCycleCallsFinishStreaming() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.finishCallCount, 1)
    }

    func testStreamingFullCycleForwardsAudioChunks() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()

        // Emit chunks and give the forwarding task time to process.
        let emitTask = emitChunksInBackground(audio, count: 3)
        try? await Task.sleep(nanoseconds: 150_000_000)
        emitTask.cancel()

        await pipeline.complete()

        XCTAssertGreaterThan(
            streaming.sendCallCount, 0,
            "Audio chunks should be forwarded to the streaming provider")
        XCTAssertGreaterThan(
            streaming.totalAudioBytesReceived, 0,
            "Streaming provider should receive audio data")
    }

    func testStreamingReadsContext() async {
        let (pipeline, audio, context, _, _, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(context.readContextCallCount, 1)
    }

    func testStreamingPassesContextToStartStreaming() async {
        let ctx = AppContext(
            bundleID: "com.test.app",
            appName: "TestApp",
            windowTitle: "Test Window"
        )
        let contextProvider = MockAppContextProvider(context: ctx)
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline(
            contextProvider: contextProvider)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.receivedContexts.count, 1)
        let received = streaming.receivedContexts.first
        XCTAssertEqual(received?.bundleID, "com.test.app")
        XCTAssertEqual(received?.appName, "TestApp")
    }

    func testStreamingPassesContextToTextInjector() async {
        let ctx = AppContext(
            bundleID: "com.test.inject",
            appName: "InjectApp",
            windowTitle: "Inject Window"
        )
        let contextProvider = MockAppContextProvider(context: ctx)
        let (pipeline, audio, _, _, _, injector, _) = makeStreamingPipeline(
            contextProvider: contextProvider)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let injectedContext = injector.injections.first?.context
        XCTAssertEqual(injectedContext?.bundleID, "com.test.inject")
        XCTAssertEqual(injectedContext?.appName, "InjectApp")
    }

    // MARK: - State transitions

    func testStreamingStatePassesThroughAllPhases() async {
        let coordinator = RecordingCoordinator()
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(coordinator: coordinator)

        var collected: [RecordingState] = []
        let expectation = XCTestExpectation(description: "Collect all state transitions")

        let streamTask = Task {
            for await state in await coordinator.stateStream {
                collected.append(state)
                // idle, recording, processing, injecting, idle
                if collected.count >= 5 {
                    break
                }
            }
            expectation.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        await fulfillment(of: [expectation], timeout: 5.0)
        streamTask.cancel()

        XCTAssertEqual(collected, [.idle, .recording, .processing, .injecting, .idle])
    }

    // MARK: - Cancellation

    func testCancelDuringStreamingResetsToIdle() async {
        let (pipeline, _, _, _, streaming, _, coordinator) = makeStreamingPipeline()

        await pipeline.activate()
        // Audio setup now runs in a background task after activate() returns.
        // Wait briefly for the streaming session to start before cancelling.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        let state = await coordinator.state
        XCTAssertEqual(state, .recording)

        await pipeline.cancel()
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)

        XCTAssertEqual(
            streaming.cancelCallCount, 1,
            "Streaming session should be cancelled")
    }

    func testCancelDoesNotCallFinishStreaming() async {
        let (pipeline, _, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        await pipeline.cancel()

        XCTAssertEqual(
            streaming.finishCallCount, 0,
            "finishStreaming should not be called on cancel")
    }

    func testCycleWorksAfterStreamingCancel() async {
        let streaming = MockStreamingProvider(stubbedText: "After cancel")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming)

        // First cycle: cancel.
        await pipeline.activate()
        await pipeline.cancel()
        var state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Second cycle: complete.
        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(streaming.finishCallCount, 1)
    }

    // MARK: - Streaming errors

    func testStreamingStartFailureFallsToBatchMode() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("connection refused")

        let dictation = MockBatchProvider(stubbedText: "Batch fallback text")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // When streaming start fails, pipeline falls back to batch mode.
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be called as fallback when streaming start fails")
        XCTAssertEqual(injector.lastInjectedText, "Batch fallback text")
    }

    func testStreamingFinishFailureFallsToBatch() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("connection lost")

        let dictation = MockBatchProvider(stubbedText: "Batch recovery")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be called as fallback when streaming finish fails")
        XCTAssertEqual(injector.lastInjectedText, "Batch recovery")
    }

    func testStreamingEmptyResultUsesBatchFallback() async {
        // When streaming returns empty, batch result is used (parallel mode).
        let streaming = MockStreamingProvider(stubbedText: "")
        let dictation = MockBatchProvider(stubbedText: "Batch result")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 1,
            "Batch result should be injected when streaming returns empty")
        XCTAssertEqual(injector.lastInjectedText, "Batch result")
    }

    func testBothEmptyResultsSkipInjection() async {
        // When both streaming and batch return empty, skip injection.
        let streaming = MockStreamingProvider(stubbedText: "")
        let dictation = MockBatchProvider(stubbedText: "")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "Empty results from both paths should skip injection")
    }

    func testBothWhitespaceOnlyResultsSkipInjection() async {
        // When both streaming and batch return whitespace-only, skip injection.
        let streaming = MockStreamingProvider(stubbedText: "   \n  ")
        let dictation = MockBatchProvider(stubbedText: "  \t  ")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "Whitespace-only results from both paths should skip injection")
    }

    // MARK: - Transcript buffer

    func testStreamingStoresTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingProvider(stubbedText: "Streamed text")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            streamingProvider: streaming, transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(stored, "Streamed text")
    }

    func testBothEmptyResultsDoNotStoreInBuffer() async {
        // When both streaming and batch return empty, nothing stored.
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingProvider(stubbedText: "")
        let dictation = MockBatchProvider(stubbedText: "")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertNil(stored, "Empty results from both paths should not be stored in buffer")
    }

    func testStreamingEmptyButBatchSuccessStoresInBuffer() async {
        // When streaming returns empty but batch returns text, store batch result.
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingProvider(stubbedText: "")
        let dictation = MockBatchProvider(stubbedText: "Batch text")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "Batch text", "Batch result should be stored when streaming is empty")
    }

    func testStreamingFailureWithBatchFallbackStoresInBuffer() async {
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("fail")
        let dictation = MockBatchProvider(stubbedText: "Batch recovered")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "Batch recovered",
            "Batch fallback result should be stored in buffer")
    }

    // MARK: - Injection failure in streaming mode

    func testStreamingInjectionFailureTransitionsToInjectionFailed() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider(stubbedText: "streamed text")

        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming, textInjector: injector, transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .injectionFailed,
            "Pipeline should transition to injectionFailed on injection error in streaming mode")
    }

    func testStreamingInjectionFailurePreservesTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider(stubbedText: "preserved streaming text")

        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            streamingProvider: streaming, textInjector: injector, transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "preserved streaming text",
            "Transcript should remain in buffer after injection failure in streaming mode")
    }

    func testStreamingCycleWorksAfterInjectionFailureAndReset() async {
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let coordinator = RecordingCoordinator()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider(stubbedText: "first attempt")

        let (pipeline, _, _, _, _, _, _) = makeStreamingPipeline(
            audioProvider: audio, streamingProvider: streaming,
            textInjector: injector, coordinator: coordinator)

        // First cycle: injection fails.
        await pipeline.activate()
        let emitTask1 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask1.cancel()

        var state = await coordinator.state
        XCTAssertEqual(state, .injectionFailed)

        // Reset (simulates user dismissing no-target HUD).
        await coordinator.reset()
        state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Second cycle: injection succeeds.
        injector.stubbedError = nil
        streaming.stubbedText = "second attempt"

        await pipeline.activate()
        let emitTask2 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask2.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "second attempt")
    }

    // MARK: - Fallback to batch when no PCM stream

    func testFallbackToBatchWhenNoPCMStream() async {
        // Use a MockAudioProvider WITHOUT enablePCMStream (nil pcmAudioStream).
        let audio = MockAudioProvider()
        // enablePCMStream defaults to false, so pcmAudioStream is nil.

        let streaming = MockStreamingProvider(stubbedText: "Should not be used")
        let dictation = MockBatchProvider(stubbedText: "Batch text")

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator(),
            streamingProvider: streaming
        )

        await pipeline.activate()
        await pipeline.complete()

        XCTAssertEqual(
            streaming.startCallCount, 0,
            "Streaming should not be used when audio provider has no pcmAudioStream")
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be used as fallback")
    }

    func testFallbackToBatchWhenNoStreamingProvider() async {
        let audio = makeStreamingAudioProvider()
        let dictation = MockBatchProvider(stubbedText: "Batch only")

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator()
                // No streamingProvider passed — defaults to nil.
        )

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be used when no streaming provider is configured")
    }

    // MARK: - Multiple consecutive streaming cycles

    func testMultipleConsecutiveStreamingCycles() async {
        let streaming = MockStreamingProvider()
        let audio = makeStreamingAudioProvider()
        let coordinator = RecordingCoordinator()
        let injector = MockTextInjector()

        let batch = makeSlowBatchProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: batch,
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: streaming
        )

        // First cycle.
        streaming.stubbedText = "First"
        await pipeline.activate()
        let emitTask1 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask1.cancel()

        var state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "First")

        // Second cycle.
        streaming.stubbedText = "Second"
        await pipeline.activate()
        let emitTask2 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask2.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 2)
        XCTAssertEqual(injector.lastInjectedText, "Second")

        XCTAssertEqual(streaming.startCallCount, 2)
        XCTAssertEqual(streaming.finishCallCount, 2)
    }

    // MARK: - Rapid streaming activate/cancel cycles

    func testRapidStreamingActivateCancelCycles() async {
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: MockBatchProvider(),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            streamingProvider: streaming
        )

        for _ in 0..<5 {
            await pipeline.activate()
            await pipeline.cancel()
            let state = await coordinator.state
            XCTAssertEqual(state, .idle)
        }

        // One final full cycle to confirm nothing is broken.
        streaming.stubbedText = "After rapid cycles"
        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    // MARK: - Streaming send error during forwarding

    func testStreamingSendErrorDoesNotCrash() async {
        let streaming = MockStreamingProvider(stubbedText: "Partial result")
        // Fail on the second sendAudio call.
        streaming.stubbedSendError = DictationError.networkError("send failed")

        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming)

        await pipeline.activate()

        // Emit a chunk to trigger the send error.
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        try? await Task.sleep(nanoseconds: 50_000_000)

        await pipeline.complete()

        // The pipeline should still complete (finishStreaming returns text).
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.lastInjectedText, "Partial result")
    }

    // MARK: - Language parameter

    func testStreamingPassesNilLanguage() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.receivedLanguages.count, 1)
        XCTAssertNil(streaming.receivedLanguages.first ?? "not nil")
    }

    // MARK: - Chunk handler wiring

    func testPipelineSetsChunkHandlerOnStreamingProvider() async {
        let streaming = MockStreamingProvider()
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            streamingProvider: streaming)

        await pipeline.activate()
        // Let audio setup finish and set the handler.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(
            streaming.hasChunkHandler,
            "Pipeline should set a chunk handler on the streaming provider")

        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()
    }

    // MARK: - Chunk handler cleared after complete

    func testChunkHandlerClearedAfterComplete() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertFalse(
            streaming.hasChunkHandler,
            "Chunk handler must be cleared after complete() to prevent late injection")
    }

    // MARK: - Cancel always cancels streaming

    func testCancelAlwaysCancelsStreaming() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let emitTask = emitChunksInBackground(audio)

        // Start complete() which clears isStreamingSession, then cancel.
        let completeTask = Task { await pipeline.complete() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await pipeline.cancel()
        completeTask.cancel()
        emitTask.cancel()

        XCTAssertGreaterThanOrEqual(
            streaming.cancelCallCount, 1,
            "cancel() must call cancelStreaming() even after complete() cleared isStreamingSession")
    }

    // MARK: - Silence rejection

    func testSilentStreamingSessionRejectsWithoutInjecting() async {
        let audio = makeStreamingAudioProvider()
        // Set peak RMS below the silence threshold so the early gate fires.
        audio.stubbedPeakRMS = 0.001

        let (pipeline, _, _, _, _, injector, coordinator) =
            makeStreamingPipeline(audioProvider: audio)

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let emitTask = emitChunksInBackground(audio, count: 2)
        await pipeline.complete()
        emitTask.cancel()

        // Pipeline should return to idle without injecting text.
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "Silent audio should not produce any text injection")
    }

    // MARK: - Sequential fallback (streaming → batch)

    func testStreamingSuccessSkipsBatch() async {
        // When streaming succeeds, batch should NOT be called.
        let streaming = MockStreamingProvider(stubbedText: "Streaming result")
        let dictation = MockBatchProvider(stubbedText: "Batch result")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            dictation.dictateCallCount, 0,
            "Batch should not be called when streaming succeeds")
        XCTAssertEqual(injector.lastInjectedText, "Streaming result")
    }

    func testStreamingFailureFallsToBatchHTTP() async {
        // When streaming fails, batch HTTP should be called as fallback.
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider(stubbedText: "Batch fallback")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch should be called as fallback when streaming fails")
        XCTAssertEqual(injector.lastInjectedText, "Batch fallback")
    }

    func testBothStreamingAndBatchFailSkipInjection() async {
        // When both streaming and batch fail, no text should be injected.
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.networkError("http died")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "No text should be injected when both paths fail")
    }

    // MARK: - Audio setup failure during complete

    func testAudioSetupFailureDuringCompleteResetsToIdle() async {
        // Simulate: activate() starts audio setup which takes 1s then
        // fails. complete() is called 50ms later while setup is still
        // running. The coordinator should end in .idle, not get stuck
        // in .processing.
        let audio = makeStreamingAudioProvider()
        audio.stubbedStartDelay = 1.0
        audio.stubbedStartError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "BT negotiation failed"])

        let coordinator = RecordingCoordinator()
        let (pipeline, _, _, _, _, injector, _) = makeStreamingPipeline(
            audioProvider: audio, coordinator: coordinator)

        await pipeline.activate()
        let state1 = await coordinator.state
        XCTAssertEqual(state1, .recording)

        // complete() while audio setup is still sleeping for 1s.
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .idle,
            "Coordinator should be idle after audio setup failure, not stuck in processing")
        XCTAssertEqual(
            injector.injectionCount, 0,
            "No text should be injected when audio setup fails")
    }
}
