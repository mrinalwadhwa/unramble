import XCTest

@testable import FreeFlowKit

final class HotkeyPipelineDriverTests: XCTestCase {
    func testReleasePublishesCaptureBoundaryBeforeQueuedCompletion() async throws {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let releaseHostTime: UInt64 = 41_000

        driver.submit(.pressed)
        await pipeline.waitUntilActivationStarts()
        let boundaries = await pipeline.activationReleaseBoundaries
        let boundary = try XCTUnwrap(boundaries.first)

        driver.submit(.released, hostTime: releaseHostTime)

        XCTAssertEqual(boundary.releaseHostTime, releaseHostTime)
        await pipeline.rejectActivation()
        await driver.waitForSubmittedEvents()
        driver.invalidate()
    }

    func testReleaseCarriesPhysicalEventHostTimeToCompletion() async {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let sessionID = DictationSessionID()
        let releaseHostTime: UInt64 = 42_000

        await pipeline.releaseActivation(with: sessionID)
        driver.submit(.pressed)
        await driver.waitForSubmittedEvents()
        driver.submit(.released, hostTime: releaseHostTime)
        await driver.waitForSubmittedEvents()

        let completions = await pipeline.timestampedCompletionAttempts
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.sessionID, sessionID)
        XCTAssertEqual(completions.first?.releaseHostTime, releaseHostTime)
        driver.invalidate()
    }

    func testReleaseCancelsPendingActivationBeforeItReturns() async {
        let activationCancelled = expectation(
            description: "pending activation cancelled")
        let pipeline = GatedHotkeyPipeline(
            activationCancelled: { activationCancelled.fulfill() })
        let driver = HotkeyPipelineDriver(pipeline: pipeline)

        driver.submit(.pressed)
        await pipeline.waitUntilActivationStarts()
        driver.submit(.released)

        let cancellationResult = await XCTWaiter().fulfillment(
            of: [activationCancelled], timeout: 0.2)

        await pipeline.rejectActivation()
        await driver.waitForSubmittedEvents()

        let completionAttempts = await pipeline.scopedCompletionAttempts
        XCTAssertEqual(cancellationResult, .completed)
        XCTAssertEqual(completionAttempts, [])
        driver.invalidate()
    }

    func testReleaseRaceCompletesAcceptedSessionExactlyOnce() async {
        let activationCancelled = expectation(
            description: "pending activation cancelled")
        let pipeline = GatedHotkeyPipeline(
            activationCancelled: { activationCancelled.fulfill() })
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let sessionID = DictationSessionID()

        driver.submit(.pressed)
        await pipeline.waitUntilActivationStarts()
        driver.submit(.released)
        await fulfillment(of: [activationCancelled], timeout: 1.0)

        // Model the exact cancellation boundary: the provider admitted the
        // session immediately before it observed caller cancellation.
        await pipeline.releaseActivation(with: sessionID)
        await pipeline.waitUntilCompletionFinishes(for: sessionID)

        driver.submit(.released)
        await driver.waitForSubmittedEvents()

        let completionAttempts = await pipeline.scopedCompletionAttempts
        XCTAssertEqual(completionAttempts, [sessionID])
        driver.invalidate()
    }

    func testPendingActivationUsesOriginalReleaseHostTime() async {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let sessionID = DictationSessionID()
        let releaseHostTime: UInt64 = 43_000

        driver.submit(.pressed)
        await pipeline.waitUntilActivationStarts()
        driver.submit(.released, hostTime: releaseHostTime)
        await driver.waitForSubmittedCommands()

        await pipeline.releaseActivation(with: sessionID)
        await driver.waitForSubmittedEvents()

        let completions = await pipeline.timestampedCompletionAttempts
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.sessionID, sessionID)
        XCTAssertEqual(completions.first?.releaseHostTime, releaseHostTime)
        driver.invalidate()
    }

    func testDuplicatePressCannotReplacePhysicalReleaseBoundary() async {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let incorrectlyAcceptedSession = DictationSessionID()
        let releaseHostTime: UInt64 = 43_500

        await pipeline.rejectActivation()
        driver.submit(.pressed)
        await driver.waitForSubmittedEvents()
        let firstBoundaries = await pipeline.activationReleaseBoundaries
        XCTAssertEqual(firstBoundaries.count, 1)

        // The physical key is still down. A repeated key-down must not create
        // a second press whose capture boundary differs from key-up ownership.
        await pipeline.releaseActivation(with: incorrectlyAcceptedSession)
        driver.submit(.pressed)
        await driver.waitForSubmittedCommands()
        driver.submit(.released, hostTime: releaseHostTime)
        await driver.waitForSubmittedEvents()

        let activationCount = await pipeline.activationStartCount
        let boundaries = await pipeline.activationReleaseBoundaries
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(boundaries.first?.releaseHostTime, releaseHostTime)
        driver.invalidate()
    }

    func testReleaseDoesNotWaitForSessionAcceptedObserver() async {
        let pipeline = GatedHotkeyPipeline()
        let observerGate = HotkeyObserverGate()
        let observerStarted = expectation(description: "observer started")
        let driver = HotkeyPipelineDriver(
            pipeline: pipeline,
            sessionAccepted: { _ in
                observerStarted.fulfill()
                await observerGate.waitForRelease()
            })
        let sessionID = DictationSessionID()

        await pipeline.releaseActivation(with: sessionID)
        driver.submit(.pressed)
        await fulfillment(of: [observerStarted], timeout: 1.0)

        let completionFinished = expectation(
            description: "physical release completes while observer is stalled")
        let completionProbe = Task {
            await pipeline.waitUntilCompletionFinishes(for: sessionID)
            completionFinished.fulfill()
        }
        driver.submit(.released)

        let result = await XCTWaiter().fulfillment(
            of: [completionFinished], timeout: 0.2)
        await observerGate.release()
        await completionProbe.value
        await driver.waitForSubmittedEvents()

        let completionAttempts = await pipeline.scopedCompletionAttempts
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(completionAttempts, [sessionID])
        driver.invalidate()
    }

    func testReleaseWaitsForAcceptedPressAndUsesItsSessionID() async {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)

        driver.submit(.pressed)
        await pipeline.waitUntilActivationStarts()
        driver.submit(.released)

        let beforeRelease = await pipeline.events
        XCTAssertEqual(beforeRelease, [.activationStarted])

        let sessionID = DictationSessionID()
        await pipeline.releaseActivation(with: sessionID)
        await driver.waitForSubmittedEvents()
        await pipeline.waitUntilCompletionFinishes(for: sessionID)

        let events = await pipeline.events
        XCTAssertEqual(
            events,
            [
                .activationStarted,
                .activationReturned(sessionID),
                .completed(sessionID),
            ])
    }

    func testLateReleaseCannotCompleteExternallyStartedReplacement() async {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let firstSession = DictationSessionID()
        let replacementSession = DictationSessionID()

        driver.submit(.pressed)
        await pipeline.waitUntilActivationStarts()
        await pipeline.releaseActivation(with: firstSession)
        await driver.waitForSubmittedEvents()

        await pipeline.replaceActiveSession(with: replacementSession)
        driver.submit(.released)
        await driver.waitForSubmittedEvents()
        await pipeline.waitUntilCompletionStarts(for: firstSession)

        let activeSessionID = await pipeline.activeSessionID
        let completionAttempts = await pipeline.scopedCompletionAttempts
        XCTAssertEqual(activeSessionID, replacementSession)
        XCTAssertEqual(completionAttempts, [firstSession])
    }

    func testPressReleaseDuringCompletionIsRejectedAndNotReplayed() async {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let firstSession = DictationSessionID()
        let rejectedSession = DictationSessionID()

        await pipeline.gateCompletion(for: firstSession)
        await pipeline.releaseActivation(with: firstSession)
        driver.submit(.pressed)
        driver.submit(.released)
        await pipeline.waitUntilCompletionStarts(for: firstSession)
        await driver.waitForSubmittedCommands()

        // Supply a result so an incorrect second activation cannot block the
        // command barrier and disguise itself as prompt rejection.
        await pipeline.releaseActivation(with: rejectedSession)
        driver.submit(.pressed)
        driver.submit(.released)
        await driver.waitForSubmittedCommands()

        var activationCount = await pipeline.activationStartCount
        var completionAttempts = await pipeline.scopedCompletionAttempts
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(completionAttempts, [firstSession])

        await pipeline.releaseCompletion(for: firstSession)
        await pipeline.waitUntilCompletionFinishes(for: firstSession)
        await driver.waitForSubmittedEvents()

        activationCount = await pipeline.activationStartCount
        completionAttempts = await pipeline.scopedCompletionAttempts
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(completionAttempts, [firstSession])
    }

    func testPressAfterPipelineIdleIsNotDroppedByCompletionBookkeeping() async {
        let pipeline = GatedHotkeyPipeline()
        let acceptedSessions = expectation(description: "sessions accepted")
        acceptedSessions.expectedFulfillmentCount = 2
        let driver = HotkeyPipelineDriver(
            pipeline: pipeline,
            sessionAccepted: { _ in acceptedSessions.fulfill() })
        let firstSession = DictationSessionID()
        let replacementSession = DictationSessionID()

        await pipeline.gateCompletion(for: firstSession)
        await pipeline.releaseOwnershipBeforeCompletionReturns(
            for: firstSession)
        await pipeline.releaseActivation(with: firstSession)
        driver.submit(.pressed)
        await driver.waitForSubmittedEvents()

        driver.submit(.released)
        await pipeline.waitUntilCompletionStarts(for: firstSession)
        await pipeline.releaseActivation(with: replacementSession)
        driver.submit(.pressed)
        await fulfillment(of: [acceptedSessions], timeout: 1.0)

        let activationCount = await pipeline.activationStartCount
        let currentSessionID = await pipeline.currentSessionID
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(currentSessionID, replacementSession)

        await pipeline.releaseCompletion(for: firstSession)
        driver.invalidate()
    }

    func testInvalidateWhilePressIsHeldScopedCancelsAcceptedSession() async {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let sessionID = DictationSessionID()

        await pipeline.releaseActivation(with: sessionID)
        driver.submit(.pressed)
        await driver.waitForSubmittedEvents()

        driver.invalidate()
        await pipeline.waitUntilCancellationStarts(for: sessionID)

        let currentSessionID = await pipeline.currentSessionID
        let cancellationAttempts = await pipeline.scopedCancellationAttempts
        let unscopedCancelCount = await pipeline.unscopedCancelCount
        XCTAssertNil(currentSessionID)
        XCTAssertEqual(cancellationAttempts, [sessionID])
        XCTAssertEqual(unscopedCancelCount, 0)
    }

    func testTransferReturnsHeldSessionAndMakesPhysicalReleaseANoOp() async {
        let pipeline = GatedHotkeyPipeline()
        let accepted = expectation(description: "held session accepted")
        let recorder = HeldSessionRecorder()
        let driver = HotkeyPipelineDriver(
            pipeline: pipeline,
            heldSessionAccepted: { heldSession in
                await recorder.record(heldSession)
                accepted.fulfill()
            })
        let sessionID = DictationSessionID()

        await pipeline.releaseActivation(with: sessionID)
        driver.submit(.pressed)
        await driver.waitForSubmittedEvents()
        await fulfillment(of: [accepted], timeout: 1.0)
        guard let heldSession = await recorder.heldSession else {
            return XCTFail("Held session was not reported")
        }

        let transferCompleted = expectation(description: "transfer completed")
        let transferRecorder = HeldSessionRecorder()
        let transferredBoundary = driver.transferHeldSession { transferred in
            Task {
                if let transferred {
                    await transferRecorder.record(transferred)
                }
                transferCompleted.fulfill()
            }
        }
        XCTAssertTrue(transferredBoundary === heldSession.releaseBoundary)
        await fulfillment(of: [transferCompleted], timeout: 1.0)
        let transferredSession = await transferRecorder.heldSession
        XCTAssertEqual(transferredSession?.sessionID, sessionID)

        driver.submit(.released)
        await driver.waitForSubmittedEvents()

        let currentSessionID = await pipeline.currentSessionID
        let completionAttempts = await pipeline.scopedCompletionAttempts
        XCTAssertEqual(currentSessionID, sessionID)
        XCTAssertEqual(completionAttempts, [])

        driver.invalidate()
    }

    func testTransferDuringPendingActivationDetachesPhysicalReleaseImmediately() async throws {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let sessionID = DictationSessionID()
        let transferred = expectation(description: "pending activation transferred")

        driver.submit(.pressed)
        await pipeline.waitUntilActivationStarts()
        let boundaries = await pipeline.activationReleaseBoundaries
        let pressBoundary = try XCTUnwrap(boundaries.first)

        let transferredBoundary = driver.transferHeldSession { heldSession in
            XCTAssertEqual(heldSession?.sessionID, sessionID)
            transferred.fulfill()
        }
        XCTAssertTrue(transferredBoundary === pressBoundary)

        driver.submit(.released, hostTime: 44_000)
        XCTAssertNil(pressBoundary.releaseHostTime)

        await pipeline.releaseActivation(with: sessionID)
        await fulfillment(of: [transferred], timeout: 1.0)
        await driver.waitForSubmittedEvents()
        let completionAttempts = await pipeline.scopedCompletionAttempts
        XCTAssertEqual(completionAttempts, [])
        driver.invalidate()
    }

    func testRejectedPressDoesNotCorruptHUDOwnedSession() async {
        let pipeline = GatedHotkeyPipeline()
        let driver = HotkeyPipelineDriver(pipeline: pipeline)
        let hudSessionID = DictationSessionID()

        await pipeline.replaceActiveSession(with: hudSessionID)
        await pipeline.rejectActivation()
        driver.submit(.pressed)
        driver.submit(.released)
        await driver.waitForSubmittedEvents()

        let currentSessionID = await pipeline.currentSessionID
        let completionAttempts = await pipeline.scopedCompletionAttempts
        let cancellationAttempts = await pipeline.scopedCancellationAttempts
        XCTAssertEqual(currentSessionID, hudSessionID)
        XCTAssertEqual(completionAttempts, [])
        XCTAssertEqual(cancellationAttempts, [])

        driver.invalidate()
    }

    func testCompletionThatRetainsSessionDoesNotReportSessionEnded() async {
        let pipeline = GatedHotkeyPipeline()
        let sessionEnded = expectation(description: "session ended")
        sessionEnded.isInverted = true
        let driver = HotkeyPipelineDriver(
            pipeline: pipeline,
            sessionEnded: { _ in sessionEnded.fulfill() })
        let sessionID = DictationSessionID()

        await pipeline.retainActiveSessionAfterCompletion(for: sessionID)
        await pipeline.releaseActivation(with: sessionID)
        driver.submit(.pressed)
        await driver.waitForSubmittedEvents()

        driver.submit(.released)
        await pipeline.waitUntilCompletionFinishes(for: sessionID)

        let currentSessionID = await pipeline.currentSessionID
        XCTAssertEqual(currentSessionID, sessionID)
        await fulfillment(of: [sessionEnded], timeout: 0.1)

        driver.invalidate()
    }

    func testCompletionThatReleasesSessionReportsSessionEnded() async {
        let pipeline = GatedHotkeyPipeline()
        let endedSessions = SessionEndedRecorder()
        let sessionEnded = expectation(description: "session ended")
        let driver = HotkeyPipelineDriver(
            pipeline: pipeline,
            sessionEnded: { sessionID in
                await endedSessions.record(sessionID)
                sessionEnded.fulfill()
            })
        let sessionID = DictationSessionID()

        await pipeline.releaseActivation(with: sessionID)
        driver.submit(.pressed)
        await driver.waitForSubmittedEvents()

        driver.submit(.released)
        await fulfillment(of: [sessionEnded], timeout: 1.0)

        let currentSessionID = await pipeline.currentSessionID
        let reportedSessions = await endedSessions.sessions
        XCTAssertNil(currentSessionID)
        XCTAssertEqual(reportedSessions, [sessionID])

        driver.invalidate()
    }
}

private actor HotkeyObserverGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor SessionEndedRecorder {
    private(set) var sessions: [DictationSessionID] = []

    func record(_ sessionID: DictationSessionID) {
        sessions.append(sessionID)
    }
}

private actor HeldSessionRecorder {
    private(set) var heldSession: HotkeyHeldSession?

    func record(_ heldSession: HotkeyHeldSession) {
        self.heldSession = heldSession
    }
}

private actor GatedHotkeyPipeline: PipelineProviding {
    enum Event: Equatable {
        case activationStarted
        case activationReturned(DictationSessionID)
        case completed(DictationSessionID)
    }

    private(set) var events: [Event] = []
    private(set) var activeSessionID: DictationSessionID?
    private(set) var activationStartCount = 0
    private(set) var scopedCompletionAttempts: [DictationSessionID] = []
    private(set) var scopedCancellationAttempts: [DictationSessionID] = []
    private(set) var unscopedCancelCount = 0
    private var activationStarted = false
    private var activationResults: [DictationSessionID?] = []
    private var activationWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiters:
        [CheckedContinuation<DictationSessionID?, Never>] = []
    private var retainedCompletionSessions: Set<DictationSessionID> = []
    private var idleBeforeCompletionReturns: Set<DictationSessionID> = []
    private var gatedCompletions: Set<DictationSessionID> = []
    private var startedCompletions: Set<DictationSessionID> = []
    private var finishedCompletions: Set<DictationSessionID> = []
    private var completionStartWaiters:
        [DictationSessionID: [CheckedContinuation<Void, Never>]] = [:]
    private var completionReleaseWaiters:
        [DictationSessionID: [CheckedContinuation<Void, Never>]] = [:]
    private var completionFinishWaiters:
        [DictationSessionID: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var timestampedCompletionAttempts:
        [(sessionID: DictationSessionID, releaseHostTime: UInt64)] = []
    private(set) var activationReleaseBoundaries:
        [AudioCaptureReleaseBoundary] = []
    private var startedCancellations: Set<DictationSessionID> = []
    private var cancellationStartWaiters:
        [DictationSessionID: [CheckedContinuation<Void, Never>]] = [:]
    nonisolated private let activationCancelled: @Sendable () -> Void

    init(activationCancelled: @escaping @Sendable () -> Void = {}) {
        self.activationCancelled = activationCancelled
    }

    var state: RecordingState {
        get async { activeSessionID == nil ? .idle : .recording }
    }

    var currentSessionID: DictationSessionID? {
        get async { activeSessionID }
    }

    func activate() async -> DictationSessionID? {
        activationStarted = true
        activationStartCount += 1
        events.append(.activationStarted)
        activationWaiters.forEach { $0.resume() }
        activationWaiters.removeAll()

        let sessionID: DictationSessionID? = await withTaskCancellationHandler {
            if !activationResults.isEmpty {
                return activationResults.removeFirst()
            }
            return await withCheckedContinuation { continuation in
                resultWaiters.append(continuation)
            }
        } onCancel: {
            activationCancelled()
        }
        guard let sessionID else { return nil }
        activeSessionID = sessionID
        events.append(.activationReturned(sessionID))
        return sessionID
    }

    func activate(
        releaseBoundary: AudioCaptureReleaseBoundary
    ) async -> DictationSessionID? {
        activationReleaseBoundaries.append(releaseBoundary)
        return await activate()
    }

    func complete() async {
        guard let activeSessionID else { return }
        await complete(sessionID: activeSessionID)
    }

    func complete(sessionID: DictationSessionID) async {
        scopedCompletionAttempts.append(sessionID)
        startedCompletions.insert(sessionID)
        completionStartWaiters.removeValue(forKey: sessionID)?
            .forEach { $0.resume() }

        if activeSessionID == sessionID,
            idleBeforeCompletionReturns.contains(sessionID)
        {
            activeSessionID = nil
        }

        if gatedCompletions.contains(sessionID) {
            await withCheckedContinuation { continuation in
                completionReleaseWaiters[sessionID, default: []]
                    .append(continuation)
            }
        }

        if activeSessionID == sessionID,
           !retainedCompletionSessions.contains(sessionID)
        {
            activeSessionID = nil
            events.append(.completed(sessionID))
        }
        finishedCompletions.insert(sessionID)
        completionFinishWaiters.removeValue(forKey: sessionID)?
            .forEach { $0.resume() }
    }

    func complete(
        sessionID: DictationSessionID,
        releaseHostTime: UInt64
    ) async {
        timestampedCompletionAttempts.append((sessionID, releaseHostTime))
        await complete(sessionID: sessionID)
    }

    func cancel() async {
        unscopedCancelCount += 1
        activeSessionID = nil
    }

    func cancel(sessionID: DictationSessionID) async {
        scopedCancellationAttempts.append(sessionID)
        startedCancellations.insert(sessionID)
        cancellationStartWaiters.removeValue(forKey: sessionID)?
            .forEach { $0.resume() }
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
    }

    func waitUntilActivationStarts() async {
        guard !activationStarted else { return }
        await withCheckedContinuation { continuation in
            activationWaiters.append(continuation)
        }
    }

    func releaseActivation(with sessionID: DictationSessionID) {
        resolveActivation(with: sessionID)
    }

    func rejectActivation() {
        resolveActivation(with: nil)
    }

    private func resolveActivation(with sessionID: DictationSessionID?) {
        if resultWaiters.isEmpty {
            activationResults.append(sessionID)
        } else {
            let continuation = resultWaiters.removeFirst()
            continuation.resume(returning: sessionID)
        }
    }

    func replaceActiveSession(with sessionID: DictationSessionID) {
        activeSessionID = sessionID
    }

    func retainActiveSessionAfterCompletion(for sessionID: DictationSessionID) {
        retainedCompletionSessions.insert(sessionID)
    }

    func gateCompletion(for sessionID: DictationSessionID) {
        gatedCompletions.insert(sessionID)
    }

    func releaseOwnershipBeforeCompletionReturns(
        for sessionID: DictationSessionID
    ) {
        idleBeforeCompletionReturns.insert(sessionID)
    }

    func waitUntilCompletionStarts(for sessionID: DictationSessionID) async {
        guard !startedCompletions.contains(sessionID) else { return }
        await withCheckedContinuation { continuation in
            completionStartWaiters[sessionID, default: []].append(continuation)
        }
    }

    func releaseCompletion(for sessionID: DictationSessionID) {
        gatedCompletions.remove(sessionID)
        completionReleaseWaiters.removeValue(forKey: sessionID)?
            .forEach { $0.resume() }
    }

    func waitUntilCompletionFinishes(for sessionID: DictationSessionID) async {
        guard !finishedCompletions.contains(sessionID) else { return }
        await withCheckedContinuation { continuation in
            completionFinishWaiters[sessionID, default: []].append(continuation)
        }
    }

    func waitUntilCancellationStarts(for sessionID: DictationSessionID) async {
        guard !startedCancellations.contains(sessionID) else { return }
        await withCheckedContinuation { continuation in
            cancellationStartWaiters[sessionID, default: []].append(continuation)
        }
    }
}
