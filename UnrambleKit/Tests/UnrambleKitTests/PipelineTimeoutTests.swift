import XCTest

@testable import UnrambleKit
import UnrambleKitTestSupport

// MARK: - Hanging Mock

/// A mock streaming provider where each method can be made to hang
/// indefinitely (until cancelled) or for a configurable duration.
///
/// This simulates real-world failure modes:
/// - WebSocket `sendPing` hanging on a half-closed TCP connection
/// - `ensureConnected()` blocking on a slow TLS handshake
/// - Server never sending `transcript_done`
///
/// Each method blocks on a `CheckedContinuation` that is only resumed
/// when the task is cancelled or the test explicitly calls `release*()`.
final class HangingStreamingDictationProvider: StreamingDictationProviding, @unchecked Sendable {

    private let lock = NSLock()

    // --- Configuration ---

    /// When true, `startStreaming()` hangs until cancelled or released.
    var hangOnStart: Bool = false

    /// When true, `finishStreaming()` hangs until cancelled or released.
    var hangOnFinish: Bool = false

    /// When true, `sendAudio()` hangs indefinitely on the first call,
    /// simulating a stuck `URLSessionWebSocketTask.send()` on a broken
    /// WebSocket. Closing the forwarding operation should unblock this.
    var hangOnSendAudio: Bool = false

    /// Fixed delay (in seconds) before `startStreaming()` returns.
    /// Applied only when `hangOnStart` is false.
    var startDelay: TimeInterval = 0

    /// Fixed delay (in seconds) before `finishStreaming()` returns.
    /// Applied only when `hangOnFinish` is false.
    var finishDelay: TimeInterval = 0

    /// The text returned by `finishStreaming()` when it doesn't hang.
    var stubbedText: String = "Streamed text"

    /// Pipeline watchdog for a cancellation-insensitive finalization.
    var finishStreamingWatchdog: TimeInterval = 30

    /// An optional error to throw from `finishStreaming()`.
    var stubbedFinishError: (any Error)?

    // --- Call tracking ---

    private var _startCallCount: Int = 0
    private var _finishCallCount: Int = 0
    private var _cancelCallCount: Int = 0
    private var _sendAudioCallCount: Int = 0
    private var _startDidHang: Bool = false
    private var _finishDidHang: Bool = false
    private var _sendAudioDidHang: Bool = false
    private var sessionCancelled = false
    private var activeSessionID: DictationSessionID?

    var startCallCount: Int { lock.withLock { _startCallCount } }
    var finishCallCount: Int { lock.withLock { _finishCallCount } }
    var cancelCallCount: Int { lock.withLock { _cancelCallCount } }
    var sendAudioCallCount: Int { lock.withLock { _sendAudioCallCount } }

    /// Whether `startStreaming()` actually entered the hanging state.
    var startDidHang: Bool { lock.withLock { _startDidHang } }

    /// Whether `finishStreaming()` actually entered the hanging state.
    var finishDidHang: Bool { lock.withLock { _finishDidHang } }

    /// Whether `sendAudio()` actually entered the hanging state.
    var sendAudioDidHang: Bool { lock.withLock { _sendAudioDidHang } }

    // --- Manual release for hangs ---

    private var startContinuation: CheckedContinuation<Void, any Error>?
    private var finishContinuation: CheckedContinuation<String, any Error>?
    private var sendAudioContinuation: CheckedContinuation<Void, any Error>?

    /// Resume a hanging `startStreaming()` call.
    func releaseStart() {
        lock.withLock {
            startContinuation?.resume()
            startContinuation = nil
        }
    }

    /// Resume a hanging `finishStreaming()` call with a result.
    func releaseFinish(text: String = "Released text") {
        lock.withLock {
            finishContinuation?.resume(returning: text)
            finishContinuation = nil
        }
    }

    /// Resume a hanging `finishStreaming()` call with an error.
    func releaseFinishWithError(_ error: any Error) {
        lock.withLock {
            finishContinuation?.resume(throwing: error)
            finishContinuation = nil
        }
    }

    // --- StreamingDictationProviding ---

    func startStreaming(
        sessionID: DictationSessionID,
        context _: AppContext,
        language _: String?,
        micProximity _: MicProximity
    ) async throws {
        let accepted = lock.withLock {
            guard activeSessionID == nil else { return false }
            _startCallCount += 1
            sessionCancelled = false
            activeSessionID = sessionID
            return true
        }
        guard accepted else { throw CancellationError() }

        if hangOnStart {
            // Block until cancelled or explicitly released.
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Void, any Error>) in
                let shouldCancel = lock.withLock {
                    _startDidHang = true
                    guard !sessionCancelled else { return true }
                    startContinuation = cont
                    return false
                }
                if shouldCancel {
                    cont.resume(throwing: CancellationError())
                }
            }
        } else if startDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            try Task.checkCancellation()
        }
    }

    func sendAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID
    ) async throws {
        let accepted = lock.withLock {
            guard activeSessionID == sessionID else { return false }
            _sendAudioCallCount += 1
            return true
        }
        guard accepted else { throw CancellationError() }

        if hangOnSendAudio {
            // Block indefinitely, simulating a stuck WebSocket send().
            // URLSessionWebSocketTask.send() does not respond to Swift
            // structured concurrency cancellation, so this continuation
            // is only resumed by cancelStreaming() or explicit release.
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Void, any Error>) in
                let shouldCancel = lock.withLock {
                    _sendAudioDidHang = true
                    guard !sessionCancelled else { return true }
                    sendAudioContinuation = cont
                    return false
                }
                if shouldCancel {
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    func finishStreaming(
        sessionID: DictationSessionID
    ) async throws -> String {
        let accepted = lock.withLock {
            guard activeSessionID == sessionID else { return false }
            _finishCallCount += 1
            return true
        }
        guard accepted else { throw CancellationError() }

        let result: String
        if hangOnFinish {
            result = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<String, any Error>) in
                let shouldCancel = lock.withLock {
                    _finishDidHang = true
                    guard !sessionCancelled else { return true }
                    finishContinuation = cont
                    return false
                }
                if shouldCancel {
                    cont.resume(throwing: CancellationError())
                }
            }
        } else if finishDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(finishDelay * 1_000_000_000))
            try Task.checkCancellation()
            result = stubbedText
        } else {
            result = stubbedText
        }

        if let error = stubbedFinishError {
            throw error
        }
        let stillOwned = lock.withLock {
            guard activeSessionID == sessionID else { return false }
            activeSessionID = nil
            return true
        }
        guard stillOwned else { throw CancellationError() }
        return result
    }

    func cancelActiveStreaming() async {
        guard let sessionID = lock.withLock({ activeSessionID }) else { return }
        await cancelStreaming(sessionID: sessionID)
    }

    func cancelStreaming(sessionID: DictationSessionID) async {
        let continuations = lock.withLock { () -> (
            CheckedContinuation<Void, any Error>?,
            CheckedContinuation<String, any Error>?,
            CheckedContinuation<Void, any Error>?
        )? in
            guard activeSessionID == sessionID else { return nil }
            _cancelCallCount += 1
            sessionCancelled = true
            activeSessionID = nil
            let continuations = (
                startContinuation, finishContinuation, sendAudioContinuation)
            startContinuation = nil
            finishContinuation = nil
            sendAudioContinuation = nil
            return continuations
        }
        guard let continuations else { return }
        continuations.0?.resume(throwing: CancellationError())
        continuations.1?.resume(throwing: CancellationError())
        continuations.2?.resume(throwing: CancellationError())
    }
}

// MARK: - Tests

final class PipelineTimeoutTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UNRAMBLE_TEST_SLOW"] == "1",
            "Slow timeout tests skipped (set UNRAMBLE_TEST_SLOW=1 to run)")
    }

    // MARK: - Helpers

    private func makeStreamingAudioProvider() -> MockAudioProvider {
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        return audio
    }

    private func makeNonSilentPCMChunk(sampleCount: Int = 1600) -> Data {
        var data = Data(capacity: sampleCount * 2)
        for i in 0..<sampleCount {
            let sample: Int16 = i % 2 == 0 ? 3000 : -3000
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func makePipeline(
        audioProvider: MockAudioProvider? = nil,
        batchProvider: MockBatchProvider = MockBatchProvider(),
        streamingProvider: HangingStreamingDictationProvider = HangingStreamingDictationProvider(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        pipelineDeadlineOverride: TimeInterval? = nil
    ) -> (
        DictationPipeline, MockAudioProvider, MockBatchProvider,
        HangingStreamingDictationProvider, MockTextInjector, RecordingCoordinator
    ) {
        let audio = audioProvider ?? makeStreamingAudioProvider()
        let injector = MockTextInjector()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streamingProvider,
                fallback: batchProvider),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimit: .seconds(300),
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            pipelineDeadlineOverride: pipelineDeadlineOverride
        )
        return (pipeline, audio, batchProvider, streamingProvider, injector, coordinator)
    }

    private func emitChunksInBackground(
        _ audio: MockAudioProvider,
        count: Int = 5,
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

    /// Assert that an async operation completes within the given wall-clock time.
    /// Fails the test if the deadline is exceeded.
    private func assertCompletesWithin<T>(
        _ seconds: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: @escaping () async -> T
    ) async -> T? {
        let expectation = XCTestExpectation(description: "Operation completes within \(seconds)s")
        var result: T?
        let task = Task {
            let value = await operation()
            result = value
            expectation.fulfill()
            return value
        }
        let waiterResult = await XCTWaiter().fulfillment(of: [expectation], timeout: seconds)
        if waiterResult != .completed {
            XCTFail(
                "Operation did not complete within \(seconds)s — likely a deadlock or missing timeout",
                file: file, line: line)
            task.cancel()
            return nil
        }
        return result
    }

    // MARK: - Streaming setup timeout

    /// When `startStreaming()` hangs, `complete()` must still return within
    /// a bounded time. The 5s streaming setup timeout should fire, and the
    /// pipeline should fall back to batch mode.
    func testCompleteReturnsWhenStartStreamingHangs() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnStart = true
        let dictation = MockBatchProvider(stubbedText: "Batch fallback")
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        // Wait for audio setup to get past startRecording and into the
        // hanging startStreaming call.
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        let emitTask = emitChunksInBackground(audio, count: 10, delayNanos: 50_000_000)

        // The pipeline's streaming setup timeout is 5s. complete() should
        // return well within 8s (5s timeout + batch call + margin).
        await assertCompletesWithin(8.0) {
            await pipeline.complete()
        }
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .idle, "Pipeline should return to idle after timeout + batch fallback")

        // The streaming provider should have been cancelled after timeout.
        XCTAssertGreaterThanOrEqual(
            streaming.cancelCallCount, 1,
            "cancelStreaming() should be called after setup timeout")
    }

    /// When `startStreaming()` hangs and the batch path also produces no
    /// result (e.g. silence), `complete()` should still return promptly.
    func testCompleteReturnsWhenStartStreamingHangsAndBatchIssilent() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnStart = true
        // Don't emit audio chunks — the audio buffer will be empty/silent.
        let (pipeline, _, _, _, _, coordinator) = makePipeline(streamingProvider: streaming)

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        await assertCompletesWithin(8.0) {
            await pipeline.complete()
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Finish streaming timeout

    /// When `finishStreaming()` hangs, the provider watchdog must close and
    /// join it before the pipeline recovers from the exact complete WAV.
    func testCompleteReturnsWhenFinishStreamingHangs() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnFinish = true
        streaming.finishStreamingWatchdog = 0.05
        let dictation = MockBatchProvider(stubbedText: "Batch wins")
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline(
            batchProvider: dictation, streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        let emitTask = emitChunksInBackground(audio, count: 10, delayNanos: 50_000_000)

        await assertCompletesWithin(5.0) {
            await pipeline.complete()
        }
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertGreaterThanOrEqual(streaming.cancelCallCount, 1)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Batch wins")

        streaming.releaseFinish(text: "Late plausible text")
        await Task.yield()
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Batch wins")
    }

    // MARK: - Cancellation propagation

    /// After the streaming setup timeout fires, the cancelled task should
    /// not continue executing. Verify that `startStreaming()` sees
    /// cancellation rather than continuing to retry connections.
    func testStreamingSetupTimeoutPropagatesCancellation() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnStart = true
        let (pipeline, audio, _, _, _, _) = makePipeline(streamingProvider: streaming)

        await pipeline.activate()

        // Wait for the start to actually hang.
        let startHanging = expectation(description: "startStreaming entered hang")
        Task {
            while !streaming.startDidHang {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            startHanging.fulfill()
        }
        await fulfillment(of: [startHanging], timeout: 3.0)

        let emitTask = emitChunksInBackground(audio)

        // Complete the pipeline — this triggers the 5s timeout.
        await assertCompletesWithin(8.0) {
            await pipeline.complete()
        }
        emitTask.cancel()

        // After the timeout, cancelStreaming() should have been called,
        // which releases the hanging continuation with CancellationError.
        XCTAssertGreaterThanOrEqual(streaming.cancelCallCount, 1)
    }

    // MARK: - Rapid cycles with hanging provider

    /// Rapid activate/complete cycles should never deadlock, even when
    /// the streaming provider intermittently hangs.
    func testRapidCyclesWithIntermittentHangs() async {
        let streaming = HangingStreamingDictationProvider()
        let dictation = MockBatchProvider(stubbedText: "Rapid result")
        let coordinator = RecordingCoordinator()
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            coordinator: coordinator)

        // Run 6 rapid cycles. Hang on even-numbered ones.
        for i in 0..<6 {
            streaming.hangOnStart = (i % 2 == 0)

            await pipeline.activate()
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

            let emitTask = emitChunksInBackground(audio, count: 3, delayNanos: 10_000_000)

            // Each cycle must complete within 8s (5s timeout + margin).
            let completed = await assertCompletesWithin(8.0) {
                await pipeline.complete()
            }
            emitTask.cancel()

            XCTAssertNotNil(completed, "Cycle \(i) should complete within timeout")

            let state = await coordinator.state
            XCTAssertEqual(state, .idle, "Cycle \(i) should return to idle")
        }
    }

    // MARK: - Cancel during setup

    /// Calling `cancel()` while `performAudioSetup()` is in progress
    /// (hanging on startStreaming) should return promptly.
    func testCancelWhileSetupHangs() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnStart = true
        let (pipeline, _, _, _, _, coordinator) = makePipeline(streamingProvider: streaming)

        await pipeline.activate()

        // Wait for the hang to be entered.
        let startHanging = expectation(description: "startStreaming entered hang")
        Task {
            while !streaming.startDidHang {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            startHanging.fulfill()
        }
        await fulfillment(of: [startHanging], timeout: 3.0)

        // Cancel should return quickly — it doesn't need to wait for the
        // streaming setup timeout.
        await assertCompletesWithin(2.0) {
            await pipeline.cancel()
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .idle, "Cancel should reset to idle")
    }

    // MARK: - Slow start still works

    /// A streaming provider that is slow (but not hanging) should still
    /// work — the setup completes before the 5s timeout.
    func testSlowStartStreamingStillWorks() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.startDelay = 1.0  // 1s — well under the 5s timeout
        streaming.stubbedText = "Slow but OK"
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline(
            streamingProvider: streaming)

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        let emitTask = emitChunksInBackground(audio, count: 10, delayNanos: 50_000_000)

        await assertCompletesWithin(5.0) {
            await pipeline.complete()
        }
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Streaming should have succeeded (not timed out).
        XCTAssertEqual(streaming.startCallCount, 1)
        XCTAssertEqual(
            streaming.cancelCallCount, 0,
            "Streaming should not be cancelled when it completes in time")
    }

    // MARK: - Batch fallback correctness

    /// When streaming setup times out, verify the pipeline correctly falls
    /// back to batch mode and produces the batch result.
    func testBatchFallbackAfterSetupTimeout() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnStart = true
        let dictation = MockBatchProvider(stubbedText: "Batch text")
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let emitTask = emitChunksInBackground(audio, count: 10, delayNanos: 50_000_000)

        await assertCompletesWithin(8.0) {
            await pipeline.complete()
        }
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Batch dictation should have been called (streaming was unavailable).
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be called when streaming times out")
        XCTAssertEqual(
            injector.lastInjectedText, "Batch text",
            "Batch result should be injected when streaming times out")
    }

    // MARK: - No zombie tasks after timeout

    /// After a streaming setup timeout, no further calls should be made to
    /// the streaming provider from the timed-out task. This verifies that
    /// zombie tasks are properly cancelled.
    func testNoZombieCallsAfterTimeout() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnStart = true
        let (pipeline, audio, _, _, _, _) = makePipeline(streamingProvider: streaming)

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let emitTask = emitChunksInBackground(audio)

        await assertCompletesWithin(8.0) {
            await pipeline.complete()
        }
        emitTask.cancel()

        let countAfterComplete = streaming.startCallCount

        // Wait an additional 2s and verify no new calls arrived from
        // a zombie task retrying startStreaming.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertEqual(
            streaming.startCallCount, countAfterComplete,
            "No additional startStreaming() calls should occur after timeout + cancel")
    }

    // MARK: - Complete before audio setup finishes

    /// If the user releases the hotkey before audio setup completes
    /// (very fast press-release), complete() returns promptly and surfaces an
    /// explicit failure for the missed capture rather than silently going idle.
    func testQuickReleaseBeforeAudioSetupCompletes() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.startDelay = 2.0  // Slow but not hanging
        let dictation = MockBatchProvider(stubbedText: "Quick release")
        let (pipeline, _, _, _, _, coordinator) = makePipeline(
            batchProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        // Don't wait — release immediately.
        // complete() should wait for audioSetupTask, which is still
        // setting up audio + streaming. Total should be < startDelay + margin.

        await assertCompletesWithin(5.0) {
            await pipeline.complete()
        }

        let state = await coordinator.state
        XCTAssertEqual(
            state, .dictationFailed,
            "A release before live capture surfaces an explicit failure")
    }

    // MARK: - Audio forwarding operation timeout

    /// Reproduce the exact production hang: streaming setup succeeds,
    /// audio forwarding starts, then sendAudio() hangs on a broken
    /// WebSocket. complete() must still return within a bounded time
    /// instead of permanently sticking in `.processing`.
    func testCompleteReturnsWhenSendAudioHangs() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnSendAudio = true
        let dictation = MockBatchProvider(stubbedText: "Batch fallback")
        let audio = makeStreamingAudioProvider()
        let coordinator = RecordingCoordinator()
        let (pipeline, _, _, _, injector, _) = makePipeline(
            audioProvider: audio,
            batchProvider: dictation,
            streamingProvider: streaming,
            coordinator: coordinator)

        await pipeline.activate()

        // Wait for audio setup (streaming session open + forwarding started).
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Emit a chunk — this triggers sendAudio() which hangs.
        audio.emitPCMChunk(makeNonSilentPCMChunk())

        // Give the forwarding operation time to enter the hanging sendAudio.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            streaming.sendAudioDidHang,
            "sendAudio should have entered hanging state")

        // complete() must return within a bounded time. The forwarding
        // task timeout is 2s, plus margin for batch fallback.
        // Total budget: 2s forwarding timeout + batch dictation + margin.
        await assertCompletesWithin(8.0) {
            await pipeline.complete()
        }

        let state = await coordinator.state
        XCTAssertEqual(
            state, .idle,
            "Pipeline should be back to idle after forwarding timeout")
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(dictation.receivedAudioData, [audio.stubbedBuffer.data])
        XCTAssertEqual(injector.lastInjectedText, "Batch fallback")
    }

    // MARK: - Overall pipeline timeout

    /// A forwarding timeout followed by a stuck batch request must hit the
    /// pipeline deadline and preserve the exact WAV for an explicit retry.
    func testOverallPipelineTimeoutPreservesCompleteWAVForRetry() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnSendAudio = true
        // Make batch also hang by using a provider that blocks.
        let hangingDictation = MockBatchProvider()
        hangingDictation.stubbedDelay = 60
        let audio = makeStreamingAudioProvider()
        let coordinator = RecordingCoordinator()
        let (pipeline, _, _, _, injector, _) = makePipeline(
            audioProvider: audio,
            batchProvider: hangingDictation,
            streamingProvider: streaming,
            coordinator: coordinator,
            pipelineDeadlineOverride: 5)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 200_000_000)
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        try? await Task.sleep(nanoseconds: 200_000_000)

        // The injected 5 s deadline fires while the batch is still stuck
        // (stubbedDelay 60 s); wait comfortably past it.
        await assertCompletesWithin(20.0) {
            await pipeline.complete()
        }

        let state = await coordinator.state
        XCTAssertEqual(
            state, .dictationFailed,
            "A timed-out batch fallback must remain recoverable")
        XCTAssertEqual(hangingDictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        hangingDictation.stubbedDelay = 0
        hangingDictation.stubbedText = "Recovered after deadline"
        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(hangingDictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered after deadline")
    }

    /// A finish operation whose own watchdog exceeds the pipeline deadline must
    /// still preserve the exact WAV when the outer owner cancels finalization.
    func testOverallDeadlineDuringFinishPreservesCompleteWAVForRetry() async {
        let streaming = HangingStreamingDictationProvider()
        streaming.hangOnFinish = true
        streaming.finishStreamingWatchdog = 60
        let dictation = MockBatchProvider(stubbedText: "Recovered finish timeout")
        let audio = makeStreamingAudioProvider()
        let coordinator = RecordingCoordinator()
        let (pipeline, _, _, _, injector, _) = makePipeline(
            audioProvider: audio,
            batchProvider: dictation,
            streamingProvider: streaming,
            coordinator: coordinator,
            pipelineDeadlineOverride: 5)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let emitTask = emitChunksInBackground(audio)

        // The injected 5 s deadline fires while finishStreaming is still
        // hanging (watchdog 60 s), so the outer owner cancels finalization.
        await assertCompletesWithin(20.0) {
            await pipeline.complete()
        }
        emitTask.cancel()

        let timedOutState = await coordinator.state
        XCTAssertEqual(timedOutState, .dictationFailed)
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertGreaterThanOrEqual(streaming.cancelCallCount, 1)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered finish timeout")
    }
}
