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

@Suite("Audio preview pre-roll publication")
struct AudioPreviewPreRollPublicationTests {
    @Test("A stale physical stop cannot clear replacement preview coverage")
    func staleClearCannotTouchReplacement() {
        let publication = AudioPreviewPreRollPublication<Int>()
        publication.publish(for: 1) { _ in false }
        publication.publish(for: 2) { pressHostTime in
            pressHostTime == 42
        }

        #expect(!publication.clear(for: 1))
        #expect(publication.canRecover(at: 42))
        #expect(publication.clear(for: 2))
        #expect(!publication.canRecover(at: 42))
    }

    @Test("Coverage is evaluated outside the publication lock")
    func evaluatorCanReenterPublication() {
        let publication = AudioPreviewPreRollPublication<Int>()
        publication.publish(for: 1) { _ in
            #expect(publication.clear(for: 1))
            return true
        }

        #expect(publication.canRecover(at: 42))
        #expect(!publication.canRecover(at: 42))
    }
}

@Suite("Audio capture stop result ownership")
struct AudioCaptureStopResultOwnershipTests {
    private enum TestError: Error {
        case releaseDrainTimedOut
    }

    private actor CleanupGate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitForRelease() async {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private actor Flag {
        private(set) var value = false
        func set() { value = true }
    }

    @Test("An early stop failure is shared while cleanup retains queue ownership")
    func earlyFailureDoesNotReleaseTransition() async {
        let queue = AsyncSerialOperationQueue()
        let cleanupGate = CleanupGate()
        let replacementEntered = Flag()
        let owner = AudioCaptureOwner.dictation(DictationSessionID())
        let operation = AudioCaptureProvider.StopOperation(owner: owner) {
            publication in
            do {
                let buffer = try await queue.run {
                    publication.publish(.failure(TestError.releaseDrainTimedOut))
                    await cleanupGate.waitForRelease()
                    return AudioBuffer.empty
                }
                return .success(buffer)
            } catch {
                return .failure(error)
            }
        }

        let first = Task { await operation.result() }
        await cleanupGate.waitUntilEntered()
        guard case .failure(let firstError) = await first.value else {
            Issue.record("Expected early timeout failure")
            return
        }
        #expect(firstError is TestError)
        #expect(!operation.isCompleted)

        guard case .failure(let duplicateError) = await operation.result() else {
            Issue.record("Expected duplicate to share timeout failure")
            return
        }
        #expect(duplicateError is TestError)

        let replacement = Task {
            try? await queue.run {
                await replacementEntered.set()
            }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await replacementEntered.value))

        await cleanupGate.release()
        await replacement.value
        #expect(await replacementEntered.value)
        for _ in 0..<100 where !operation.isCompleted {
            await Task.yield()
        }
        #expect(operation.isCompleted)
    }
}

@Suite("Audio capture stop deadline")
struct AudioCaptureStopDeadlineTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = 0

        var value: Int { lock.withLock { storedValue } }

        func increment() {
            lock.withLock { storedValue += 1 }
        }
    }

    private final class StopCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stops: [AudioCapturePhysicalStop<Int>] = []

        func append(_ stop: AudioCapturePhysicalStop<Int>) {
            lock.withLock { stops.append(stop) }
        }

        var snapshot: [AudioCapturePhysicalStop<Int>] {
            lock.withLock { stops }
        }
    }

    private func wait(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }

    private actor AsyncGate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    @Test("The stop deadline includes final converter drain")
    func deadlineIncludesFinalConverterDrain() async {
        let finishEntered = DispatchSemaphore(value: 0)
        let releaseFinish = DispatchSemaphore(value: 0)
        let drain = AudioCaptureStopDrain<Int>(
            observeRelease: { true },
            finalize: {
                finishEntered.signal()
                releaseFinish.wait()
                return 42
            })

        let observation = await drain.outcome(timeout: 0.01)
        guard case .deadline = observation else {
            Issue.record("Expected final converter drain to hit the deadline")
            releaseFinish.signal()
            return
        }
        #expect(wait(finishEntered, timeout: .now() + 1) == .success)
        #expect(drain.timeoutFailure.stage == .converterDrain)

        releaseFinish.signal()
        guard case .finalized(let value) = await drain.task.value else {
            Issue.record("Expected retained finalization to finish")
            return
        }
        #expect(value == 42)
    }

    @Test("A release wait deadline remains classified as release drain")
    func releaseObservationDeadlineIsClassified() async {
        let releaseObservation = AsyncGate()
        let drain = AudioCaptureStopDrain<Int>(
            observeRelease: {
                await releaseObservation.wait()
                return true
            },
            finalize: { 42 })

        let observation = await drain.outcome(timeout: 0.01)
        guard case .deadline = observation else {
            Issue.record("Expected release observation to hit the deadline")
            await releaseObservation.release()
            return
        }
        await releaseObservation.waitUntilEntered()
        #expect(drain.timeoutFailure.stage == .releaseDrain)

        await releaseObservation.release()
        guard case .finalized(let value) = await drain.task.value else {
            Issue.record("Expected retained finalization to finish")
            return
        }
        #expect(value == 42)
    }

    @Test("Physical stop closes hardware before retaining blocked cleanup")
    func physicalStopDoesNotJoinBlockedCleanup() async {
        let hardwareClosed = DispatchSemaphore(value: 0)
        let cleanupEntered = DispatchSemaphore(value: 0)
        let releaseCleanup = DispatchSemaphore(value: 0)
        let physicalStop = AudioCapturePhysicalStop<Int>(
            closeHardware: {
                hardwareClosed.signal()
            },
            cleanup: {
                cleanupEntered.signal()
                releaseCleanup.wait()
                return 42
            })

        let hardwareCloseResult = wait(hardwareClosed, timeout: .now())
        #expect(hardwareCloseResult == .success)
        let cleanupEntryResult = wait(cleanupEntered, timeout: .now() + 1)
        #expect(cleanupEntryResult == .success)
        guard case .deadline = await physicalStop.outcome(timeout: 0.01) else {
            Issue.record("Expected blocked tap cleanup to exceed its deadline")
            releaseCleanup.signal()
            return
        }

        releaseCleanup.signal()
        #expect(await physicalStop.task.value == 42)
    }

    @Test("Concurrent physical-stop claims share one exact-attempt operation")
    func physicalStopClaimsAreDeduplicated() async {
        let ledger = AudioCapturePhysicalStopLedger<Int, Int>()
        let closeCount = Counter()
        let cleanupCount = Counter()
        let stops = StopCollector()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let stop = ledger.beginOrJoin(
                for: 7,
                closeHardware: { closeCount.increment() },
                cleanup: {
                    cleanupCount.increment()
                    return 42
                })
            stops.append(stop)
        }

        let claimedStops = stops.snapshot
        #expect(claimedStops.count == 32)
        guard let first = claimedStops.first else { return }
        #expect(claimedStops.allSatisfy { $0 === first })
        #expect(closeCount.value == 1)
        #expect(await first.task.value == 42)
        #expect(cleanupCount.value == 1)
    }

    @Test("Only the exact attempt can release a retained physical stop")
    func physicalStopCompletionIsAttemptScoped() {
        let ledger = AudioCapturePhysicalStopLedger<Int, Int>()
        let first = ledger.beginOrJoin(
            for: 1,
            closeHardware: {},
            cleanup: { 1 })

        #expect(ledger.hasRetainedStops)
        #expect(!ledger.claimCompletion(2))
        #expect(!ledger.finish(2))
        #expect(
            ledger.beginOrJoin(
                for: 1,
                closeHardware: {},
                cleanup: { 2 }) === first)
        #expect(ledger.claimCompletion(1))
        #expect(ledger.hasRetainedStops)
        #expect(!ledger.claimCompletion(1))
        #expect(ledger.finish(1))
        #expect(!ledger.hasRetainedStops)

        let replacement = ledger.beginOrJoin(
            for: 2,
            closeHardware: {},
            cleanup: { 2 })
        #expect(replacement !== first)
        #expect(!ledger.claimCompletion(1))
        #expect(!ledger.finish(1))
        #expect(
            ledger.beginOrJoin(
                for: 2,
                closeHardware: {},
                cleanup: { 3 }) === replacement)
    }

    @Test("Physical-stop publication permits recursive same-attempt stop")
    func physicalStopCreationIsReentrant() async throws {
        let ledger = AudioCapturePhysicalStopLedger<Int, Int>()
        let closeCount = Counter()
        let cleanupCount = Counter()
        let stops = StopCollector()
        let returned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            let outer = ledger.beginOrJoin(
                for: 7,
                closeHardware: {
                    closeCount.increment()
                    let recursive = ledger.beginOrJoin(
                        for: 7,
                        closeHardware: { closeCount.increment() },
                        cleanup: {
                            cleanupCount.increment()
                            return 99
                        })
                    stops.append(recursive)
                },
                cleanup: {
                    cleanupCount.increment()
                    return 42
                })
            stops.append(outer)
            returned.signal()
        }

        #expect(wait(returned, timeout: .now() + 1) == .success)
        let claimedStops = stops.snapshot
        #expect(claimedStops.count == 2)
        let first = try #require(claimedStops.first)
        #expect(claimedStops.allSatisfy { $0 === first })
        #expect(closeCount.value == 1)
        #expect(await first.task.value == 42)
        #expect(cleanupCount.value == 1)
    }

    @Test("Concurrent shutdown callers elect one finalizer")
    func shutdownIsOneShot() {
        let gate = AudioCaptureShutdownGate()
        let winnerCount = Counter()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if gate.claim() {
                winnerCount.increment()
            }
        }

        #expect(winnerCount.value == 1)
        #expect(!gate.claim())
    }
}

@Suite("Audio configuration change policy")
struct AudioConfigurationChangePolicyTests {
    @Test("A permanent capture rotates only when its input format changes")
    func activeCapturePolicy() {
        #expect(
            AudioCaptureConfigurationChangePolicy.action(
                isRecording: true,
                inputFormatChanged: false) == .ignore)
        #expect(
            AudioCaptureConfigurationChangePolicy.action(
                isRecording: true,
                inputFormatChanged: true) == .invalidateActiveCapture)
    }

    @Test("An idle engine can rebuild immediately")
    func idleEnginePolicy() {
        #expect(
            AudioCaptureConfigurationChangePolicy.action(
                isRecording: false,
                inputFormatChanged: true) == .rebuildIdleEngine)
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

    @Test("Shutdown either revokes demand before reservation or sees the attempt")
    func shutdownReservationHandshake() throws {
        let owner = AudioCaptureOwner.preview()

        let sealedFirstDemands = AudioCaptureDemandLedger()
        let sealedFirstLedger = AudioEngineStartResetLedger<Engine>()
        #expect(sealedFirstDemands.insert(owner))
        _ = sealedFirstDemands.sealForShutdown()
        let lateAttempt = try #require(
            sealedFirstLedger.beginIfIdle(owner: owner))
        #expect(!sealedFirstDemands.contains(owner))
        sealedFirstLedger.end(lateAttempt)

        let reservedFirstDemands = AudioCaptureDemandLedger()
        let reservedFirstLedger = AudioEngineStartResetLedger<Engine>()
        #expect(reservedFirstDemands.insert(owner))
        let reservedAttempt = try #require(
            reservedFirstLedger.beginIfIdle(owner: owner))
        #expect(reservedFirstDemands.contains(owner))
        _ = reservedFirstDemands.sealForShutdown()
        #expect(
            reservedFirstLedger.invalidateActiveAttempt()?.attempt
                == reservedAttempt)
    }
}

@Suite("Audio capture owner contract")
struct AudioCaptureOwnerContractTests {
    private actor Gate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitForRelease() async {
            entered = true
            let waitingForEntry = entryWaiters
            entryWaiters.removeAll()
            waitingForEntry.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            released = true
            let waitingForRelease = releaseWaiters
            releaseWaiters.removeAll()
            waitingForRelease.forEach { $0.resume() }
        }
    }

    @Test("Preview and dictation demands can coexist without sharing ownership")
    func previewAndDictationDemandsCanCoexist() {
        let preview = AudioCaptureOwner.preview()
        let dictation = AudioCaptureOwner.dictation(DictationSessionID())
        let demands = AudioCaptureDemandLedger()

        #expect(demands.insert(preview))
        #expect(demands.insert(dictation))
        #expect(demands.contains(preview))
        #expect(demands.contains(dictation))
        #expect(demands.preferredOwner == dictation)

        #expect(demands.remove(preview))
        #expect(!demands.contains(preview))
        #expect(demands.contains(dictation))
        #expect(demands.preferredOwner == dictation)
    }

    @Test("Shutdown revokes every capture demand atomically")
    func shutdownRevokesAllDemands() {
        let preview = AudioCaptureOwner.preview()
        let dictation = AudioCaptureOwner.dictation(DictationSessionID())
        let demands = AudioCaptureDemandLedger()
        #expect(demands.insert(preview))
        #expect(demands.insert(dictation))

        #expect(demands.removeAll() == [preview, dictation])
        #expect(!demands.contains(preview))
        #expect(!demands.contains(dictation))
        #expect(demands.preferredOwner == nil)
    }

    @Test("Stop and reset have one durable terminal winner")
    func terminalClaimExcludesResetAndStaleCompletion() throws {
        let owner = AudioCaptureOwner.dictation(DictationSessionID())
        let demands = AudioCaptureDemandLedger()
        #expect(demands.insert(owner))

        let termination = try #require(demands.beginTermination(owner))
        #expect(!demands.contains(owner))
        #expect(!demands.remove(owner))
        #expect(demands.beginTermination(owner) == nil)
        #expect(demands.finishTermination(termination))
        #expect(!demands.finishTermination(termination))

        #expect(demands.insert(owner))
        #expect(!demands.finishTermination(termination))
        #expect(demands.contains(owner))
    }

    @Test("Shutdown preserves an in-flight stop claim and seals new starts")
    func shutdownPreservesTerminalClaim() throws {
        let preview = AudioCaptureOwner.preview()
        let dictation = AudioCaptureOwner.dictation(DictationSessionID())
        let demands = AudioCaptureDemandLedger()
        #expect(demands.insert(preview))
        #expect(demands.insert(dictation))
        let termination = try #require(demands.beginTermination(dictation))

        #expect(
            demands.sealForShutdown()
                == .init(
                    activeOwners: [preview],
                    terminatingOwners: [dictation]))
        #expect(!demands.insert(AudioCaptureOwner.preview()))
        #expect(demands.isShutdown)
        #expect(demands.finishTermination(termination))
    }

    @Test("A preview stop cannot stop a dictation capture")
    func previewStopCannotStopDictation() async throws {
        let audio = MockAudioProvider()
        let dictation = AudioCaptureOwner.dictation(DictationSessionID())
        let preview = AudioCaptureOwner.preview()

        try await audio.startRecording(owner: dictation)

        await #expect(throws: AudioCaptureError.self) {
            try await audio.stopRecording(owner: preview)
        }
        #expect(audio.isRecording(owner: dictation))
        #expect(!audio.isRecording(owner: preview))

        _ = try await audio.stopRecording(owner: dictation)
    }

    @Test("A mismatched reset cannot invalidate a live capture")
    func mismatchedResetCannotInvalidateLiveCapture() async throws {
        let audio = MockAudioProvider()
        let owner = AudioCaptureOwner.dictation(DictationSessionID())
        let staleOwner = AudioCaptureOwner.preview()

        try await audio.startRecording(owner: owner)

        #expect(!audio.forceReset(owner: staleOwner))
        #expect(audio.isRecording(owner: owner))
        #expect(audio.metrics(owner: staleOwner) == nil)
        #expect(audio.metrics(owner: owner) != nil)

        _ = try await audio.stopRecording(owner: owner)
    }

    @Test("Concurrent duplicate stops join one physical stop")
    func duplicateStopsJoin() async throws {
        let audio = MockAudioProvider()
        let owner = AudioCaptureOwner.dictation(DictationSessionID())
        let gate = Gate()
        audio.stopWillComplete = { await gate.waitForRelease() }
        try await audio.startRecording(owner: owner)

        async let first = audio.stopRecording(owner: owner)
        await gate.waitUntilEntered()
        async let duplicate = audio.stopRecording(owner: owner)
        await Task.yield()
        await gate.release()

        let (firstBuffer, duplicateBuffer) = try await (first, duplicate)
        #expect(firstBuffer.data == duplicateBuffer.data)
        #expect(audio.stopCallCount == 1)
    }

    @Test("An immediate stop publishes completion before admitting replacement")
    func immediateStopsAdmitReplacement() async throws {
        let audio = MockAudioProvider()

        for _ in 0..<100 {
            let owner = AudioCaptureOwner.dictation(DictationSessionID())
            try await audio.startRecording(owner: owner)
            _ = try await audio.stopRecording(owner: owner)
        }

        #expect(audio.stopCallCount == 100)
    }

    @Test("Failed start releases only its owner and admits a replacement")
    func failedStartCleanupAdmitsReplacement() async throws {
        let audio = MockAudioProvider()
        let failedOwner = AudioCaptureOwner.preview()
        let replacement = AudioCaptureOwner.dictation(DictationSessionID())
        audio.stubbedStartError = AudioCaptureError.noInputDevice

        await #expect(throws: AudioCaptureError.self) {
            try await audio.startRecording(
                owner: failedOwner,
                configuration: .previewMetering)
        }
        #expect(!audio.isRecording(owner: failedOwner))
        #expect(audio.metrics(owner: failedOwner) == nil)

        audio.stubbedStartError = nil
        try await audio.startRecording(owner: replacement)
        #expect(audio.isRecording(owner: replacement))
        _ = try await audio.stopRecording(owner: replacement)
    }

    @Test("Late cleanup from a reset owner cannot touch its replacement")
    func lateCleanupCannotTouchReplacement() async throws {
        let audio = MockAudioProvider()
        let staleOwner = AudioCaptureOwner.preview()
        let replacement = AudioCaptureOwner.dictation(DictationSessionID())

        try await audio.startRecording(
            owner: staleOwner,
            configuration: .previewMetering)
        #expect(audio.forceReset(owner: staleOwner))
        try await audio.startRecording(owner: replacement)

        await #expect(throws: AudioCaptureError.self) {
            try await audio.stopRecording(owner: staleOwner)
        }
        #expect(!audio.forceReset(owner: staleOwner))
        #expect(audio.isRecording(owner: replacement))
        #expect(audio.metrics(owner: staleOwner) == nil)
        #expect(audio.metrics(owner: replacement) != nil)

        _ = try await audio.stopRecording(owner: replacement)
    }

    @Test("Preview metering exposes only its level stream")
    func previewMeteringSurfaceIsOwnerScoped() async throws {
        let audio = MockAudioProvider()
        let preview = AudioCaptureOwner.preview()
        let otherPreview = AudioCaptureOwner.preview()

        try await audio.startRecording(
            owner: preview,
            configuration: .previewMetering)

        #expect(audio.audioLevelStream(owner: preview) != nil)
        #expect(audio.audioLevelStream(owner: otherPreview) == nil)
        #expect(audio.pcmAudioStream(owner: preview) == nil)
        #expect(audio.pcmAudioStream(owner: otherPreview) == nil)

        _ = try await audio.stopRecording(owner: preview)
    }
}
