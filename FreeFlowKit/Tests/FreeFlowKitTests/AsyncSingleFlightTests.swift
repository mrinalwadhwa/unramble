import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Async single flight", .timeLimit(.minutes(1)))
struct AsyncSingleFlightTests {

    @Test("Concurrent callers share one operation")
    func concurrentCallers() async throws {
        let flight = AsyncSingleFlight<Int>()
        let operation = ControlledOperation(result: 42)

        let tasks = (0..<8).map { _ in
            Task {
                try await flight.run {
                    try await operation.run()
                }
            }
        }

        let started = await operation.waitUntilStarted()
        #expect(started)
        if !started {
            tasks.forEach { $0.cancel() }
        }
        let callersJoined = await waitUntil {
            await flight.activeCallerCount == tasks.count
        }
        #expect(callersJoined)
        if !callersJoined {
            tasks.forEach { $0.cancel() }
        }
        #expect(await operation.invocationCount == 1)

        await operation.release()
        if !started || !callersJoined {
            await flight.cancel()
        }
        var results: [Result<Int, any Error>] = []
        for task in tasks {
            results.append(await task.result)
        }
        for result in results {
            #expect(try result.get() == 42)
        }
        #expect(await flight.activeCallerCount == 0)
        #expect(await operation.invocationCount == 1)
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
            try await flight.run { try await operation.run() }
        }
        let started = await operation.waitUntilStarted()
        #expect(started)
        guard started else {
            leader.cancel()
            await operation.release()
            await flight.cancel()
            _ = await leader.result
            return
        }
        let waiter = Task {
            try await flight.run { try await operation.run() }
        }

        let waiterJoined = await waitUntil {
            await flight.activeCallerCount == 2
        }
        #expect(waiterJoined)
        if !waiterJoined {
            leader.cancel()
        }
        waiter.cancel()
        #expect(await operation.invocationCount == 1)

        await operation.release()
        if !waiterJoined {
            await flight.cancel()
        }
        let leaderResult = await leader.result
        let waiterResult = await waiter.result
        #expect(try leaderResult.get() == 42)
        #expect(throws: CancellationError.self) {
            try waiterResult.get()
        }
        #expect(await operation.invocationCount == 1)
    }

    @Test("Cancel stops the operation and permits retry")
    func cancelAndRetry() async throws {
        let flight = AsyncSingleFlight<Int>()
        let operation = CancellationControlledOperation(result: 1)
        let task = Task {
            try await flight.run {
                try await operation.run()
            }
        }

        let started = await operation.waitUntilStarted()
        #expect(started)
        if !started {
            task.cancel()
        }
        let cancellation = Task { await flight.cancel() }
        let cancellationObserved =
            await operation.waitUntilCancellationObserved()
        #expect(cancellationObserved)
        if !cancellationObserved {
            task.cancel()
            cancellation.cancel()
            await operation.release()
        }
        await cancellation.value

        let result = await task.result
        #expect(throws: CancellationError.self) {
            try result.get()
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

        let started = await operation.waitUntilStarted()
        #expect(started)
        guard started else {
            first.cancel()
            await operation.releaseFirst()
            await flight.cancel()
            _ = await first.result
            return
        }

        let cancellation = Task { await flight.cancel() }
        let cancellationObserved =
            await operation.waitUntilCancellationObserved()
        #expect(cancellationObserved)
        guard cancellationObserved else {
            first.cancel()
            cancellation.cancel()
            await operation.releaseFirst()
            await cancellation.value
            _ = await first.result
            return
        }

        let replacement = Task {
            try await flight.run { await operation.run() }
        }
        let replacementJoined = await waitUntil {
            await flight.activeCallerCount == 2
        }
        #expect(replacementJoined)
        if !replacementJoined {
            first.cancel()
            replacement.cancel()
            cancellation.cancel()
        }
        #expect(await operation.invocationCount == 1)

        await operation.releaseFirst()
        await cancellation.value
        let firstResult = await first.result
        let replacementResult = await replacement.result
        #expect(try firstResult.get() == 1)
        #expect(try replacementResult.get() == 2)
        #expect(await operation.invocationCount == 2)
    }
}

private struct TestFailure: Error {}

private func waitUntil(
    _ condition: @escaping () async -> Bool
) async -> Bool {
    for _ in 0..<5_000 {
        if await condition() { return true }
        do {
            try await Task.sleep(nanoseconds: 1_000_000)
        } catch {
            return false
        }
    }
    return await condition()
}

private actor ControlledOperation {
    private(set) var invocationCount = 0
    private let result: Int
    private let started = AsyncSignal()
    private let released = AsyncSignal()

    init(result: Int) {
        self.result = result
    }

    func run() async throws -> Int {
        invocationCount += 1
        started.signal()
        await released.waitIgnoringCancellation()
        try Task.checkCancellation()
        return result
    }

    func waitUntilStarted() async -> Bool {
        await started.wait()
    }

    func release() {
        released.signal()
    }
}

private actor CancellationControlledOperation {
    private let result: Int
    private let started = AsyncSignal()
    private let cancellationObserved = AsyncSignal()
    private let released = AsyncSignal()

    init(result: Int) {
        self.result = result
    }

    func run() async throws -> Int {
        started.signal()
        await withTaskCancellationHandler {
            _ = await released.wait()
        } onCancel: {
            cancellationObserved.signal()
            released.signal()
        }
        try Task.checkCancellation()
        return result
    }

    func waitUntilStarted() async -> Bool {
        await started.wait()
    }

    func waitUntilCancellationObserved() async -> Bool {
        await cancellationObserved.wait()
    }

    func release() {
        released.signal()
    }
}

private actor DrainControlledOperation {
    private(set) var invocationCount = 0
    private let started = AsyncSignal()
    private let cancellationObserved = AsyncSignal()
    private let released = AsyncSignal()

    func run() async -> Int {
        invocationCount += 1
        let result = invocationCount
        guard result == 1 else { return result }
        started.signal()
        await withTaskCancellationHandler {
            await released.waitIgnoringCancellation()
        } onCancel: {
            cancellationObserved.signal()
        }
        return result
    }

    func waitUntilStarted() async -> Bool {
        await started.wait()
    }

    func waitUntilCancellationObserved() async -> Bool {
        await cancellationObserved.wait()
    }

    func releaseFirst() {
        released.signal()
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func signal() {
        let continuations = lock.withLock {
            guard !signaled else {
                return [CheckedContinuation<Bool, Never>]()
            }
            signaled = true
            let continuations = Array(waiters.values)
            waiters.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume(returning: true) }
    }

    func wait() async -> Bool {
        await wait(cancellable: true)
    }

    func waitIgnoringCancellation() async {
        _ = await wait(cancellable: false)
    }

    private func wait(cancellable: Bool) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediateResult: Bool? = lock.withLock {
                    if signaled { return true }
                    if cancellable && Task.isCancelled { return false }
                    waiters[id] = continuation
                    return nil
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            guard cancellable else { return }
            let continuation = lock.withLock {
                waiters.removeValue(forKey: id)
            }
            continuation?.resume(returning: false)
        }
    }
}
