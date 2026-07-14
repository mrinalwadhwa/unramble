import Foundation
import XCTest

@testable import FreeFlowKit

final class AudioForwardingOperationTests: XCTestCase {

    func testDrainSendsQueuedTailInOrderWithoutCancellingProvider() async {
        let firstChunk = Data([0x01])
        let secondChunk = Data([0x02])
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let sender = OrderedBlockingSender()
        let provider = ProviderCancellationProbe()
        let operation = AudioForwardingOperation(
            stream: stream,
            send: { data in try await sender.send(data) }
        )

        continuation.yield(firstChunk)
        await sender.waitUntilFirstSendStarts()
        continuation.yield(secondChunk)
        continuation.finish()

        let drainTask = Task {
            await operation.drain(
                timeout: .seconds(30),
                cancelStreaming: { await provider.cancel() }
            )
        }
        await sender.releaseFirstSend()
        let outcome = await drainTask.value
        let sentChunks = await sender.sentChunks
        let cancellationCount = await provider.cancellationCount

        XCTAssertEqual(outcome, .drained)
        XCTAssertEqual(sentChunks, [firstChunk, secondChunk])
        XCTAssertEqual(cancellationCount, 0)
    }

    func testSendFailureDrainsAndDiscardsRemainingStreamBeforeCancelling() async {
        let chunks = [Data([0x01]), Data([0x02]), Data([0x03])]
        let source = CountingUnfoldingSource(chunks: chunks)
        let stream = AsyncStream<Data>(unfolding: { await source.next() })
        let sender = FirstSendFailureSender()
        let provider = ProviderCancellationProbe()
        let operation = AudioForwardingOperation(
            stream: stream,
            send: { data in try await sender.send(data) }
        )

        let outcome = await operation.drain(
            timeout: .seconds(30),
            cancelStreaming: { await provider.cancel() }
        )
        let attemptedChunks = await sender.attemptedChunks
        let sourceSnapshot = await source.snapshot
        let cancellationCount = await provider.cancellationCount

        XCTAssertEqual(outcome, .failed("send failed"))
        XCTAssertEqual(attemptedChunks, [chunks[0]])
        XCTAssertEqual(sourceSnapshot.elementCount, chunks.count)
        XCTAssertTrue(sourceSnapshot.reachedEnd)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testDeadlineCancelsProviderBeforeJoiningBlockedSend() async {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let sender = CancellationInsensitiveSender()
        let operation = AudioForwardingOperation(
            stream: stream,
            send: { data in try await sender.send(data) }
        )

        continuation.yield(Data([0x01]))
        continuation.finish()
        await sender.waitUntilSendStarts()

        let drainTask = Task {
            await operation.drain(
                timeout: .zero,
                cancelStreaming: { await sender.cancelStreaming() }
            )
        }
        let outcome = await drainTask.value
        let events = await sender.events

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(
            events,
            [.sendStarted, .cancelStreaming, .sendExited]
        )
    }

    func testCancelledDrainIsNotReportedAsTimeout() async {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let sender = CancellationInsensitiveSender()
        let operation = AudioForwardingOperation(
            stream: stream,
            send: { data in try await sender.send(data) }
        )

        continuation.yield(Data([0x01]))
        continuation.finish()
        await sender.waitUntilSendStarts()

        let drainTask = Task {
            await operation.drain(
                timeout: .seconds(30),
                cancelStreaming: { await sender.cancelStreaming() }
            )
        }
        drainTask.cancel()
        let outcome = await drainTask.value
        let events = await sender.events

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(
            events,
            [.sendStarted, .cancelStreaming, .sendExited]
        )
    }

    func testExplicitCancelClosesProviderBeforeJoiningBlockedSend() async {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let sender = CancellationInsensitiveSender()
        let operation = AudioForwardingOperation(
            stream: stream,
            send: { data in try await sender.send(data) }
        )

        continuation.yield(Data([0x01]))
        continuation.finish()
        await sender.waitUntilSendStarts()

        await operation.cancel {
            await sender.cancelStreaming()
        }

        let events = await sender.events
        XCTAssertEqual(
            events,
            [.sendStarted, .cancelStreaming, .sendExited]
        )
    }
}

private actor OrderedBlockingSender {
    private let firstSendStarted = RememberedAsyncSignal()
    private let firstSendReleased = RememberedAsyncSignal()
    private(set) var sentChunks: [Data] = []

    func send(_ data: Data) async throws {
        sentChunks.append(data)
        guard sentChunks.count == 1 else { return }
        firstSendStarted.signal()
        await firstSendReleased.waitIgnoringCancellation()
    }

    func waitUntilFirstSendStarts() async {
        await firstSendStarted.waitIgnoringCancellation()
    }

    func releaseFirstSend() {
        firstSendReleased.signal()
    }
}

private actor ProviderCancellationProbe {
    private(set) var cancellationCount = 0

    func cancel() {
        cancellationCount += 1
    }
}

private actor CountingUnfoldingSource {
    struct Snapshot: Sendable {
        let elementCount: Int
        let reachedEnd: Bool
    }

    private let chunks: [Data]
    private var index = 0
    private var didReachEnd = false

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func next() -> Data? {
        guard index < chunks.count else {
            didReachEnd = true
            return nil
        }
        defer { index += 1 }
        return chunks[index]
    }

    var snapshot: Snapshot {
        Snapshot(elementCount: index, reachedEnd: didReachEnd)
    }
}

private actor FirstSendFailureSender {
    private(set) var attemptedChunks: [Data] = []

    func send(_ data: Data) async throws {
        attemptedChunks.append(data)
        throw ForwardingSendFailure()
    }
}

private struct ForwardingSendFailure: LocalizedError {
    var errorDescription: String? { "send failed" }
}

private actor CancellationInsensitiveSender {
    enum Event: Equatable {
        case sendStarted
        case cancelStreaming
        case sendExited
    }

    private let sendStarted = RememberedAsyncSignal()
    private let sendReleased = RememberedAsyncSignal()
    private(set) var events: [Event] = []

    func send(_ data: Data) async throws {
        events.append(.sendStarted)
        sendStarted.signal()
        await sendReleased.waitIgnoringCancellation()
        events.append(.sendExited)
    }

    func waitUntilSendStarts() async {
        await sendStarted.waitIgnoringCancellation()
    }

    func cancelStreaming() {
        events.append(.cancelStreaming)
        sendReleased.signal()
    }
}

private final class RememberedAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        let continuations = lock.withLock {
            guard !isSignalled else {
                return [CheckedContinuation<Void, Never>]()
            }
            isSignalled = true
            let continuations = Array(waiters.values)
            waiters.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        await wait(cancellable: true)
    }

    func waitIgnoringCancellation() async {
        await wait(cancellable: false)
    }

    private func wait(cancellable: Bool) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if isSignalled || (cancellable && Task.isCancelled) {
                        return true
                    }
                    waiters[id] = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            guard cancellable else { return }
            let continuation = lock.withLock {
                waiters.removeValue(forKey: id)
            }
            continuation?.resume()
        }
    }
}
