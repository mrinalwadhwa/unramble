import Foundation
import XCTest

@testable import UnrambleKit

final class StreamingFinishOperationTests: XCTestCase {

    func testSuccessfulFinishDoesNotCancelCompletedProvider() async {
        let provider = FinishProviderCancellationProbe()
        let operation = StreamingFinishOperation {
            "Complete text"
        }

        let outcome = await operation.resolve(
            timeout: .seconds(30),
            cancelStreaming: { await provider.cancel() })

        XCTAssertEqual(outcome, .completed("Complete text"))
        let cancellationCount = await provider.cancellationCount
        XCTAssertEqual(cancellationCount, 0)
    }

    func testFailedFinishClosesProviderBeforeReturningFailure() async {
        let provider = FinishProviderCancellationProbe()
        let operation = StreamingFinishOperation {
            throw DictationError.networkError("offline")
        }

        let outcome = await operation.resolve(
            timeout: .seconds(30),
            cancelStreaming: { await provider.cancel() })

        guard case .failed = outcome else {
            return XCTFail("Expected failed finish, got \(outcome)")
        }
        let cancellationCount = await provider.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
    }

    func testTimeoutClosesProviderBeforeJoiningAndRejectsLateSuccess() async {
        let finishStarted = TestGate()
        let finishReleased = TestGate()
        let trace = FinishTrace()
        let operation = StreamingFinishOperation {
            await trace.append(.finishStarted)
            await finishStarted.open()
            await finishReleased.wait()
            await trace.append(.finishExited)
            return "Late plausible text"
        }

        await finishStarted.wait()
        let outcome = await operation.resolve(
            timeout: .zero,
            cancelStreaming: {
                await trace.append(.cancelStreaming)
                await finishReleased.open()
            })

        XCTAssertEqual(outcome, .timedOut)
        let events = await trace.events
        XCTAssertEqual(events, [.finishStarted, .cancelStreaming, .finishExited])
    }

    func testCallerCancellationClosesProviderBeforeJoining() async {
        let finishStarted = TestGate()
        let finishReleased = TestGate()
        let trace = FinishTrace()
        let operation = StreamingFinishOperation {
            await trace.append(.finishStarted)
            await finishStarted.open()
            await finishReleased.wait()
            await trace.append(.finishExited)
            return "Late plausible text"
        }

        await finishStarted.wait()
        let resolveTask = Task {
            await operation.resolve(
                timeout: .seconds(30),
                cancelStreaming: {
                    await trace.append(.cancelStreaming)
                    await finishReleased.open()
                })
        }
        resolveTask.cancel()
        let outcome = await resolveTask.value

        XCTAssertEqual(outcome, .cancelled)
        let events = await trace.events
        XCTAssertEqual(events, [.finishStarted, .cancelStreaming, .finishExited])
    }
}

private actor FinishProviderCancellationProbe {
    private(set) var cancellationCount = 0

    func cancel() {
        cancellationCount += 1
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor FinishTrace {
    enum Event: Equatable {
        case finishStarted
        case cancelStreaming
        case finishExited
    }

    private(set) var events: [Event] = []

    func append(_ event: Event) {
        events.append(event)
    }
}
