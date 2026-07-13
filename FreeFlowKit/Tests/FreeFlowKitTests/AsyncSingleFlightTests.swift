import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Async single flight")
struct AsyncSingleFlightTests {

    @Test("Concurrent callers share one operation")
    func concurrentCallers() async throws {
        let flight = AsyncSingleFlight<Int>()
        let operation = ControlledOperation(result: 42)

        let tasks = (0..<8).map { _ in
            Task {
                try await flight.run {
                    await operation.run()
                }
            }
        }

        try await waitUntil {
            await flight.activeCallerCount == tasks.count
        }
        try await waitUntil { await operation.invocationCount == 1 }
        #expect(await operation.invocationCount == 1)

        await operation.release()
        for task in tasks {
            #expect(try await task.value == 42)
        }
        #expect(await flight.activeCallerCount == 0)
    }

    @Test("Failure clears the operation for retry")
    func retryAfterFailure() async throws {
        let flight = AsyncSingleFlight<Int>()

        await #expect(throws: TestFailure.self) {
            try await flight.run {
                throw TestFailure()
            }
        }

        let value = try await flight.run { 7 }
        #expect(value == 7)
    }

    @Test("Canceling one caller preserves shared work")
    func cancelCallerOnly() async throws {
        let flight = AsyncSingleFlight<Int>()
        let operation = ControlledOperation(result: 42)
        let leader = Task {
            try await flight.run { await operation.run() }
        }
        let waiter = Task {
            try await flight.run { await operation.run() }
        }

        try await waitUntil { await flight.activeCallerCount == 2 }
        try await waitUntil { await operation.invocationCount == 1 }
        waiter.cancel()
        #expect(await operation.invocationCount == 1)

        await operation.release()
        #expect(try await leader.value == 42)
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
    }

    @Test("Cancel stops the operation and permits retry")
    func cancelAndRetry() async throws {
        let flight = AsyncSingleFlight<Int>()
        let task = Task {
            try await flight.run {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
        }

        try await waitUntil { await flight.activeCallerCount == 1 }
        await flight.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try await flight.run { 2 } == 2)
    }

    @Test("Replacement waits for canceled work to drain")
    func replacementWaitsForDrain() async throws {
        let flight = AsyncSingleFlight<Int>()
        let operation = DrainControlledOperation()
        let first = Task {
            try await flight.run { await operation.run() }
        }

        try await waitUntil { await operation.invocationCount == 1 }

        let cancellation = Task { await flight.cancel() }
        try await waitUntil { await flight.isCancelling }

        let replacement = Task {
            try await flight.run { await operation.run() }
        }
        try await waitUntil { await flight.activeCallerCount == 2 }
        #expect(await operation.invocationCount == 1)

        await operation.releaseFirst()
        await cancellation.value
        #expect(try await first.value == 1)
        #expect(try await replacement.value == 2)
        #expect(await operation.invocationCount == 2)
    }
}

private struct TestFailure: Error {}
private struct WaitTimeout: Error {}

private func waitUntil(
    _ condition: @escaping () async -> Bool
) async throws {
    for _ in 0..<5_000 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw WaitTimeout()
}

private actor ControlledOperation {
    private(set) var invocationCount = 0
    private let result: Int
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(result: Int) {
        self.result = result
    }

    func run() async -> Int {
        invocationCount += 1
        await withCheckedContinuation {
            releaseContinuation = $0
        }
        return result
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor DrainControlledOperation {
    private(set) var invocationCount = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async -> Int {
        invocationCount += 1
        let result = invocationCount
        guard result == 1 else { return result }
        await withCheckedContinuation {
            releaseContinuation = $0
        }
        return result
    }

    func releaseFirst() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
