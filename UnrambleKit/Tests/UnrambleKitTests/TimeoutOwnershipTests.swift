import XCTest

@testable import UnrambleKit

private actor CancellationInsensitiveGate {
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

private enum RecordedTimeoutResult: Equatable {
    case notRecorded
    case timedOut
    case value(String)
}

private actor TimeoutResultProbe {
    private var result: RecordedTimeoutResult = .notRecorded

    func record(_ result: String?) {
        self.result = result.map(RecordedTimeoutResult.value) ?? .timedOut
    }

    func recordedResult() -> RecordedTimeoutResult {
        result
    }
}

private actor ActivationCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func hasCompleted() -> Bool {
        completed
    }
}

private final class WatchdogInvocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    var callCount: Int {
        lock.withLock { durations.count }
    }

    func record(_ duration: Duration) {
        lock.withLock { durations.append(duration) }
    }
}

private final class GatedLocalStreamingProvider: LocalAudioReplayProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let startGate: CancellationInsensitiveGate
    private let result: String
    private var activeSessionID: DictationSessionID?
    private var _startCallCount = 0
    private var _finishCallCount = 0
    private var _cancelCallCount = 0
    private var _receivedAudio: [Data] = []

    init(startGate: CancellationInsensitiveGate, result: String) {
        self.startGate = startGate
        self.result = result
    }

    var startCallCount: Int { lock.withLock { _startCallCount } }
    var finishCallCount: Int { lock.withLock { _finishCallCount } }
    var cancelCallCount: Int { lock.withLock { _cancelCallCount } }
    var receivedAudio: [Data] { lock.withLock { _receivedAudio } }

    func startStreaming(
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity: MicProximity
    ) async throws {
        lock.withLock {
            _startCallCount += 1
            activeSessionID = sessionID
        }
        await startGate.waitForRelease()
    }

    func sendAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID
    ) async throws {
        let accepted = lock.withLock {
            guard activeSessionID == sessionID else { return false }
            _receivedAudio.append(pcmData)
            return true
        }
        guard accepted else { throw CancellationError() }
    }

    func finishStreaming(
        sessionID: DictationSessionID
    ) async throws -> String {
        let accepted = lock.withLock {
            guard activeSessionID == sessionID else { return false }
            _finishCallCount += 1
            activeSessionID = nil
            return true
        }
        guard accepted else { throw CancellationError() }
        return result
    }

    func cancelActiveStreaming() async {
        guard let sessionID = lock.withLock({ activeSessionID }) else { return }
        await cancelStreaming(sessionID: sessionID)
    }

    func cancelStreaming(sessionID: DictationSessionID) async {
        lock.withLock {
            guard activeSessionID == sessionID else { return }
            _cancelCallCount += 1
            activeSessionID = nil
        }
    }

    func replayCapturedAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity: MicProximity,
        silenceThreshold: Float
    ) async throws -> String {
        lock.withLock { _receivedAudio.append(pcmData) }
        return result
    }
}

final class TimeoutOwnershipTests: XCTestCase {
    func testDetachedOperationObservationReportsDeadline() async {
        let gate = CancellationInsensitiveGate()
        let operation = DetachedOperation {
            await gate.waitForRelease()
            return "late operation result"
        }

        await gate.waitUntilEntered()
        let observation = await operation.outcome(timeout: 0)

        guard case .deadline = observation else {
            return XCTFail("Expected deadline, got \(observation)")
        }

        await gate.release()
        _ = await operation.task.value
    }

    func testDetachedOperationObservationReportsCallerCancellation() async {
        let gate = CancellationInsensitiveGate()
        let operation = DetachedOperation {
            await gate.waitForRelease()
            return "late operation result"
        }
        await gate.waitUntilEntered()

        let observationTask = Task {
            await operation.outcome(timeout: 60)
        }
        observationTask.cancel()
        let observation = await observationTask.value

        guard case .cancelled = observation else {
            return XCTFail("Expected caller cancellation, got \(observation)")
        }

        await gate.release()
        _ = await operation.task.value
    }

    func testDetachedOperationReplaysCompletedValueToLaterObserver() async {
        let operation = DetachedOperation { "activation context" }

        let first = await operation.value(timeout: 0.1)
        let second = await operation.value(timeout: 0.1)

        XCTAssertEqual(first, "activation context")
        XCTAssertEqual(second, "activation context")
    }

    func testDetachedTimeoutReturnsAtDeadlineWhenOperationIgnoresCancellation() async {
        let gate = CancellationInsensitiveGate()
        let probe = TimeoutResultProbe()
        let returned = expectation(description: "timeout returned")

        let operation = DetachedOperation {
            await gate.waitForRelease()
            return "late operation result"
        }
        let timeoutTask = Task {
            let result = await operation.value(timeout: 0.01)
            await probe.record(result)
            returned.fulfill()
        }

        await gate.waitUntilEntered()
        let waiterResult = await XCTWaiter().fulfillment(
            of: [returned], timeout: 0.2)

        XCTAssertEqual(
            waiterResult,
            .completed,
            "The deadline must return without joining cancellation-insensitive work")

        await gate.release()
        _ = await operation.task.value
        await timeoutTask.value
        let recordedResult = await probe.recordedResult()

        XCTAssertEqual(
            recordedResult,
            .timedOut,
            "The elapsed deadline must win the race")
    }

    func testLocalCompletionRetainsCaptureUntilGatedSetupFinishes() async {
        let setupGate = CancellationInsensitiveGate()
        let watchdogProbe = WatchdogInvocationProbe()
        let activationCompletionProbe = ActivationCompletionProbe()
        let activationWaiting = expectation(
            description: "replacement waits for completion ownership")
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        let expectedText = "Exact local dictation"
        let streaming = GatedLocalStreamingProvider(
            startGate: setupGate,
            result: expectedText)
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { _ in },
            activationDidBeginWaitingForCompletion: {
                activationWaiting.fulfill()
            },
            audioSetupCompletionWatchdog: .zero,
            audioSetupCompletionSleep: { duration in
                watchdogProbe.record(duration)
            })

        let sessionID = await pipeline.activate()
        XCTAssertNotNil(sessionID)
        await setupGate.waitUntilEntered()

        let dictatedPCM = Data([0xB8, 0x0B, 0x48, 0xF4])
        audio.emitPCMChunk(dictatedPCM)

        let completion = Task {
            if let sessionID {
                await pipeline.complete(sessionID: sessionID)
            }
        }
        let enteredProcessing = await waitForState(
            .processing, coordinator: coordinator)
        XCTAssertTrue(enteredProcessing)
        let captureStoppedBeforeSetupRelease = await waitUntil {
            audio.stopCallCount == 1
        }

        let replacementActivation = Task {
            let replacementSessionID = await pipeline.activate()
            await activationCompletionProbe.markCompleted()
            return replacementSessionID
        }
        await fulfillment(of: [activationWaiting], timeout: 1)
        let replacementCompletedBeforeSetupRelease =
            await activationCompletionProbe.hasCompleted()
        XCTAssertFalse(
            replacementCompletedBeforeSetupRelease,
            "A replacement cannot overlap setup still owned by the completing session")
        XCTAssertTrue(
            captureStoppedBeforeSetupRelease,
            "Key release must stop local capture without waiting for model setup")
        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertEqual(streaming.startCallCount, 1)
        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(streaming.cancelCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
        let stateWhileSetupIsOwned = await coordinator.state
        XCTAssertEqual(stateWhileSetupIsOwned, .processing)

        await setupGate.release()
        await completion.value
        let replacementSessionID = await replacementActivation.value
        XCTAssertNotNil(
            replacementSessionID,
            "The queued replacement should be admitted after completion releases ownership")

        XCTAssertEqual(watchdogProbe.callCount, 0)
        XCTAssertEqual(streaming.receivedAudio, [dictatedPCM])
        XCTAssertEqual(streaming.finishCallCount, 1)
        XCTAssertEqual(streaming.cancelCallCount, 0)
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(injector.lastInjectedText, expectedText)
        XCTAssertEqual(injector.injectionCount, 1)
        let replacementState = await coordinator.state
        XCTAssertEqual(replacementState, .recording)

        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    private func waitForState(
        _ expected: RecordingState,
        coordinator: RecordingCoordinator
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await coordinator.state == expected { return true }
            await Task.yield()
        }
        return await coordinator.state == expected
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
