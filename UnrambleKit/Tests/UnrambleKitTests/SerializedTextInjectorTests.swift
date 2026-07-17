import XCTest

@testable import UnrambleKit

final class SerializedTextInjectorTests: XCTestCase {
    func testSecondPublicationWaitsForFirstToFinish() async {
        let base = GatedPublicationInjector()
        let injector = SerializedTextInjector(base: base)

        let first = Task {
            try? await injector.inject(text: "first", into: .empty)
        }
        await base.waitUntilFirstStarts()

        let second = Task {
            try? await injector.inject(text: "second", into: .empty)
        }
        for _ in 0..<100 { await Task.yield() }

        let startedBeforeRelease = await base.startedTexts
        XCTAssertEqual(startedBeforeRelease, ["first"])

        await base.releaseFirst()
        await first.value
        await second.value

        let completed = await base.completedTexts
        XCTAssertEqual(completed, ["first", "second"])
    }

    func testCancelledQueuedPublicationNeverReachesBaseInjector() async {
        let base = GatedPublicationInjector()
        let injector = SerializedTextInjector(base: base)

        let first = Task {
            try? await injector.inject(text: "first", into: .empty)
        }
        await base.waitUntilFirstStarts()
        let cancelled = Task {
            try await injector.inject(text: "cancelled", into: .empty)
        }
        for _ in 0..<100 { await Task.yield() }

        cancelled.cancel()
        await base.releaseFirst()
        await first.value

        do {
            try await cancelled.value
            XCTFail("Cancelled queued publication unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: it acquired and released its queue turn without writing.
        } catch {
            XCTFail("Unexpected queued publication error: \(error)")
        }

        let started = await base.startedTexts
        XCTAssertEqual(started, ["first"])
    }

    func testCancelledQueuedPublicationReturnsWhileFirstRemainsBlocked() async throws {
        let base = GatedPublicationInjector()
        let injector = SerializedTextInjector(base: base)

        let first = Task {
            try? await injector.inject(text: "first", into: .empty)
        }
        await base.waitUntilFirstStarts()

        let cancelled = Task {
            try await injector.inject(text: "cancelled", into: .empty)
        }
        await waitUntilQueuedPublicationCount(1, in: injector)

        cancelled.cancel()
        let cancellationObserved = XCTestExpectation(
            description: "queued publication observes cancellation"
        )
        let cancellationObserver = Task {
            await assertCancellation(of: cancelled)
            cancellationObserved.fulfill()
        }
        let waitResult = await XCTWaiter().fulfillment(
            of: [cancellationObserved],
            timeout: 0.25
        )

        let startedBeforeRelease = await base.startedTexts
        XCTAssertEqual(startedBeforeRelease, ["first"])
        await base.releaseFirst()
        await first.value
        await cancellationObserver.value
        XCTAssertEqual(waitResult, .completed)
    }

    func testCancellingMiddleWaiterPreservesFIFOForLivePublications() async throws {
        let base = GatedPublicationInjector()
        let injector = SerializedTextInjector(base: base)

        let first = Task {
            try? await injector.inject(text: "first", into: .empty)
        }
        await base.waitUntilFirstStarts()

        let second = Task {
            try await injector.inject(text: "second", into: .empty)
        }
        await waitUntilQueuedPublicationCount(1, in: injector)

        let cancelled = Task {
            try await injector.inject(text: "cancelled", into: .empty)
        }
        await waitUntilQueuedPublicationCount(2, in: injector)

        let fourth = Task {
            try await injector.inject(text: "fourth", into: .empty)
        }
        await waitUntilQueuedPublicationCount(3, in: injector)

        cancelled.cancel()
        let cancellationObserved = XCTestExpectation(
            description: "middle publication observes cancellation"
        )
        let cancellationObserver = Task {
            await assertCancellation(of: cancelled)
            cancellationObserved.fulfill()
        }
        let waitResult = await XCTWaiter().fulfillment(
            of: [cancellationObserved],
            timeout: 0.25
        )

        await base.releaseFirst()
        await first.value
        await cancellationObserver.value
        try await second.value
        try await fourth.value

        XCTAssertEqual(waitResult, .completed)
        let started = await base.startedTexts
        let completed = await base.completedTexts
        XCTAssertEqual(started, ["first", "second", "fourth"])
        XCTAssertEqual(completed, ["first", "second", "fourth"])
    }
}

private func waitUntilQueuedPublicationCount(
    _ expectedCount: Int,
    in injector: SerializedTextInjector
) async {
    let deadline = ContinuousClock.now + .seconds(1)
    while await injector.queuedPublicationCount != expectedCount,
          ContinuousClock.now < deadline {
        await Task.yield()
    }
    let queuedPublicationCount = await injector.queuedPublicationCount
    XCTAssertEqual(queuedPublicationCount, expectedCount)
}

private func assertCancellation(
    of task: Task<Void, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await task.value
        XCTFail("Cancelled queued publication unexpectedly succeeded", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("Unexpected queued publication error: \(error)", file: file, line: line)
    }
}

private actor GatedPublicationInjector: TextInjecting {
    private var firstStarted = false
    private var firstReleased = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startedTexts: [String] = []
    private(set) var completedTexts: [String] = []

    func inject(text: String, into context: AppContext) async throws {
        startedTexts.append(text)
        if text == "first" {
            firstStarted = true
            let waiters = firstStartWaiters
            firstStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !firstReleased {
                await withCheckedContinuation { continuation in
                    firstReleaseWaiters.append(continuation)
                }
            }
        }
        completedTexts.append(text)
    }

    func waitUntilFirstStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        firstReleased = true
        let waiters = firstReleaseWaiters
        firstReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
