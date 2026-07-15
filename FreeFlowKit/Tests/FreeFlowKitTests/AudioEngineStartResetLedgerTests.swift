import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Audio engine start/reset ownership")
struct AudioEngineStartResetLedgerTests {
    private final class Engine: @unchecked Sendable {}

    @Test("Reset can reach an engine before its start call returns")
    func resetReachesPublishedStartingEngine() {
        let ledger = AudioEngineStartResetLedger<Engine>()
        let engine = Engine()
        let attempt = ledger.begin()

        #expect(ledger.publish(engine, for: attempt))

        let invalidated = ledger.invalidateActiveAttempt()

        #expect(invalidated?.attempt == attempt)
        #expect(invalidated?.engine === engine)
        #expect(!ledger.isValid(attempt))
    }

    @Test("An invalidated start cannot publish recording state")
    func invalidatedAttemptCannotCommit() {
        let ledger = AudioEngineStartResetLedger<Engine>()
        let engine = Engine()
        let attempt = ledger.begin()
        var didPublishRecording = false

        #expect(ledger.publish(engine, for: attempt))
        _ = ledger.invalidateActiveAttempt()

        let committed = ledger.withValidAttempt(attempt) {
            didPublishRecording = true
        }

        #expect(!committed)
        #expect(!didPublishRecording)
    }

    @Test("Reset after commit remains visible to the start owner")
    func resetAfterCommitIsObservedBeforeStartReturns() {
        let ledger = AudioEngineStartResetLedger<Engine>()
        let engine = Engine()
        let attempt = ledger.begin()
        var didPublishRecording = false

        #expect(ledger.publish(engine, for: attempt))
        #expect(
            ledger.withValidAttempt(attempt) {
                didPublishRecording = true
            })
        #expect(didPublishRecording)

        let invalidated = ledger.invalidateActiveAttempt()
        #expect(invalidated?.attempt == attempt)
        #expect(invalidated?.engine === engine)
        #expect(!ledger.isValid(attempt))
    }

    @Test("Reset cannot split capture publication from readiness")
    func resetCannotSplitCapturePublicationFromReadiness() {
        let ledger = AudioEngineStartResetLedger<Engine>()
        let attempt = ledger.begin()
        let readinessEntered = DispatchSemaphore(value: 0)
        let releaseReadiness = DispatchSemaphore(value: 0)
        let commitReturned = DispatchSemaphore(value: 0)
        let resetReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = ledger.commitCaptureReady(
                attempt,
                publish: {},
                onCaptureReady: {
                    readinessEntered.signal()
                    releaseReadiness.wait()
                })
            commitReturned.signal()
        }

        #expect(readinessEntered.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().async {
            _ = ledger.invalidateActiveAttempt()
            resetReturned.signal()
        }

        #expect(resetReturned.wait(timeout: .now() + 0.05) == .timedOut)
        releaseReadiness.signal()
        #expect(commitReturned.wait(timeout: .now() + 1) == .success)
        #expect(resetReturned.wait(timeout: .now() + 1) == .success)
        #expect(!ledger.isValid(attempt))
    }

    @Test("Late cleanup from an old attempt cannot clear its replacement")
    func staleCleanupCannotClearReplacement() {
        let ledger = AudioEngineStartResetLedger<Engine>()
        let first = ledger.begin()
        ledger.end(first)

        let replacementEngine = Engine()
        let replacement = ledger.begin()
        #expect(ledger.publish(replacementEngine, for: replacement))

        ledger.end(first)

        #expect(ledger.isValid(replacement))
        #expect(ledger.invalidateActiveAttempt()?.engine === replacementEngine)
    }
}

@Suite("Audio callback publication ownership")
struct AudioCapturePublicationLedgerTests {
    @Test("A callback queued by a replaced tap cannot enter the new generation")
    func replacedTapRejectsCallbackThatEntersAfterReset() {
        let ledger = AudioCapturePublicationLedger<Int>()
        let firstTap = ledger.begin(1)
        let queuedFirstTapCallback = {
            ledger.admitCallback(for: firstTap)
        }

        ledger.reset()
        ledger.begin(1)

        #expect(queuedFirstTapCallback() == nil)
    }

    @Test("Reset callbacks cannot publish into a replacement capture")
    func resetRejectsStaleCallbacks() {
        let ledger = AudioCapturePublicationLedger<Int>()
        let firstPublication = ledger.begin(1)
        let staleAdmission = ledger.admitCallback(for: firstPublication)
        #expect(staleAdmission != nil)

        ledger.reset()
        let replacementPublication = ledger.begin(1)

        #expect(!ledger.accepts(staleAdmission!))
        #expect(ledger.admitCallback(for: replacementPublication) != nil)
    }

    @Test("Closing a boundary retains timestamped callbacks until drain finishes")
    func boundaryCloseRetainsTimestampedCallbacksUntilDrainFinishes() {
        let ledger = AudioCapturePublicationLedger<Int>()
        let publication = ledger.begin(1)
        let admittedBeforeClose = ledger.admitCallback(for: publication)
        #expect(admittedBeforeClose != nil)

        let beganDraining = ledger.beginDrainingCurrentCapture()
        #expect(beganDraining)
        #expect(ledger.admitCallback(for: publication) != nil)
        #expect(ledger.accepts(admittedBeforeClose!))
        #expect(!ledger.canBegin)

        ledger.finishDraining(1)

        #expect(ledger.canBegin)
        #expect(!ledger.accepts(admittedBeforeClose!))
    }

    @Test("Async stop can join a boundary closed synchronously earlier")
    func stopCanJoinClosedBoundary() {
        let ledger = AudioCapturePublicationLedger<Int>()
        ledger.begin(1)

        #expect(ledger.beginDrainingCurrentCapture())
        #expect(ledger.beginDraining(1))
        #expect(ledger.drainingToken == 1)

        ledger.finishDraining(1)
        #expect(ledger.canBegin)
    }
}

@Suite("Audio provider force-reset contract")
struct AudioProviderForceResetContractTests {
    @Test("Reset terminates capture streams and permits a fresh recording")
    func resetTerminatesCaptureAndPermitsRestart() async throws {
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        let preResetChunk = Data([0x01, 0x02])
        let postResetChunk = Data([0x03, 0x04])

        try await audio.startRecording()
        let stream = try #require(audio.pcmAudioStream)
        audio.emitPCMChunk(preResetChunk)

        audio.forceReset()
        audio.emitPCMChunk(postResetChunk)

        #expect(!audio.isRecording)
        #expect(audio.pcmAudioStream == nil)

        var iterator = stream.makeAsyncIterator()
        let firstChunk = await iterator.next()
        let endOfStream = await iterator.next()
        #expect(firstChunk == preResetChunk)
        #expect(endOfStream == nil)

        try await audio.startRecording()
        #expect(audio.isRecording)
        #expect(audio.captureReadyCount == 2)

        audio.forceReset()
        audio.forceReset()
        #expect(!audio.isRecording)
    }
}
