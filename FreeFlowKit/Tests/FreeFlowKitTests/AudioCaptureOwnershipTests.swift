import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Audio capture sink ownership")
struct AudioCaptureSinkOwnershipTests {
    @Test("Stale cleanup cannot clear replacement sinks")
    func staleCleanupCannotClearReplacement() {
        let ledger = AudioCaptureSinkOwnershipLedger<Int>()

        #expect(ledger.begin(1))
        ledger.reset()
        #expect(ledger.begin(2))

        #expect(!ledger.finish(1))
        #expect(ledger.owns(2))
    }

    @Test("Stale stop cannot reset replacement callback publication")
    func staleStopCannotResetReplacementPublication() {
        let ledger = AudioCapturePublicationLedger<Int>()
        ledger.begin(1)
        ledger.reset()
        let replacement = ledger.begin(2)

        #expect(!ledger.reset(1))
        #expect(ledger.admitCallback(for: replacement) != nil)
    }
}

@Suite("Audio capture stream snapshot")
struct AudioCaptureStreamSnapshotTests {
    @Test("Publication and clearing do not depend on provider state")
    func publishesAndClearsStream() async throws {
        let snapshot = AudioCapturePCMStreamSnapshot()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let chunk = Data([0x01, 0x02])

        #expect(snapshot.current == nil)
        snapshot.publish(stream)
        let published = try #require(snapshot.current)

        continuation.yield(chunk)
        continuation.finish()
        var iterator = published.makeAsyncIterator()
        #expect(await iterator.next() == chunk)

        snapshot.clear()
        #expect(snapshot.current == nil)
    }
}

@Suite("Serialized converter ownership")
struct SerializedConverterOwnershipTests {
    @Test("Discard waits for an in-flight consume operation")
    func discardWaitsForConsume() {
        let session = SerializedConverterSession<Int>()
        #expect(session.begin { 42 })

        let consumeEntered = DispatchSemaphore(value: 0)
        let releaseConsume = DispatchSemaphore(value: 0)
        let consumeFinished = DispatchSemaphore(value: 0)
        let discardStarted = DispatchSemaphore(value: 0)
        let discardFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = session.consume { _ in
                consumeEntered.signal()
                releaseConsume.wait()
            }
            consumeFinished.signal()
        }
        #expect(consumeEntered.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            discardStarted.signal()
            session.discard()
            discardFinished.signal()
        }
        #expect(discardStarted.wait(timeout: .now() + 1) == .success)
        #expect(discardFinished.wait(timeout: .now() + 0.05) == .timedOut)

        releaseConsume.signal()
        #expect(consumeFinished.wait(timeout: .now() + 1) == .success)
        #expect(discardFinished.wait(timeout: .now() + 1) == .success)
        #expect(session.consume { _ in true } == nil)
    }
}

@Suite("Audio start reservation")
struct AudioStartReservationTests {
    private final class Engine: @unchecked Sendable {}

    @Test("Reset can invalidate a start before provider state is entered")
    func resetInvalidatesPreLockReservation() throws {
        let ledger = AudioEngineStartResetLedger<Engine>()
        let attempt = try #require(ledger.beginIfIdle())

        let invalidated = ledger.invalidateActiveAttempt()

        #expect(invalidated?.attempt == attempt)
        #expect(!ledger.isValid(attempt))
        #expect(!ledger.publish(Engine(), for: attempt))
    }

    @Test("A competing start reservation is rejected without trapping")
    func competingReservationIsRejected() throws {
        let ledger = AudioEngineStartResetLedger<Engine>()
        let owner = try #require(ledger.beginIfIdle())

        #expect(ledger.beginIfIdle() == nil)

        ledger.end(owner)
        #expect(ledger.beginIfIdle() != nil)
    }
}
