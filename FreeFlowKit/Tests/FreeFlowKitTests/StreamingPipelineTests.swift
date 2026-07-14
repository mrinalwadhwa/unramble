import XCTest

@testable import FreeFlowKit

private final class RecordingLimitSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var _requestedDurations: [Duration] = []
    private var _observedCancellation: Bool?

    var callCount: Int {
        lock.withLock { _requestedDurations.count }
    }

    var requestedDurations: [Duration] {
        lock.withLock { _requestedDurations }
    }

    var observedCancellation: Bool? {
        lock.withLock { _observedCancellation }
    }

    func sleep(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                _requestedDurations.append(duration)
                if released { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
        lock.withLock {
            _observedCancellation = Task.isCancelled
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class MultiRecordingLimitSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var durations: [Duration] = []
    private var cancellations: [Int: Bool] = [:]

    var callCount: Int {
        lock.withLock { durations.count }
    }

    func observedCancellation(for call: Int) -> Bool? {
        lock.withLock { cancellations[call] }
    }

    func sleep(for duration: Duration) async {
        let call = lock.withLock {
            let call = durations.count
            durations.append(duration)
            return call
        }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if released.contains(call) { return true }
                continuations[call] = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
        lock.withLock {
            cancellations[call] = Task.isCancelled
        }
    }

    func release(call: Int) {
        let continuation = lock.withLock {
            released.insert(call)
            return continuations.removeValue(forKey: call)
        }
        continuation?.resume()
    }
}

private actor RecordingLimitClaimGate {
    private var claimed = false
    private var released = false
    private var observedCancellation: Bool?
    private var claimWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseAfterClaim() async {
        claimed = true
        let waiters = claimWaiters
        claimWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        observedCancellation = Task.isCancelled
    }

    func waitUntilClaimed() async {
        guard !claimed else { return }
        await withCheckedContinuation { continuation in
            claimWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func cancellationObserved() -> Bool? {
        observedCancellation
    }
}

private actor AsyncCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func hasCompleted() -> Bool {
        completed
    }
}

private final class CompletionWaitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false

    var hasWaiter: Bool {
        lock.withLock { waiting }
    }

    func markWaiting() {
        lock.withLock { waiting = true }
    }
}

private actor SuspensionGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class GatedStartAudioProvider: AudioProviding, @unchecked Sendable {
    private let base = MockAudioProvider()
    private let startGate: SuspensionGate

    init(startGate: SuspensionGate) {
        self.startGate = startGate
    }

    var isRecording: Bool { base.isRecording }
    var pcmAudioStream: AsyncStream<Data>? { base.pcmAudioStream }
    var audioLevelStream: AsyncStream<Float>? { base.audioLevelStream }
    var peakRMS: Float { base.peakRMS }
    var ambientRMS: Float { base.ambientRMS }
    var micProximity: MicProximity { base.micProximity }
    var gainFactor: Float { base.gainFactor }
    var deviceName: String { base.deviceName }
    func startRecording() async throws {
        await startGate.waitForRelease()
        try await base.startRecording()
    }

    func stopRecording() async throws -> AudioBuffer {
        try await base.stopRecording()
    }
}

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

    private func makeSparseAudibleBuffer() -> AudioBuffer {
        let sampleRate = 16_000
        let sampleCount = sampleRate * 4
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let sample: Int16 = index < 160
                ? (index.isMultiple(of: 2) ? 3_000 : -3_000)
                : 0
            withUnsafeBytes(of: sample.littleEndian) {
                pcm.append(contentsOf: $0)
            }
        }
        return AudioBuffer(
            data: WAVEncoder.encode(
                pcmData: pcm,
                sampleRate: sampleRate,
                channels: 1,
                bitsPerSample: 16),
            duration: 4,
            sampleRate: sampleRate,
            channels: 1,
            bitsPerSample: 16)
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
        transcriptBuffer: TranscriptBuffer? = nil,
        localMode: Bool = false,
        onSessionExpired: (@Sendable () -> Void)? = nil,
        cloudRecordingLimitSleep: @escaping @Sendable (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        }
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
            streamingProvider: streamingProvider,
            onSessionExpired: onSessionExpired,
            localMode: localMode,
            cloudRecordingLimitSleep: cloudRecordingLimitSleep
        )
        return (
            pipeline, audio, contextProvider, dictation,
            streamingProvider, textInjector, coordinator
        )
    }

    // MARK: - Cloud recording limit

    func testCompleteAlreadyCancelledBeforeEntryDrainsRecording() async {
        let entryGate = SuspensionGate()
        let (pipeline, audio, _, dictation, streaming, injector, coordinator) =
            makeStreamingPipeline()

        await pipeline.activate()
        let recordingStarted = await waitUntil { audio.startCallCount == 1 }
        XCTAssertTrue(recordingStarted)

        let completeTask = Task {
            await entryGate.waitForRelease()
            await pipeline.complete()
        }
        await entryGate.waitUntilEntered()
        completeTask.cancel()
        await entryGate.release()
        await completeTask.value

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testCompleteCancellationDuringSetupDrainsProcessing() async {
        let setupGate = SuspensionGate()
        let audio = GatedStartAudioProvider(startGate: setupGate)
        let dictation = MockBatchProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: dictation,
            textInjector: injector,
            coordinator: coordinator)

        await pipeline.activate()
        await setupGate.waitUntilEntered()

        let completeTask = Task { await pipeline.complete() }
        let processingStarted = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(processingStarted)

        completeTask.cancel()
        await setupGate.release()
        await completeTask.value

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testExplicitCancelInvalidatesManualCompleteSuspendedDuringSetup() async {
        let setupGate = SuspensionGate()
        let cancelCompletion = AsyncCompletionProbe()
        let audio = GatedStartAudioProvider(startGate: setupGate)
        let dictation = MockBatchProvider(stubbedText: "Late dictation")
        let streaming = MockStreamingProvider(stubbedText: "Late streaming result")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: dictation,
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: streaming)

        await pipeline.activate()
        await setupGate.waitUntilEntered()

        let completeTask = Task { await pipeline.complete() }
        let processingStarted = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(processingStarted)

        let cancelTask = Task {
            await pipeline.cancel()
            await cancelCompletion.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelCallCount > 0
        }
        XCTAssertTrue(cancellationEntered)
        let completedBeforeSetupRelease = await cancelCompletion.hasCompleted()
        XCTAssertFalse(completedBeforeSetupRelease)

        await setupGate.release()
        await cancelTask.value
        await completeTask.value

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testCompleteEnteringDuringCancellationDrainIsRejected() async {
        let cancelGate = SuspensionGate()
        let completeCompletion = AsyncCompletionProbe()
        let batch = MockBatchProvider(stubbedText: "Late dictation")
        let streaming = MockStreamingProvider(stubbedText: "Late streaming result")
        streaming.cancelStreamingHook = {
            if streaming.cancelCallCount == 1 {
                await cancelGate.waitForRelease()
            }
        }
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: batch,
            streamingProvider: streaming)

        await pipeline.activate()
        let setupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(setupFinished)

        let cancelTask = Task { await pipeline.cancel() }
        await cancelGate.waitUntilEntered()
        let stateWhileDrainBlocked = await coordinator.state
        XCTAssertEqual(stateWhileDrainBlocked, .recording)

        let completeTask = Task {
            await pipeline.complete()
            await completeCompletion.markCompleted()
        }
        var completeReturned = false
        for _ in 0..<10_000 {
            if await completeCompletion.hasCompleted() {
                completeReturned = true
                break
            }
            await Task.yield()
        }

        XCTAssertTrue(completeReturned)
        let stateAfterLateComplete = await coordinator.state
        XCTAssertEqual(stateAfterLateComplete, .recording)
        XCTAssertEqual(batch.dictateCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)

        await cancelGate.release()
        await cancelTask.value
        await completeTask.value
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testStaleManualCompleteCannotCancelReplacementRecording() async {
        let handoffGate = SuspensionGate()
        let activationWaitProbe = CompletionWaitProbe()
        let activationCompletion = AsyncCompletionProbe()
        let audio = makeStreamingAudioProvider()
        let dictation = MockBatchProvider(stubbedText: "Stale dictation")
        let streaming = MockStreamingProvider(stubbedText: "Stale streaming result")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: dictation,
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: streaming,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            completionWillHandoff: {
                await handoffGate.waitForRelease()
            },
            activationDidBeginWaitingForCompletion: {
                activationWaitProbe.markWaiting()
            })

        await pipeline.activate()
        let firstSetupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(firstSetupFinished)

        let staleCompleteTask = Task { await pipeline.complete() }
        await handoffGate.waitUntilEntered()
        await pipeline.cancel()

        let cancelledState = await coordinator.state
        XCTAssertEqual(cancelledState, .idle)

        let replacementActivationTask = Task {
            await pipeline.activate()
            await activationCompletion.markCompleted()
        }
        let activationReachedBarrierOrStarted = await waitUntil {
            activationWaitProbe.hasWaiter || audio.startCallCount == 2
        }
        XCTAssertTrue(activationReachedBarrierOrStarted)
        XCTAssertTrue(activationWaitProbe.hasWaiter)
        XCTAssertEqual(audio.startCallCount, 1)
        let completedWhileStaleOwnerActive = await activationCompletion.hasCompleted()
        XCTAssertFalse(completedWhileStaleOwnerActive)

        await handoffGate.release()
        await staleCompleteTask.value
        await replacementActivationTask.value

        let replacementStarted = await waitUntil {
            audio.startCallCount == 2 && streaming.startCallCount == 2
        }
        XCTAssertTrue(replacementStarted)

        let stateAfterStaleCompletion = await coordinator.state
        XCTAssertEqual(stateAfterStaleCompletion, .recording)
        XCTAssertTrue(audio.isRecording)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.cancel()
    }

    func testReplacementActivationWaitsForStaleEarlySilenceCleanup() async {
        let cleanupGate = SuspensionGate()
        let activationWaitProbe = CompletionWaitProbe()
        let activationCompletion = AsyncCompletionProbe()
        let audio = makeStreamingAudioProvider()
        audio.stubbedPeakRMS = 0.001
        let dictation = MockBatchProvider(stubbedText: "Unexpected dictation")
        let streaming = MockStreamingProvider(stubbedText: "Unexpected streaming result")
        streaming.cancelStreamingHook = {
            if streaming.cancelCallCount == 1 {
                await cleanupGate.waitForRelease()
            }
        }
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: dictation,
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: streaming,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            activationDidBeginWaitingForCompletion: {
                activationWaitProbe.markWaiting()
            })

        await pipeline.activate()
        let firstSetupFinished = await waitUntil {
            audio.startCallCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(firstSetupFinished)

        let staleCompleteTask = Task { await pipeline.complete() }
        await cleanupGate.waitUntilEntered()
        await pipeline.cancel()

        let replacementActivationTask = Task {
            await pipeline.activate()
            await activationCompletion.markCompleted()
        }
        let activationReachedBarrierOrStarted = await waitUntil {
            activationWaitProbe.hasWaiter || audio.startCallCount == 2
        }
        XCTAssertTrue(activationReachedBarrierOrStarted)
        XCTAssertTrue(activationWaitProbe.hasWaiter)
        XCTAssertEqual(audio.startCallCount, 1)
        let completedWhileStaleOwnerActive = await activationCompletion.hasCompleted()
        XCTAssertFalse(completedWhileStaleOwnerActive)

        await cleanupGate.release()
        await staleCompleteTask.value
        await replacementActivationTask.value

        let replacementStarted = await waitUntil {
            audio.startCallCount == 2 && streaming.startCallCount == 2
        }
        XCTAssertTrue(replacementStarted)
        let replacementState = await coordinator.state
        XCTAssertEqual(replacementState, .recording)
        XCTAssertTrue(audio.isRecording)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.cancel()
    }

    func testCancelDoesNotAwaitClaimedCompletionDuringSetupDrain() async {
        let sleepGate = RecordingLimitSleepGate()
        let setupGate = SuspensionGate()
        let cancelCompletion = AsyncCompletionProbe()
        let audio = GatedStartAudioProvider(startGate: setupGate)
        let streaming = MockStreamingProvider()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: MockBatchProvider(),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            streamingProvider: streaming,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        await setupGate.waitUntilEntered()
        let automaticCompletionArmed = await waitUntil {
            sleepGate.callCount == 1
        }
        XCTAssertTrue(automaticCompletionArmed)

        sleepGate.release()
        let processingStarted = await waitUntilState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(processingStarted)

        let cancelTask = Task {
            await pipeline.cancel()
            await cancelCompletion.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelCallCount > 0
        }
        XCTAssertTrue(cancellationEntered)
        await setupGate.release()

        var cancellationCompleted = false
        for _ in 0..<10_000 {
            if await cancelCompletion.hasCompleted() {
                cancellationCompleted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(cancellationCompleted)
        if cancellationCompleted {
            await cancelTask.value
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(audio.isRecording)
    }

    func testCloudRecordingLimitCompletesWithExactWAVAndLateReleaseIsNoOp() async {
        let sleepGate = RecordingLimitSleepGate()
        let audio = makeStreamingAudioProvider()
        // Timer scheduling is not a correctness boundary. Even a capture that
        // exceeds the Realtime hard guard must reach whole-WAV recovery intact.
        let sourcePCM = Data(
            repeating: 0x01,
            count: 310 * 16_000 * MemoryLayout<Int16>.size + 4_096)
        let expectedWAV = WAVEncoder.encode(
            pcmData: sourcePCM,
            sampleRate: 16_000,
            channels: 1,
            bitsPerSample: 16)
        audio.stubbedBuffer = AudioBuffer(
            data: expectedWAV,
            duration: WAVEncoder.duration(
                byteCount: sourcePCM.count,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16),
            sampleRate: 16_000,
            channels: 1,
            bitsPerSample: 16)
        let batch = MockBatchProvider(stubbedText: "Recovered complete dictation")
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = OpenAIRealtimeCommitSession.Failure
            .hardBoundaryHasContinuation
        let (pipeline, _, _, _, _, injector, coordinator) = makeStreamingPipeline(
            audioProvider: audio,
            batchProvider: batch,
            streamingProvider: streaming,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let armed = await waitUntil {
            sleepGate.callCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(armed)
        XCTAssertEqual(sleepGate.requestedDurations, [.seconds(300)])

        sleepGate.release()
        let injected = await waitUntil { injector.injectionCount == 1 }
        let returnedToIdle = await waitUntilState(.idle, coordinator: coordinator)
        let finalState = await coordinator.state
        XCTAssertTrue(injected)
        XCTAssertTrue(returnedToIdle)
        XCTAssertEqual(batch.lastReceivedAudio, expectedWAV)
        XCTAssertEqual(injector.lastInjectedText, "Recovered complete dictation")
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(sleepGate.observedCancellation, false)

        // The physical key release arrives after automatic completion.
        await pipeline.complete()
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(batch.dictateCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testManualCompleteCancelsCloudRecordingLimit() async {
        let sleepGate = RecordingLimitSleepGate()
        let (pipeline, _, _, _, _, injector, _) = makeStreamingPipeline(
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let armed = await waitUntil { sleepGate.callCount == 1 }
        XCTAssertTrue(armed)

        await pipeline.complete()
        sleepGate.release()
        let timerReturned = await waitUntil { sleepGate.observedCancellation != nil }

        XCTAssertTrue(timerReturned)
        XCTAssertEqual(sleepGate.observedCancellation, true)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testCancelCancelsCloudRecordingLimit() async {
        let sleepGate = RecordingLimitSleepGate()
        let (pipeline, audio, _, _, streaming, injector, coordinator) =
            makeStreamingPipeline(cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let armed = await waitUntil {
            sleepGate.callCount == 1 && audio.startCallCount == 1
        }
        XCTAssertTrue(armed)

        await pipeline.cancel()
        sleepGate.release()
        let timerReturned = await waitUntil { sleepGate.observedCancellation != nil }
        let finalState = await coordinator.state

        XCTAssertTrue(timerReturned)
        XCTAssertEqual(sleepGate.observedCancellation, true)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
        XCTAssertEqual(finalState, .idle)
    }

    func testRetireCancelsCloudRecordingLimit() async {
        let sleepGate = RecordingLimitSleepGate()
        let (pipeline, _, _, _, streaming, injector, _) = makeStreamingPipeline(
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let armed = await waitUntil { sleepGate.callCount == 1 }
        XCTAssertTrue(armed)

        await pipeline.retire()
        sleepGate.release()
        let timerReturned = await waitUntil { sleepGate.observedCancellation != nil }

        XCTAssertTrue(timerReturned)
        XCTAssertEqual(sleepGate.observedCancellation, true)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testLocalRecordingDoesNotArmCloudRecordingLimit() async {
        let sleepGate = RecordingLimitSleepGate()
        let (pipeline, _, _, _, streaming, injector, _) = makeStreamingPipeline(
            localMode: true,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let started = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(sleepGate.callCount, 0)

        await pipeline.complete()

        XCTAssertEqual(sleepGate.callCount, 0)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testCancelledOldLimitCannotCompleteNewRecordingGeneration() async {
        let sleepGate = MultiRecordingLimitSleepGate()
        let (pipeline, audio, _, _, streaming, injector, coordinator) =
            makeStreamingPipeline(cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let firstArmed = await waitUntil {
            sleepGate.callCount == 1 && audio.startCallCount == 1
        }
        XCTAssertTrue(firstArmed)
        await pipeline.cancel()
        let stopCallCountAfterCancel = audio.stopCallCount

        await pipeline.activate()
        let secondArmed = await waitUntil {
            sleepGate.callCount == 2 && audio.startCallCount == 2
        }
        XCTAssertTrue(secondArmed)

        sleepGate.release(call: 0)
        let oldTimerReturned = await waitUntil {
            sleepGate.observedCancellation(for: 0) != nil
        }
        XCTAssertTrue(oldTimerReturned)
        XCTAssertEqual(sleepGate.observedCancellation(for: 0), true)
        let recordingState = await coordinator.state
        XCTAssertEqual(recordingState, .recording)
        XCTAssertEqual(audio.stopCallCount, stopCallCountAfterCancel)

        await pipeline.complete()
        sleepGate.release(call: 1)
        let currentTimerReturned = await waitUntil {
            sleepGate.observedCancellation(for: 1) != nil
        }
        XCTAssertTrue(currentTimerReturned)
        XCTAssertEqual(sleepGate.observedCancellation(for: 1), true)
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(audio.stopCallCount, stopCallCountAfterCancel + 1)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testCancelDrainsAutomaticCompletionDuringClaimHandoff() async {
        let sleepGate = RecordingLimitSleepGate()
        let claimGate = RecordingLimitClaimGate()
        let cancelCompletion = AsyncCompletionProbe()
        let streaming = MockStreamingProvider()
        let pipeline = DictationPipeline(
            audioProvider: makeStreamingAudioProvider(),
            contextProvider: MockAppContextProvider(),
            batchProvider: MockBatchProvider(),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator(),
            streamingProvider: streaming,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            },
            cloudRecordingLimitDidClaim: {
                await claimGate.pauseAfterClaim()
            })

        await pipeline.activate()
        let armed = await waitUntil { sleepGate.callCount == 1 }
        XCTAssertTrue(armed)
        sleepGate.release()
        await claimGate.waitUntilClaimed()

        let cancelTask = Task {
            await pipeline.cancel()
            await cancelCompletion.markCompleted()
        }
        let cancellationEntered = await waitUntil {
            streaming.cancelCallCount > 0
        }
        XCTAssertTrue(cancellationEntered)
        await Task.yield()
        let completedBeforeRelease = await cancelCompletion.hasCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await claimGate.release()
        await cancelTask.value

        let observedCancellation = await claimGate.cancellationObserved()
        XCTAssertEqual(observedCancellation, true)
    }

    func testReactivationWaitsForClaimedAutomaticCompletion() async {
        let sleepGate = MultiRecordingLimitSleepGate()
        let claimGate = RecordingLimitClaimGate()
        let activationCompletion = AsyncCompletionProbe()
        let audio = makeStreamingAudioProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: MockBatchProvider(),
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: MockStreamingProvider(),
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            },
            cloudRecordingLimitDidClaim: {
                await claimGate.pauseAfterClaim()
            })

        await pipeline.activate()
        let firstArmed = await waitUntil {
            sleepGate.callCount == 1 && audio.startCallCount == 1
        }
        XCTAssertTrue(firstArmed)
        sleepGate.release(call: 0)
        await claimGate.waitUntilClaimed()

        // The physical release finishes this recording while the automatic
        // completion owns, but has not yet entered, its complete() call.
        await pipeline.complete()
        XCTAssertEqual(injector.injectionCount, 1)
        let stateAfterManualCompletion = await coordinator.state
        XCTAssertEqual(stateAfterManualCompletion, .idle)

        let activationTask = Task {
            await pipeline.activate()
            await activationCompletion.markCompleted()
        }
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeClaimRetired =
            await activationCompletion.hasCompleted()
        XCTAssertFalse(completedBeforeClaimRetired)

        await claimGate.release()
        await activationTask.value
        let secondArmed = await waitUntil {
            sleepGate.callCount == 2 && audio.startCallCount == 2
        }
        XCTAssertTrue(secondArmed)
        let reactivatedState = await coordinator.state
        XCTAssertEqual(reactivatedState, .recording)

        await pipeline.complete()
        sleepGate.release(call: 1)
        XCTAssertEqual(injector.injectionCount, 2)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testCancelDrainsAutomaticCompletionBlockedInBatch() async {
        let sleepGate = MultiRecordingLimitSleepGate()
        let batch = CancellationInsensitiveBatchProvider(
            firstResult: "late result",
            retryResult: "next generation")
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        streaming.cancelStreamingHook = {
            await batch.releaseFirstCallIfStarted()
        }
        let audio = makeStreamingAudioProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: batch,
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: streaming,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let automaticCompletionArmed = await waitUntil {
            sleepGate.callCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(automaticCompletionArmed)
        sleepGate.release(call: 0)
        await batch.waitUntilFirstCallStarts()

        await pipeline.cancel()
        let cancelledState = await coordinator.state
        XCTAssertEqual(cancelledState, .idle)
        XCTAssertEqual(injector.injectionCount, 0)
        XCTAssertEqual(audio.stopCallCount, 1)

        streaming.stubbedStartError = nil
        await pipeline.activate()
        let nextGenerationArmed = await waitUntil {
            sleepGate.callCount == 2 && streaming.startCallCount == 2
        }
        XCTAssertTrue(nextGenerationArmed)
        await pipeline.complete()
        sleepGate.release(call: 1)

        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Mock streaming dictation")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testRetireDrainsAutomaticCompletionBlockedInBatch() async {
        let sleepGate = RecordingLimitSleepGate()
        let batch = CancellationInsensitiveBatchProvider(
            firstResult: "late result",
            retryResult: "unused")
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        streaming.cancelStreamingHook = {
            await batch.releaseFirstCallIfStarted()
        }
        let audio = makeStreamingAudioProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            batchProvider: batch,
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: streaming,
            cloudRecordingLimitSleep: { duration in
                await sleepGate.sleep(for: duration)
            })

        await pipeline.activate()
        let automaticCompletionArmed = await waitUntil {
            sleepGate.callCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(automaticCompletionArmed)
        sleepGate.release()
        await batch.waitUntilFirstCallStarts()

        await pipeline.retire()

        let retiredState = await coordinator.state
        XCTAssertEqual(retiredState, .idle)
        XCTAssertEqual(injector.injectionCount, 0)
        XCTAssertEqual(sleepGate.observedCancellation, false)
        await pipeline.activate()
        XCTAssertEqual(streaming.startCallCount, 1)
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func waitUntilState(
        _ expected: RecordingState,
        coordinator: RecordingCoordinator
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await coordinator.state == expected { return true }
            await Task.yield()
        }
        return await coordinator.state == expected
    }

    /// Emit PCM chunks in the background so the forwarding operation has data.
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

        // Emit chunks and give the forwarding operation time to process.
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

    func testCompleteDrainsQueuedAudioBeforeStreamingFinish() async {
        let firstChunk = makeNonSilentPCMChunk(sampleCount: 400)
        let finalChunk = makeNonSilentPCMChunk(sampleCount: 600)
        let sendGate = PipelineSendGate()
        let streaming = MockStreamingProvider(stubbedText: "Complete dictation")
        streaming.sendAudioHook = { data in
            await sendGate.send(data)
        }
        let dictation = MockBatchProvider(stubbedText: "Unexpected fallback")
        let (pipeline, audio, _, _, _, injector, _) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        guard didStart else {
            await pipeline.cancel()
            return
        }
        audio.emitPCMChunk(firstChunk)
        await sendGate.waitUntilFirstSendStarts()
        audio.emitPCMChunk(finalChunk)

        let completeTask = Task { await pipeline.complete() }
        let captureStopped = await waitUntil { audio.stopCallCount == 1 }
        XCTAssertTrue(captureStopped)
        XCTAssertEqual(streaming.finishCallCount, 0)

        await sendGate.releaseFirstSend()
        await completeTask.value

        let sentChunks = await sendGate.sentChunks
        XCTAssertEqual(sentChunks, [firstChunk, finalChunk])
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Complete dictation")
    }

    func testCancelClosesAndJoinsBlockedForwardingWithoutPublishing() async {
        let sendGate = PipelineSendGate()
        let streaming = MockStreamingProvider(stubbedText: "Untrusted partial text")
        streaming.sendAudioHook = { data in
            await sendGate.send(data)
        }
        streaming.cancelStreamingHook = {
            await sendGate.releaseFirstSend()
        }
        let dictation = MockBatchProvider(stubbedText: "Unexpected fallback")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        guard didStart else {
            await pipeline.cancel()
            return
        }
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        await sendGate.waitUntilFirstSendStarts()

        await pipeline.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertGreaterThanOrEqual(streaming.cancelCallCount, 1)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testExplicitCancelDiscardsRecoveryPublishedByCancelledBatch() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        let dictation = MockBatchProvider(stubbedText: "Late result")
        dictation.stubbedDelay = 60
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        let completeTask = Task { await pipeline.complete() }
        let batchStarted = await waitUntil { dictation.dictateCallCount == 1 }
        XCTAssertTrue(batchStarted)

        await pipeline.cancel()
        await completeTask.value
        emitTask.cancel()

        let cancelledState = await coordinator.state
        XCTAssertEqual(cancelledState, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 0)

        dictation.stubbedDelay = 0
        _ = await coordinator.startRecording()
        _ = await coordinator.stopRecording()
        _ = await coordinator.expireSession()
        await pipeline.retryDictation()

        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Explicit cancel must not leave hidden recovery audio")
        XCTAssertEqual(injector.injectionCount, 0)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testExplicitCancelRejectsLateBatchAuthenticationFailure() async {
        let audio = makeStreamingAudioProvider()
        let context = MockAppContextProvider()
        let dictation = CancellationInsensitiveAuthenticationFailureProvider()
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        streaming.cancelStreamingHook = {
            await dictation.releaseCallIfStarted()
        }
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let sessionExpired = expectation(description: "late session expiry")
        sessionExpired.isInverted = true
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            batchProvider: dictation,
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: streaming,
            onSessionExpired: { sessionExpired.fulfill() })

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        let completeTask = Task { await pipeline.complete() }
        await dictation.waitUntilCallStarts()

        await pipeline.cancel()
        await completeTask.value
        emitTask.cancel()
        await fulfillment(of: [sessionExpired], timeout: 0.1)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testOwnerCancellationRejectsLateBatchResultAndPreservesCompleteWAV() async {
        let audio = makeStreamingAudioProvider()
        let context = MockAppContextProvider()
        let dictation = CancellationInsensitiveBatchProvider(
            firstResult: "Late plausible result",
            retryResult: "Recovered complete result")
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("offline")
        streaming.cancelStreamingHook = {
            await dictation.releaseFirstCallIfStarted()
        }
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            batchProvider: dictation,
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        let completeTask = Task { await pipeline.complete() }
        await dictation.waitUntilFirstCallStarts()

        completeTask.cancel()
        await completeTask.value
        emitTask.cancel()

        let failedState = await coordinator.state
        let firstReceivedAudio = await dictation.receivedAudio
        XCTAssertEqual(failedState, .dictationFailed)
        XCTAssertEqual(firstReceivedAudio, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        let allReceivedAudio = await dictation.receivedAudio
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(allReceivedAudio, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered complete result")
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

    func testStreamingStartFailureDoesNotRejectSparseAudibleWAV() async {
        let audio = MockAudioProvider(stubbedBuffer: makeSparseAudibleBuffer())
        audio.enablePCMStream = true
        audio.stubbedPeakRMS = 0.1
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("connection refused")
        let dictation = MockBatchProvider(stubbedText: "Sparse setup recovery")
        let (pipeline, _, _, _, _, injector, coordinator) = makeStreamingPipeline(
            audioProvider: audio,
            batchProvider: dictation,
            streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [audio.stubbedBuffer.data])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Sparse setup recovery")
    }

    func testStreamingStartFailureAndEmptyBatchPreserveCompleteWAV() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedStartError = DictationError.networkError("connection refused")
        let dictation = MockBatchProvider(stubbedText: "")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        dictation.stubbedText = "Recovered setup fallback"
        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered setup fallback")
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
        XCTAssertEqual(dictation.lastReceivedAudio, audio.stubbedBuffer.data)
        XCTAssertEqual(injector.lastInjectedText, "Batch recovery")
    }

    func testStreamingEmptyResultUsesBatchFallback() async {
        // When streaming returns empty, the serial batch fallback is used.
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
        XCTAssertEqual(dictation.lastReceivedAudio, audio.stubbedBuffer.data)
        XCTAssertEqual(injector.lastInjectedText, "Batch result")
    }

    func testBothEmptyResultsPreserveCompleteWAVForRetry() async {
        let streaming = MockStreamingProvider(stubbedText: "")
        let dictation = MockBatchProvider(stubbedText: "")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .dictationFailed)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.retryDictation()

        let stillRecoverableState = await coordinator.state
        XCTAssertEqual(stillRecoverableState, .dictationFailed)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        dictation.stubbedText = "Recovered after empty results"
        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(
            dictation.receivedAudioData,
            [completeWAV, completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered after empty results")
    }

    func testBothWhitespaceOnlyResultsPreserveCompleteWAVForRetry() async {
        let streaming = MockStreamingProvider(stubbedText: "   \n  ")
        let dictation = MockBatchProvider(stubbedText: "  \t  ")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .dictationFailed)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        dictation.stubbedText = "Recovered after whitespace results"
        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered after whitespace results")
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

    func testRecoveryInjectionFailureDiscardsAcceptedAudio() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("stream failed")
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.networkError("batch failed")
        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            textInjector: injector,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        dictation.stubbedError = nil
        dictation.stubbedText = "accepted recovery text"
        await pipeline.retryDictation()

        let failedState = await coordinator.state
        let stored = await buffer.lastTranscript
        XCTAssertEqual(failedState, .injectionFailed)
        XCTAssertEqual(stored, "accepted recovery text")
        XCTAssertEqual(dictation.dictateCallCount, 2)

        await coordinator.reset()
        _ = await coordinator.startRecording()
        _ = await coordinator.stopRecording()
        _ = await coordinator.failDictation()
        await pipeline.retryDictation()

        XCTAssertEqual(
            dictation.dictateCallCount, 2,
            "Accepted text must replace the WAV as the recovery artifact")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
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

    func testStreamingSendErrorRejectsPartialAndBatchesCompleteWAV() async {
        let streaming = MockStreamingProvider(stubbedText: "Plausible partial result")
        streaming.stubbedSendError = DictationError.networkError("send failed")
        let dictation = MockBatchProvider(stubbedText: "Complete batch recovery")

        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        let didSend = await waitUntil { streaming.sendCallCount == 1 }
        XCTAssertTrue(didSend)

        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertGreaterThanOrEqual(streaming.cancelCallCount, 1)
        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(dictation.lastReceivedAudio, completeWAV)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Complete batch recovery")
    }

    func testStreamingRecoveryDoesNotRejectSparseAudibleWAV() async {
        let completeBuffer = makeSparseAudibleBuffer()
        let audio = MockAudioProvider(stubbedBuffer: completeBuffer)
        audio.enablePCMStream = true
        audio.stubbedPeakRMS = 0.1
        let streaming = MockStreamingProvider(stubbedText: "")
        streaming.stubbedSendError = DictationError.networkError("send failed")
        let dictation = MockBatchProvider(stubbedText: "Brief complete recovery")
        let (pipeline, _, _, _, _, injector, coordinator) = makeStreamingPipeline(
            audioProvider: audio,
            batchProvider: dictation,
            streamingProvider: streaming)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        let didSend = await waitUntil { streaming.sendCallCount == 1 }
        XCTAssertTrue(didSend)

        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertEqual(dictation.receivedAudioData, [completeBuffer.data])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Brief complete recovery")
    }

    func testLocalSendErrorDoesNotFinalizeOrInjectPartialText() async {
        let streaming = MockStreamingProvider(stubbedText: "Incomplete local text")
        streaming.stubbedSendError = DictationError.networkError("send failed")
        let dictation = MockBatchProvider(stubbedText: "Unexpected cloud recovery")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            localMode: true)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        let didSend = await waitUntil { streaming.sendCallCount == 1 }
        XCTAssertTrue(didSend)

        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .dictationFailed)
        XCTAssertEqual(streaming.finishCallCount, 0)
        XCTAssertGreaterThanOrEqual(streaming.cancelCallCount, 1)
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
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

    func testCloudPipelinePublishesOnlyOneFinalResult() async {
        let streaming = MockStreamingProvider(stubbedText: "Complete cloud result")
        let (pipeline, _, _, _, _, injector, _) = makeStreamingPipeline(
            streamingProvider: streaming)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)

        XCTAssertFalse(
            streaming.hasChunkHandler,
            "Cloud providers must not publish irreversible intermediate text")
        await streaming.emitChunk("Untrusted intermediate text")
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.complete()

        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Complete cloud result")
    }

    func testLocalPipelineDoesNotSetChunkHandler() async {
        let streaming = MockStreamingProvider()
        let (pipeline, _, _, _, _, _, _) = makeStreamingPipeline(
            streamingProvider: streaming,
            localMode: true)

        await pipeline.activate()
        let didStart = await waitUntil { streaming.startCallCount == 1 }
        XCTAssertTrue(didStart)
        XCTAssertFalse(
            streaming.hasChunkHandler,
            "Local assembles one final result and does not inject mid-stream")
        await pipeline.cancel()
    }

    // MARK: - Chunk handler cleared after complete

    func testChunkHandlerClearedAfterComplete() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline(localMode: true)

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

    func testBothStreamingAndBatchFailPreservesCompleteWAVForRetry() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.networkError("http died")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation, streamingProvider: streaming)
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .dictationFailed)
        XCTAssertEqual(dictation.lastReceivedAudio, completeWAV)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "No text should be injected when both paths fail")

        dictation.stubbedError = nil
        dictation.stubbedText = "Recovered complete dictation"
        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 2)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered complete dictation")
    }

    func testBatch401PreservesCompleteWAVAcrossCredentialRetry() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.authenticationFailed
        let callback = expectation(description: "session expired")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            onSessionExpired: { callback.fulfill() })
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()
        await fulfillment(of: [callback], timeout: 2)

        let expiredState = await coordinator.state
        XCTAssertEqual(expiredState, .sessionExpired)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        dictation.stubbedError = nil
        dictation.stubbedText = "Recovered after sign in"
        await pipeline.presentRecoveryAfterAuthentication()

        let readyState = await coordinator.state
        XCTAssertEqual(readyState, .dictationFailed)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)

        await pipeline.retryDictation()

        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Recovered after sign in")
    }

    func testRetryAuthenticationFailureReopensSessionRecovery() async {
        let streaming = MockStreamingProvider()
        streaming.stubbedFinishError = DictationError.networkError("ws died")
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.networkError("http died")
        let secondExpiry = expectation(description: "replacement key rejected")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            batchProvider: dictation,
            streamingProvider: streaming,
            onSessionExpired: { secondExpiry.fulfill() })
        let completeWAV = audio.stubbedBuffer.data

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        dictation.stubbedError = DictationError.authenticationFailed
        await pipeline.retryDictation()
        await fulfillment(of: [secondExpiry], timeout: 2)

        let state = await coordinator.state
        XCTAssertEqual(state, .sessionExpired)
        XCTAssertEqual(dictation.receivedAudioData, [completeWAV, completeWAV])
        XCTAssertEqual(injector.injectionCount, 0)
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

private actor PipelineSendGate {
    private var firstSendStarted = false
    private var firstSendReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sentChunks: [Data] = []

    func send(_ data: Data) async {
        sentChunks.append(data)
        guard sentChunks.count == 1 else { return }
        firstSendStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        guard !firstSendReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilFirstSendStarts() async {
        guard !firstSendStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstSend() {
        guard !firstSendReleased else { return }
        firstSendReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor CancellationInsensitiveBatchProvider: BatchDictationProviding {
    private let firstResult: String
    private let retryResult: String
    private var firstCallStarted = false
    private var firstCallReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var receivedAudio: [Data] = []

    init(firstResult: String, retryResult: String) {
        self.firstResult = firstResult
        self.retryResult = retryResult
    }

    func dictate(audio: Data, context: AppContext) async throws -> String {
        receivedAudio.append(audio)
        guard receivedAudio.count == 1 else { return retryResult }

        firstCallStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }

        if !firstCallReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return firstResult
    }

    func waitUntilFirstCallStarts() async {
        guard !firstCallStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstCallIfStarted() {
        guard firstCallStarted, !firstCallReleased else { return }
        firstCallReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private actor CancellationInsensitiveAuthenticationFailureProvider:
    BatchDictationProviding
{
    private var callStarted = false
    private var callReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func dictate(audio: Data, context: AppContext) async throws -> String {
        callStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }

        if !callReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        throw DictationError.authenticationFailed
    }

    func waitUntilCallStarts() async {
        guard !callStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseCallIfStarted() {
        guard callStarted, !callReleased else { return }
        callReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}
