import XCTest

@testable import FreeFlowKit

final class RecordingCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    /// Assert the coordinator is in the expected state. Extracts the await
    /// into a local variable so it is not inside an XCTAssert autoclosure.
    private func assertState(
        _ coordinator: RecordingCoordinator,
        _ expected: RecordingState,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await coordinator.state
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() async {
        let coordinator = RecordingCoordinator()
        await assertState(coordinator, .idle)
    }

    // MARK: - Happy path: full cycle

    func testFullCycleIdleToRecordingToProcessingToInjectingToIdle() async {
        let coordinator = RecordingCoordinator()

        let started = await coordinator.startRecording()
        XCTAssertTrue(started)
        await assertState(coordinator, .recording)

        let stopped = await coordinator.stopRecording()
        XCTAssertTrue(stopped)
        await assertState(coordinator, .processing)

        let injecting = await coordinator.startInjecting()
        XCTAssertTrue(injecting)
        await assertState(coordinator, .injecting)

        let finished = await coordinator.finishInjecting()
        XCTAssertTrue(finished)
        await assertState(coordinator, .idle)
    }

    // MARK: - startRecording edge cases

    func testStartRecordingFromRecordingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()

        let result = await coordinator.startRecording()
        XCTAssertFalse(result)
        await assertState(coordinator, .recording)
    }

    func testStartRecordingFromProcessingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        let result = await coordinator.startRecording()
        XCTAssertFalse(result)
        await assertState(coordinator, .processing)
    }

    func testStartRecordingFromInjectingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()

        let result = await coordinator.startRecording()
        XCTAssertFalse(result)
        await assertState(coordinator, .injecting)
    }

    // MARK: - stopRecording edge cases

    func testStopRecordingFromIdleFails() async {
        let coordinator = RecordingCoordinator()

        let result = await coordinator.stopRecording()
        XCTAssertFalse(result)
        await assertState(coordinator, .idle)
    }

    func testStopRecordingFromProcessingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        let result = await coordinator.stopRecording()
        XCTAssertFalse(result)
        await assertState(coordinator, .processing)
    }

    func testStopRecordingFromInjectingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()

        let result = await coordinator.stopRecording()
        XCTAssertFalse(result)
        await assertState(coordinator, .injecting)
    }

    // MARK: - startInjecting edge cases

    func testStartInjectingFromIdleFails() async {
        let coordinator = RecordingCoordinator()

        let result = await coordinator.startInjecting()
        XCTAssertFalse(result)
        await assertState(coordinator, .idle)
    }

    func testStartInjectingFromRecordingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()

        let result = await coordinator.startInjecting()
        XCTAssertFalse(result)
        await assertState(coordinator, .recording)
    }

    func testStartInjectingFromInjectingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()

        let result = await coordinator.startInjecting()
        XCTAssertFalse(result)
        await assertState(coordinator, .injecting)
    }

    // MARK: - finishInjecting edge cases

    func testFinishInjectingFromIdleFails() async {
        let coordinator = RecordingCoordinator()

        let result = await coordinator.finishInjecting()
        XCTAssertFalse(result)
        await assertState(coordinator, .idle)
    }

    func testFinishInjectingFromRecordingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()

        let result = await coordinator.finishInjecting()
        XCTAssertFalse(result)
        await assertState(coordinator, .recording)
    }

    func testFinishInjectingFromProcessingSucceeds() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        let result = await coordinator.finishInjecting()
        XCTAssertTrue(result)
        await assertState(coordinator, .idle)
    }

    func testRetryDictationFromSessionExpiredIsRejected() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.expireSession()

        let retried = await coordinator.retryDictation()

        XCTAssertFalse(retried)
        await assertState(coordinator, .sessionExpired)
    }

    func testPrepareDictationRecoveryMakesRetryAvailable() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.expireSession()

        let prepared = await coordinator.prepareDictationRecovery()

        XCTAssertTrue(prepared)
        await assertState(coordinator, .dictationFailed)

        let retried = await coordinator.retryDictation()

        XCTAssertTrue(retried)
        await assertState(coordinator, .processing)
    }

    func testPrepareDictationRecoveryFromIdleIsRejected() async {
        let coordinator = RecordingCoordinator()

        let prepared = await coordinator.prepareDictationRecovery()

        XCTAssertFalse(prepared)
        await assertState(coordinator, .idle)
    }

    // MARK: - reset

    func testResetFromIdleRemainsIdle() async {
        let coordinator = RecordingCoordinator()
        await coordinator.reset()
        await assertState(coordinator, .idle)
    }

    func testResetFromRecording() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.reset()
        await assertState(coordinator, .idle)
    }

    func testResetFromProcessing() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.reset()
        await assertState(coordinator, .idle)
    }

    func testResetFromInjecting() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()
        await coordinator.reset()
        await assertState(coordinator, .idle)
    }

    // MARK: - Multiple cycles

    func testMultipleFullCycles() async {
        let coordinator = RecordingCoordinator()

        for _ in 0..<3 {
            await assertState(coordinator, .idle)
            await coordinator.startRecording()
            await assertState(coordinator, .recording)
            await coordinator.stopRecording()
            await assertState(coordinator, .processing)
            await coordinator.startInjecting()
            await assertState(coordinator, .injecting)
            await coordinator.finishInjecting()
            await assertState(coordinator, .idle)
        }
    }

    func testCycleAfterReset() async {
        let coordinator = RecordingCoordinator()

        // Start a cycle but reset midway.
        await coordinator.startRecording()
        await coordinator.reset()
        await assertState(coordinator, .idle)

        // A fresh cycle should work fine.
        let started = await coordinator.startRecording()
        XCTAssertTrue(started)
        let stopped = await coordinator.stopRecording()
        XCTAssertTrue(stopped)
        let injecting = await coordinator.startInjecting()
        XCTAssertTrue(injecting)
        let finished = await coordinator.finishInjecting()
        XCTAssertTrue(finished)
        await assertState(coordinator, .idle)
    }

    // MARK: - Double press simulation

    func testDoublePressWhileRecordingIsIgnored() async {
        let coordinator = RecordingCoordinator()

        let first = await coordinator.startRecording()
        XCTAssertTrue(first)

        let second = await coordinator.startRecording()
        XCTAssertFalse(second)

        // State should still be recording and the cycle should complete normally.
        await assertState(coordinator, .recording)
        await coordinator.stopRecording()
        await coordinator.startInjecting()
        await coordinator.finishInjecting()
        await assertState(coordinator, .idle)
    }

    func testPressWhileProcessingIsIgnored() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await assertState(coordinator, .processing)

        // Pressing during processing should fail.
        let result = await coordinator.startRecording()
        XCTAssertFalse(result)
        await assertState(coordinator, .processing)
    }

    func testPressWhileInjectingIsIgnored() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()
        await assertState(coordinator, .injecting)

        let result = await coordinator.startRecording()
        XCTAssertFalse(result)
        await assertState(coordinator, .injecting)
    }

    // MARK: - State stream observation

    func testStateStreamEmitsCurrentStateThenChanges() async {
        let coordinator = RecordingCoordinator()

        var collected: [RecordingState] = []
        let expectation = XCTestExpectation(description: "Collect state transitions")

        let streamTask = Task {
            for await state in await coordinator.stateStream {
                collected.append(state)
                if state == .injecting {
                    break
                }
            }
            expectation.fulfill()
        }

        // Small delay to let the stream subscribe.
        try? await Task.sleep(nanoseconds: 50_000_000)

        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()

        await fulfillment(of: [expectation], timeout: 2.0)
        streamTask.cancel()

        XCTAssertEqual(collected, [.idle, .recording, .processing, .injecting])
    }

    func testStateStreamEmitsResetTransitions() async {
        let coordinator = RecordingCoordinator()

        var collected: [RecordingState] = []
        let expectation = XCTestExpectation(description: "Collect reset transition")

        let streamTask = Task {
            var count = 0
            for await state in await coordinator.stateStream {
                collected.append(state)
                count += 1
                // Expect: idle, recording, idle (from reset)
                if count >= 3 {
                    break
                }
            }
            expectation.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        await coordinator.startRecording()
        await coordinator.reset()

        await fulfillment(of: [expectation], timeout: 2.0)
        streamTask.cancel()

        XCTAssertEqual(collected, [.idle, .recording, .idle])
    }

    func testMultipleStreamObserversReceiveAllTransitions() async {
        let coordinator = RecordingCoordinator()

        var collected1: [RecordingState] = []
        var collected2: [RecordingState] = []
        let expectation1 = XCTestExpectation(description: "Observer 1 done")
        let expectation2 = XCTestExpectation(description: "Observer 2 done")

        let task1 = Task {
            for await state in await coordinator.stateStream {
                collected1.append(state)
                if state == .processing { break }
            }
            expectation1.fulfill()
        }

        let task2 = Task {
            for await state in await coordinator.stateStream {
                collected2.append(state)
                if state == .processing { break }
            }
            expectation2.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        await coordinator.startRecording()
        await coordinator.stopRecording()

        await fulfillment(of: [expectation1, expectation2], timeout: 2.0)
        task1.cancel()
        task2.cancel()

        XCTAssertEqual(collected1, [.idle, .recording, .processing])
        XCTAssertEqual(collected2, [.idle, .recording, .processing])
    }

    // MARK: - failInjection

    func testFailInjectionFromInjectingSucceeds() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()

        let result = await coordinator.failInjection()
        XCTAssertTrue(result)
        await assertState(coordinator, .injectionFailed)
    }

    func testFailInjectionFromIdleFails() async {
        let coordinator = RecordingCoordinator()

        let result = await coordinator.failInjection()
        XCTAssertFalse(result)
        await assertState(coordinator, .idle)
    }

    func testFailInjectionFromRecordingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()

        let result = await coordinator.failInjection()
        XCTAssertFalse(result)
        await assertState(coordinator, .recording)
    }

    func testFailInjectionFromProcessingFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()

        let result = await coordinator.failInjection()
        XCTAssertFalse(result)
        await assertState(coordinator, .processing)
    }

    func testFinishInjectingFromInjectionFailedSucceeds() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()
        await coordinator.failInjection()

        let result = await coordinator.finishInjecting()
        XCTAssertTrue(result)
        await assertState(coordinator, .idle)
    }

    func testResetFromInjectionFailed() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()
        await coordinator.failInjection()

        await coordinator.reset()
        await assertState(coordinator, .idle)
    }

    func testCycleAfterInjectionFailure() async {
        let coordinator = RecordingCoordinator()

        // Full cycle through injection failure and recovery.
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()
        await coordinator.failInjection()
        await assertState(coordinator, .injectionFailed)
        await coordinator.finishInjecting()
        await assertState(coordinator, .idle)

        // A fresh cycle should work.
        let started = await coordinator.startRecording()
        XCTAssertTrue(started)
        let stopped = await coordinator.stopRecording()
        XCTAssertTrue(stopped)
        let injecting = await coordinator.startInjecting()
        XCTAssertTrue(injecting)
        let finished = await coordinator.finishInjecting()
        XCTAssertTrue(finished)
        await assertState(coordinator, .idle)
    }

    func testStartRecordingFromInjectionFailedFails() async {
        let coordinator = RecordingCoordinator()
        await coordinator.startRecording()
        await coordinator.stopRecording()
        await coordinator.startInjecting()
        await coordinator.failInjection()

        let result = await coordinator.startRecording()
        XCTAssertFalse(result)
        await assertState(coordinator, .injectionFailed)
    }

    // MARK: - Rapid transitions

    func testRapidStartStopCycles() async {
        let coordinator = RecordingCoordinator()

        // Simulate rapid press/release cycles.
        for _ in 0..<10 {
            let started = await coordinator.startRecording()
            XCTAssertTrue(started)
            let stopped = await coordinator.stopRecording()
            XCTAssertTrue(stopped)
            // Skip injection and just reset to idle for the next cycle.
            await coordinator.reset()
        }

        await assertState(coordinator, .idle)
    }
}
