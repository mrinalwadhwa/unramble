import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Async serial operation queue")
struct AsyncSerialOperationQueueTests {
    private actor Gate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private actor Trace {
        private var values: [String] = []

        func append(_ value: String) { values.append(value) }
        var snapshot: [String] { values }
    }

    @Test("A suspended operation retains the queue until it finishes")
    func suspensionRetainsQueue() async throws {
        let queue = AsyncSerialOperationQueue()
        let gate = Gate()
        let trace = Trace()

        let first = Task {
            try await queue.run {
                await trace.append("first-enter")
                await gate.wait()
                await trace.append("first-exit")
            }
        }
        await gate.waitUntilEntered()
        let second = Task {
            try await queue.run {
                await trace.append("second")
            }
        }
        await Task.yield()

        #expect(await trace.snapshot == ["first-enter"])
        await gate.release()
        try await first.value
        try await second.value
        #expect(await trace.snapshot == ["first-enter", "first-exit", "second"])
    }

    @Test("Cancelling a queued operation prevents it from entering")
    func cancellationBeforeAdmission() async throws {
        let queue = AsyncSerialOperationQueue()
        let gate = Gate()
        let trace = Trace()

        let first = Task {
            try await queue.run { await gate.wait() }
        }
        await gate.waitUntilEntered()
        let cancelled = Task {
            try await queue.run {
                await trace.append("cancelled-entered")
            }
        }
        cancelled.cancel()
        await gate.release()
        try await first.value

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await trace.snapshot.isEmpty)
    }
}
