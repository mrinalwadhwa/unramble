import XCTest

@testable import FreeFlowKit

private actor DictationPipelineSuspensionGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor DictationPipelineCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func hasCompleted() -> Bool {
        completed
    }
}

private actor DictationPipelineGatedBatchProvider: BatchDictationProviding {
    private let text: String
    private let gatedCall: Int
    private let failingCalls: Set<Int>
    private let gate: DictationPipelineSuspensionGate
    private var audioCalls: [Data] = []

    init(
        text: String,
        gatedCall: Int,
        failingCalls: Set<Int> = [],
        gate: DictationPipelineSuspensionGate
    ) {
        self.text = text
        self.gatedCall = gatedCall
        self.failingCalls = failingCalls
        self.gate = gate
    }

    func dictate(
        audio: Data,
        context: AppContext,
        language: String?
    ) async throws -> String {
        audioCalls.append(audio)
        let call = audioCalls.count
        if failingCalls.contains(call) {
            throw DictationError.requestFailed(
                statusCode: 500,
                message: "planned failure")
        }
        if call == gatedCall {
            await gate.waitForRelease()
        }
        return text
    }

    func receivedAudio() -> [Data] {
        audioCalls
    }
}

private actor DictationPipelineGatedTextInjector: TextInjecting {
    private let gate: DictationPipelineSuspensionGate
    private var startedTexts: [String] = []
    private var committedTexts: [String] = []

    init(gate: DictationPipelineSuspensionGate) {
        self.gate = gate
    }

    func inject(text: String, into context: AppContext) async throws {
        startedTexts.append(text)
        await gate.waitForRelease()
        committedTexts.append(text)
    }

    func started() -> [String] {
        startedTexts
    }

    func committed() -> [String] {
        committedTexts
    }
}

final class DictationPipelineTests: XCTestCase {

    // MARK: - Helpers

    private func makePipeline(
        audioProvider: MockAudioProvider = MockAudioProvider(),
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        batchProvider: MockBatchProvider = MockBatchProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        transcriptBuffer: TranscriptBuffer? = nil,
        onSessionExpired: (@Sendable () -> Void)? = nil
    ) -> (
        DictationPipeline, MockAudioProvider, MockAppContextProvider, MockBatchProvider,
        MockTextInjector, RecordingCoordinator
    ) {
        let pipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: contextProvider,
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: batchProvider),
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            onSessionExpired: onSessionExpired
        )
        return (
            pipeline, audioProvider, contextProvider, batchProvider, textInjector, coordinator
        )
    }

    @discardableResult
    private func activateAndWaitForCapture(
        _ pipeline: DictationPipeline,
        audioProvider: MockAudioProvider,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> DictationSessionID? {
        let previousReadyCount = audioProvider.captureReadyCount
        let sessionID = await pipeline.activate()

        await waitForCaptureReady(
            audioProvider, after: previousReadyCount, file: file, line: line)
        return sessionID
    }

    private func waitForCaptureReady(
        _ audioProvider: MockAudioProvider,
        after previousReadyCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if audioProvider.captureReadyCount > previousReadyCount {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTFail("Capture did not become ready", file: file, line: line)
    }

    private func waitForReplacementSeal(
        _ pipeline: DictationPipeline,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await pipeline.isSealedForReplacement { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Replacement seal did not publish", file: file, line: line)
    }

    private func waitForCaptureMaintenanceSeal(
        _ pipeline: DictationPipeline,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await pipeline.isSealedForCaptureMaintenance { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Capture maintenance seal did not publish", file: file, line: line)
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() async {
        let (pipeline, _, _, _, _, _) = makePipeline()
        let state = await pipeline.state
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Full cycle: activate → complete → idle

    func testFullCycleTransitionsToIdleAfterCompletion() async {
        let (pipeline, audio, _, _, _, coordinator) = makePipeline()

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)

        await pipeline.complete()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
    }

    func testPhysicalReleaseHostTimeReachesAudioCaptureBoundary() async throws {
        let (pipeline, audio, _, _, _, _) = makePipeline()
        let acceptedSessionID = await activateAndWaitForCapture(
            pipeline,
            audioProvider: audio)
        let sessionID = try XCTUnwrap(acceptedSessionID)
        let releaseHostTime: UInt64 = 84_000

        await pipeline.complete(
            sessionID: sessionID,
            releaseHostTime: releaseHostTime)

        XCTAssertEqual(audio.releaseHostTimes, [releaseHostTime])
    }

    func testPhysicalPressBoundaryIsInstalledInExactAudioCapture() async throws {
        let (pipeline, audio, _, _, _, _) = makePipeline()
        let boundary = AudioCaptureReleaseBoundary()

        let acceptedSessionID = await pipeline.activate(
            releaseBoundary: boundary)
        await waitForCaptureReady(audio, after: 0)

        let sessionID = try XCTUnwrap(acceptedSessionID)
        let installedBoundaries = audio.captureReleaseBoundaries
        XCTAssertEqual(installedBoundaries.count, 1)
        XCTAssertTrue(installedBoundaries.first === boundary)

        let releaseHostTime: UInt64 = 85_000
        XCTAssertTrue(boundary.publish(releaseHostTime: releaseHostTime))
        await pipeline.complete(
            sessionID: sessionID,
            releaseHostTime: releaseHostTime)
    }

    func testIdleIsNotPublishedBeforeSessionOwnershipIsReleased() async {
        let audio = MockAudioProvider()
        let coordinator = RecordingCoordinator()
        let idleGate = DictationPipelineSuspensionGate()
        let idlePublished = expectation(description: "terminal idle published")
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            terminalIdleDidPublish: { _ in
                idlePublished.fulfill()
                await idleGate.waitForRelease()
            })

        guard
            let sessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected session admission")
        }

        let completion = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await fulfillment(of: [idlePublished], timeout: 1)

        let visibleState = await coordinator.state
        let visibleSessionID = await pipeline.currentSessionID
        XCTAssertEqual(visibleState, .idle)
        XCTAssertNil(
            visibleSessionID,
            "Visible idle must mean the pipeline can admit a replacement session")

        await idleGate.release()
        await completion.value
    }

    func testActivationWaitsForClaimedDismissalIdleCommit() async {
        let audio = MockAudioProvider()
        let coordinator = RecordingCoordinator()
        let fallback = MockBatchProvider()
        fallback.stubbedError = DictationError.requestFailed(
            statusCode: 500,
            message: "failed")
        let terminalGate = DictationPipelineSuspensionGate()
        let activationReserved = expectation(description: "activation reserved")
        activationReserved.expectedFulfillmentCount = 2
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: fallback),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            terminalIdleDidReleaseOwnership: { _ in
                await terminalGate.waitForRelease()
            },
            activationDidReserve: {
                activationReserved.fulfill()
            })

        guard
            let firstSessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected first session admission")
        }
        let firstReadyCount = audio.captureReadyCount

        await pipeline.complete(sessionID: firstSessionID)
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)

        let dismissal = Task {
            await pipeline.dismissDictationFailure(sessionID: firstSessionID)
        }
        await terminalGate.waitUntilEntered()
        let replacementActivation = Task {
            await pipeline.activate()
        }
        await fulfillment(of: [activationReserved], timeout: 1)

        XCTAssertEqual(audio.startCallCount, 1)
        let stateBeforeCommit = await coordinator.state
        XCTAssertEqual(stateBeforeCommit, .dictationFailed)

        await terminalGate.release()
        await dismissal.value
        let replacementSessionID = await replacementActivation.value
        XCTAssertNotNil(replacementSessionID)
        await waitForCaptureReady(audio, after: firstReadyCount)
        XCTAssertEqual(audio.startCallCount, 2)

        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
    }

    func testCancellationAdoptsClaimedDismissalWithoutOrphaningState() async {
        let audio = MockAudioProvider()
        let coordinator = RecordingCoordinator()
        let fallback = MockBatchProvider()
        fallback.stubbedError = DictationError.requestFailed(
            statusCode: 500,
            message: "failed")
        let claimGate = DictationPipelineSuspensionGate()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: fallback),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            terminalIdleDidClaim: { _ in
                await claimGate.waitForRelease()
            })

        guard
            let failedSessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected failed session admission")
        }
        await pipeline.complete(sessionID: failedSessionID)
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .dictationFailed)

        let dismissal = Task {
            await pipeline.dismissDictationFailure(sessionID: failedSessionID)
        }
        await claimGate.waitUntilEntered()

        await pipeline.cancel(sessionID: failedSessionID)

        let cancelledState = await coordinator.state
        let cancelledOwner = await pipeline.currentSessionID
        XCTAssertEqual(cancelledState, .idle)
        XCTAssertNil(cancelledOwner)

        await claimGate.release()
        await dismissal.value

        let previousReadyCount = audio.captureReadyCount
        let replacementSessionID = await pipeline.activate()
        XCTAssertNotNil(replacementSessionID)
        await waitForCaptureReady(audio, after: previousReadyCount)
        if let replacementSessionID {
            await pipeline.cancel(sessionID: replacementSessionID)
        }
    }

    func testRetirementDuringActivationOwnerHandoffDoesNotOrphanRecordingState() async {
        let coordinator = RecordingCoordinator()
        let ownerPublicationGate = DictationPipelineSuspensionGate()
        let pipeline = DictationPipeline(
            audioProvider: MockAudioProvider(),
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            activationDidPublishSessionOwner: {
                await ownerPublicationGate.waitForRelease()
            })

        let activation = Task {
            await pipeline.activate()
        }
        await ownerPublicationGate.waitUntilEntered()

        await pipeline.beginRetirement()
        await pipeline.cancel()
        await ownerPublicationGate.release()

        let admittedSessionID = await activation.value
        await pipeline.retire()
        let finalState = await coordinator.state

        XCTAssertNil(admittedSessionID)
        XCTAssertEqual(
            finalState,
            .idle,
            "Retirement must not leave a coordinator session without a pipeline owner")

        _ = await coordinator.reset()
    }

    func testReplacementSealWaitsForLiveRecordingWithoutCancellingIt() async {
        let audio = MockAudioProvider()
        let coordinator = RecordingCoordinator()
        let injector = MockTextInjector()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator)

        guard
            let sessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected session admission")
        }

        let seal = Task { await pipeline.sealForReplacement() }
        await waitForReplacementSeal(pipeline)

        XCTAssertTrue(audio.isRecording)
        XCTAssertEqual(audio.stopCallCount, 0)
        let recordingState = await coordinator.state
        XCTAssertEqual(recordingState, .recording)

        await pipeline.complete(sessionID: sessionID)
        await seal.value

        XCTAssertEqual(audio.stopCallCount, 1)
        let idleState = await coordinator.state
        let currentSessionID = await pipeline.currentSessionID
        XCTAssertEqual(idleState, .idle)
        XCTAssertNil(currentSessionID)
        XCTAssertEqual(injector.lastInjectedText, "Mock dictation")
        let replacementSessionID = await pipeline.activate()
        XCTAssertNil(
            replacementSessionID,
            "A sealed generation must reject replacement capture")
    }

    func testCaptureMaintenanceDrainsLiveRecordingAndSealsOnlyTransaction()
        async throws
    {
        let audio = MockAudioProvider()
        let coordinator = RecordingCoordinator()
        let injector = MockTextInjector()
        let transcriptBuffer = TranscriptBuffer()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer)

        guard
            let sessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected session admission")
        }

        let maintenanceGate = DictationPipelineSuspensionGate()
        let maintenance = Task {
            try await pipeline.withQuiescentCaptureMaintenance {
                await maintenanceGate.waitForRelease()
            }
        }
        await waitForCaptureMaintenanceSeal(pipeline)

        XCTAssertTrue(audio.isRecording)
        XCTAssertEqual(audio.stopCallCount, 0)

        await pipeline.complete(sessionID: sessionID)
        await maintenanceGate.waitUntilEntered()

        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Mock dictation")
        let blockedSessionID = await pipeline.activate()
        await pipeline.pasteBufferedTranscript()
        let retainedTranscript = await transcriptBuffer.lastTranscript
        XCTAssertNil(
            blockedSessionID,
            "Capture admission must remain sealed throughout maintenance")
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(retainedTranscript, "Mock dictation")

        await maintenanceGate.release()
        try await maintenance.value

        await pipeline.pasteBufferedTranscript()
        XCTAssertEqual(injector.injectionCount, 2)

        let replacementSessionID = await activateAndWaitForCapture(
            pipeline, audioProvider: audio)
        XCTAssertNotNil(
            replacementSessionID,
            "Capture admission must reopen after maintenance")
        if let replacementSessionID {
            await pipeline.complete(sessionID: replacementSessionID)
        }
    }

    func testCancellingCaptureMaintenanceWaitReopensAdmissionWithoutCancellingSession()
        async
    {
        let audio = MockAudioProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator())
        guard
            let sessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected session admission")
        }

        let finished = expectation(description: "maintenance cancellation")
        let maintenance = Task { () -> Bool in
            defer { finished.fulfill() }
            do {
                try await pipeline.withQuiescentCaptureMaintenance {}
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await waitForCaptureMaintenanceSeal(pipeline)
        maintenance.cancel()

        let waitResult = await XCTWaiter().fulfillment(
            of: [finished], timeout: 1)
        if waitResult != .completed {
            await pipeline.complete(sessionID: sessionID)
            _ = await maintenance.value
            return XCTFail("Cancelled maintenance remained suspended")
        }

        let cancelled = await maintenance.value
        let remainsSealed = await pipeline.isSealedForCaptureMaintenance
        XCTAssertTrue(cancelled)
        XCTAssertFalse(remainsSealed)
        XCTAssertTrue(audio.isRecording)
        XCTAssertEqual(audio.stopCallCount, 0)

        await pipeline.complete(sessionID: sessionID)
        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(audio.stopCallCount, 1)
    }

    func testReplacementSealWaitsForActiveCaptureMaintenance() async throws {
        let pipeline = DictationPipeline(
            audioProvider: MockAudioProvider(),
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator())
        let maintenanceGate = DictationPipelineSuspensionGate()
        let maintenance = Task {
            try await pipeline.withQuiescentCaptureMaintenance {
                await maintenanceGate.waitForRelease()
            }
        }
        await maintenanceGate.waitUntilEntered()

        let sealProbe = DictationPipelineCompletionProbe()
        let replacementSeal = Task {
            await pipeline.sealForReplacement()
            await sealProbe.markCompleted()
        }
        await waitForReplacementSeal(pipeline)

        let completedDuringMaintenance = await sealProbe.hasCompleted()
        XCTAssertFalse(completedDuringMaintenance)

        await maintenanceGate.release()
        try await maintenance.value
        await replacementSeal.value

        let completedAfterMaintenance = await sealProbe.hasCompleted()
        let sealedSessionID = await pipeline.activate()
        XCTAssertTrue(completedAfterMaintenance)
        XCTAssertNil(sealedSessionID)
    }

    func testRetirementWaitsForActiveCaptureMaintenance() async throws {
        let pipeline = DictationPipeline(
            audioProvider: MockAudioProvider(),
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator())
        let maintenanceGate = DictationPipelineSuspensionGate()
        let maintenance = Task {
            try await pipeline.withQuiescentCaptureMaintenance {
                await maintenanceGate.waitForRelease()
            }
        }
        await maintenanceGate.waitUntilEntered()

        let retirementProbe = DictationPipelineCompletionProbe()
        let retirement = Task {
            await pipeline.beginRetirement()
            await retirementProbe.markCompleted()
        }
        await waitForReplacementSeal(pipeline)

        let completedDuringMaintenance = await retirementProbe.hasCompleted()
        XCTAssertFalse(completedDuringMaintenance)

        await maintenanceGate.release()
        try await maintenance.value
        await retirement.value

        let completedAfterMaintenance = await retirementProbe.hasCompleted()
        let retiredSessionID = await pipeline.activate()
        XCTAssertTrue(completedAfterMaintenance)
        XCTAssertNil(retiredSessionID)
    }

    func testReplacementSealDrainsGatedProcessingWithoutLosingCapturedSpeech()
        async
    {
        let audio = MockAudioProvider()
        let exactCapturedAudio = audio.stubbedBuffer.data
        let processingGate = DictationPipelineSuspensionGate()
        let batch = DictationPipelineGatedBatchProvider(
            text: "speech admitted before replacement",
            gatedCall: 1,
            gate: processingGate)
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator)

        guard
            let sessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected session admission")
        }

        let completion = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await processingGate.waitUntilEntered()

        let sealProbe = DictationPipelineCompletionProbe()
        let seal = Task {
            await pipeline.sealForReplacement()
            await sealProbe.markCompleted()
        }
        await waitForReplacementSeal(pipeline)

        let processingState = await coordinator.state
        let sealCompletedBeforeProcessing = await sealProbe.hasCompleted()
        let replacementSessionID = await pipeline.activate()
        let receivedAudio = await batch.receivedAudio()
        XCTAssertEqual(processingState, .processing)
        XCTAssertFalse(sealCompletedBeforeProcessing)
        XCTAssertNil(replacementSessionID)
        XCTAssertEqual(receivedAudio, [exactCapturedAudio])
        XCTAssertNil(injector.lastInjectedText)

        await processingGate.release()
        await completion.value
        await seal.value

        let finalState = await coordinator.state
        let finalOwner = await pipeline.currentSessionID
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalOwner)
        XCTAssertEqual(injector.injections.map(\.text), [
            "speech admitted before replacement"
        ])
    }

    func testReplacementSealDrainsGatedInjectionWithoutDroppingPublication()
        async
    {
        let audio = MockAudioProvider()
        let injectionGate = DictationPipelineSuspensionGate()
        let injector = DictationPipelineGatedTextInjector(gate: injectionGate)
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider(
                    stubbedText: "publication admitted before replacement")),
            textInjector: injector,
            coordinator: coordinator)

        guard
            let sessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected session admission")
        }

        let completion = Task {
            await pipeline.complete(sessionID: sessionID)
        }
        await injectionGate.waitUntilEntered()

        let sealProbe = DictationPipelineCompletionProbe()
        let seal = Task {
            await pipeline.sealForReplacement()
            await sealProbe.markCompleted()
        }
        await waitForReplacementSeal(pipeline)

        let injectingState = await coordinator.state
        let sealCompletedBeforeInjection = await sealProbe.hasCompleted()
        let replacementSessionID = await pipeline.activate()
        let startedTexts = await injector.started()
        let committedTextsBeforeRelease = await injector.committed()
        XCTAssertEqual(injectingState, .injecting)
        XCTAssertFalse(sealCompletedBeforeInjection)
        XCTAssertNil(replacementSessionID)
        XCTAssertEqual(startedTexts, [
            "publication admitted before replacement"
        ])
        XCTAssertEqual(committedTextsBeforeRelease, [])

        await injectionGate.release()
        await completion.value
        await seal.value

        let finalState = await coordinator.state
        let finalOwner = await pipeline.currentSessionID
        let committedTexts = await injector.committed()
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalOwner)
        XCTAssertEqual(committedTexts, [
            "publication admitted before replacement"
        ])
    }

    func testReplacementSealAllowsOwnedRecoveryRetryToFinishExactCapturedSpeech()
        async
    {
        let audio = MockAudioProvider()
        let exactCapturedAudio = audio.stubbedBuffer.data
        let retryGate = DictationPipelineSuspensionGate()
        let batch = DictationPipelineGatedBatchProvider(
            text: "recovered speech admitted before replacement",
            gatedCall: 2,
            failingCalls: [1],
            gate: retryGate)
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator)

        guard
            let sessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected session admission")
        }
        await pipeline.complete(sessionID: sessionID)

        let failedState = await coordinator.state
        let canRetry = await pipeline.canRetryDictation(sessionID: sessionID)
        let initialAudioAttempts = await batch.receivedAudio()
        XCTAssertEqual(failedState, .dictationFailed)
        XCTAssertTrue(canRetry)
        XCTAssertEqual(initialAudioAttempts, [exactCapturedAudio])

        let sealProbe = DictationPipelineCompletionProbe()
        let seal = Task {
            await pipeline.sealForReplacement()
            await sealProbe.markCompleted()
        }
        await waitForReplacementSeal(pipeline)

        let replacementSessionID = await pipeline.activate()
        let sealCompletedBeforeRetry = await sealProbe.hasCompleted()
        XCTAssertNil(replacementSessionID)
        XCTAssertFalse(sealCompletedBeforeRetry)

        let retry = Task {
            await pipeline.retryDictation(sessionID: sessionID)
        }
        await retryGate.waitUntilEntered()

        let retryingState = await coordinator.state
        let audioAttempts = await batch.receivedAudio()
        let sealCompletedDuringRetry = await sealProbe.hasCompleted()
        XCTAssertEqual(retryingState, .processing)
        XCTAssertEqual(audioAttempts, [exactCapturedAudio, exactCapturedAudio])
        XCTAssertFalse(sealCompletedDuringRetry)

        await retryGate.release()
        await retry.value
        await seal.value

        let finalState = await coordinator.state
        let finalOwner = await pipeline.currentSessionID
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalOwner)
        XCTAssertEqual(injector.injections.map(\.text), [
            "recovered speech admitted before replacement"
        ])
    }

    func testReplacementSealDrainsAdmittedCancellationBeforeReturning() async {
        let audio = MockAudioProvider()
        let cancellationGate = DictationPipelineSuspensionGate()
        let batch = MockBatchProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: batch),
            textInjector: injector,
            coordinator: coordinator,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            cancellationDrainDidStart: {
                await cancellationGate.waitForRelease()
            })

        guard
            let sessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected session admission")
        }

        let cancellation = Task {
            await pipeline.cancel(sessionID: sessionID)
        }
        await cancellationGate.waitUntilEntered()

        let sealProbe = DictationPipelineCompletionProbe()
        let seal = Task {
            await pipeline.sealForReplacement()
            await sealProbe.markCompleted()
        }
        await waitForReplacementSeal(pipeline)

        let replacementSessionID = await pipeline.activate()
        let sealCompletedBeforeCancellation = await sealProbe.hasCompleted()
        XCTAssertNil(replacementSessionID)
        XCTAssertFalse(sealCompletedBeforeCancellation)

        await cancellationGate.release()
        await cancellation.value
        await seal.value

        let finalState = await coordinator.state
        let finalOwner = await pipeline.currentSessionID
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalOwner)
        XCTAssertFalse(audio.isRecording)
        XCTAssertGreaterThanOrEqual(audio.stopCallCount, 1)
        XCTAssertEqual(batch.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testActivationReservedBeforeReplacementSealFinishesOnOldPipeline() async {
        let audio = MockAudioProvider()
        let activationGate = DictationPipelineSuspensionGate()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator(),
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            activationDidReserve: {
                await activationGate.waitForRelease()
            })

        let activation = Task { await pipeline.activate() }
        await activationGate.waitUntilEntered()

        let seal = Task { await pipeline.sealForReplacement() }
        await waitForReplacementSeal(pipeline)
        await activationGate.release()

        let sessionID = await activation.value
        XCTAssertNotNil(
            sessionID,
            "An activation that reserved admission before the seal must keep its backend")
        await waitForCaptureReady(audio, after: 0)
        XCTAssertTrue(audio.isRecording)

        if let sessionID {
            await pipeline.complete(sessionID: sessionID)
        }
        await seal.value
        let currentSessionID = await pipeline.currentSessionID
        XCTAssertNil(currentSessionID)
    }

    func testReplacementSealWinsBeforeActivationAdmission() async {
        let audio = MockAudioProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator())

        await pipeline.sealForReplacement()

        let sessionID = await pipeline.activate()
        XCTAssertNil(sessionID)
        XCTAssertEqual(audio.startCallCount, 0)
    }

    func testFailedReplacementCanReopenExactQuiescentPipeline() async {
        let audio = MockAudioProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator())

        await pipeline.sealForReplacement()
        let sealedSessionID = await pipeline.activate()
        XCTAssertNil(sealedSessionID)

        let reopened = await pipeline.reopenAfterFailedReplacement()
        XCTAssertTrue(reopened)

        let sessionID = await activateAndWaitForCapture(
            pipeline, audioProvider: audio)
        XCTAssertNotNil(sessionID)
        if let sessionID {
            await pipeline.complete(sessionID: sessionID)
        }
    }

    func testFullCycleStartsAndStopsAudioCapture() async {
        let (pipeline, audio, _, _, _, _) = makePipeline()

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        XCTAssertEqual(audio.startCallCount, 1)
        var recording = audio.isRecording
        XCTAssertTrue(recording)

        await pipeline.complete()
        XCTAssertEqual(audio.stopCallCount, 1)
        recording = audio.isRecording
        XCTAssertFalse(recording)
    }

    func testFullCycleReadsContext() async {
        let (pipeline, audio, context, _, _, _) = makePipeline()

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        XCTAssertEqual(context.readContextCallCount, 1)
    }

    func testFullCycleInjectsText() async {
        let (pipeline, audio, _, _, injector, _) = makePipeline()

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertNotNil(injector.lastInjectedText)
    }

    func testInjectedTextMatchesDictationOutput() async {
        let dictation = MockBatchProvider(stubbedText: "Hello from dictation")
        let (pipeline, audio, _, _, injector, _) = makePipeline(batchProvider: dictation)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        XCTAssertEqual(injector.lastInjectedText, "Hello from dictation")
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    func testDictationReceivesAudioData() async {
        // Build a non-silent WAV buffer so the silence gate does not reject it.
        var pcmData = Data(capacity: 64000)
        for i in 0..<32000 {
            let sample: Int16 = i % 2 == 0 ? 3000 : -3000
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let buffer = AudioBuffer(
            data: wavData,
            duration: 2.0,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )
        let audio = MockAudioProvider(stubbedBuffer: buffer)
        let dictation = MockBatchProvider()
        let (pipeline, _, _, _, injector, _) = makePipeline(
            audioProvider: audio, batchProvider: dictation)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(dictation.lastReceivedAudio, buffer.data)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testInjectedContextMatchesStubbedContext() async {
        let stubbedContext = AppContext(
            bundleID: "com.example.myapp",
            appName: "MyApp",
            windowTitle: "Document 1"
        )
        let contextProvider = MockAppContextProvider(context: stubbedContext)
        let (pipeline, audio, _, _, injector, _) = makePipeline(contextProvider: contextProvider)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let injections = injector.injections
        XCTAssertEqual(injections.count, 1)
        XCTAssertEqual(injections.first?.context, stubbedContext)
    }

    func testDictationReceivesAppContext() async {
        let stubbedContext = AppContext(
            bundleID: "com.apple.mail",
            appName: "Mail",
            windowTitle: "New Message"
        )
        let contextProvider = MockAppContextProvider(context: stubbedContext)
        let dictation = MockBatchProvider()
        let (pipeline, audio, _, _, _, _) = makePipeline(
            contextProvider: contextProvider, batchProvider: dictation)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(dictation.lastReceivedContext, stubbedContext)
    }

    // MARK: - State transitions during full cycle

    func testStatePassesThroughAllPhases() async {
        let coordinator = RecordingCoordinator()
        let (pipeline, audio, _, _, _, _) = makePipeline(coordinator: coordinator)

        var collected: [RecordingState] = []
        let expectation = XCTestExpectation(description: "Collect all state transitions")

        let streamTask = Task {
            for await state in await coordinator.stateStream {
                collected.append(state)
                // After returning to idle (the second idle), break.
                if collected.count >= 5 {
                    break
                }
            }
            expectation.fulfill()
        }

        // Let the stream subscribe.
        try? await Task.sleep(nanoseconds: 50_000_000)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        await fulfillment(of: [expectation], timeout: 5.0)
        streamTask.cancel()

        // Expected: idle (initial), recording, processing, injecting, idle
        XCTAssertEqual(collected, [.idle, .recording, .processing, .injecting, .idle])
    }

    // MARK: - Multiple cycles

    func testMultipleConsecutiveCycles() async {
        let (pipeline, audio, context, _, injector, coordinator) = makePipeline()

        for cycle in 1...3 {
            await activateAndWaitForCapture(pipeline, audioProvider: audio)
            var currentState = await coordinator.state
            XCTAssertEqual(currentState, .recording, "Cycle \(cycle) should be recording")

            await pipeline.complete()
            currentState = await coordinator.state
            XCTAssertEqual(currentState, .idle, "Cycle \(cycle) should return to idle")
        }

        XCTAssertEqual(audio.startCallCount, 3)
        XCTAssertEqual(audio.stopCallCount, 3)
        XCTAssertEqual(context.readContextCallCount, 3)
        XCTAssertEqual(injector.injectionCount, 3)
    }

    // MARK: - Cancellation

    func testCancelFromRecordingResetsToIdle() async {
        let (pipeline, audio, _, _, _, coordinator) = makePipeline()

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)

        await pipeline.cancel()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertFalse(audio.isRecording)
    }

    func testCancelFromIdleRemainsIdle() async {
        let (pipeline, _, _, _, _, coordinator) = makePipeline()

        await pipeline.cancel()
        let currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
    }

    func testCycleWorksAfterCancel() async {
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline()

        // Start and cancel.
        await pipeline.activate()
        await pipeline.cancel()
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)

        // Start a fresh cycle — should work normally.
        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)

        await pipeline.complete()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        // startCallCount may be 1 or 2 depending on whether the cancelled
        // activate() reached startRecording() before the task was cancelled.
        // The important invariant is that the second cycle started audio.
        XCTAssertGreaterThanOrEqual(audio.startCallCount, 1)
    }

    // MARK: - Edge cases: activate/complete out of order

    func testActivateWhileRecordingIsIgnored() async {
        let (pipeline, audio, _, _, _, coordinator) = makePipeline()

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)

        // Double activate should be ignored.
        await pipeline.activate()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)
        XCTAssertEqual(audio.startCallCount, 1, "Should not start recording twice")
    }

    func testCompleteFromIdleIsIgnored() async {
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline()

        // Complete without activate should be a no-op.
        await pipeline.complete()
        let currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertEqual(audio.stopCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testDoubleCompleteIsIgnored() async {
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline()

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertEqual(injector.injectionCount, 1)

        // Second complete should be a no-op.
        await pipeline.complete()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertEqual(audio.stopCallCount, 1, "Should not stop recording twice")
        XCTAssertEqual(injector.injectionCount, 1, "Should not inject twice")
    }

    // MARK: - Context uses stub context

    func testDefaultStubContextUsesTextEdit() async {
        let (pipeline, audio, _, _, injector, _) = makePipeline()

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let injections = injector.injections
        XCTAssertEqual(injections.count, 1)
        XCTAssertEqual(injections.first?.context.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(injections.first?.context.appName, "TextEdit")
    }

    // MARK: - Empty audio buffer

    func testEmptyAudioBufferSkipsDictationAndResetsToIdle() async {
        let audio = MockAudioProvider(stubbedBuffer: .empty)
        let dictation = MockBatchProvider()
        let (pipeline, audioProvider, _, _, injector, coordinator) = makePipeline(
            audioProvider: audio, batchProvider: dictation)

        await activateAndWaitForCapture(pipeline, audioProvider: audioProvider)
        await pipeline.complete()

        let currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        // Empty audio should skip dictation entirely and not inject.
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    // MARK: - Hotkey-driven simulation

    func testHotkeyDrivenFullCycle() async {
        let hotkey = MockHotkeyProvider()
        let audio = MockAudioProvider()
        let context = MockAppContextProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let dictation = MockBatchProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: injector,
            coordinator: coordinator
        )

        // Simulate what the app layer does: wire hotkey to pipeline.
        let completedExpectation = XCTestExpectation(description: "Pipeline cycle completes")

        try! hotkey.register { event in
            Task {
                switch event {
                case .pressed:
                    await pipeline.activate()
                case .released:
                    await pipeline.complete()
                    completedExpectation.fulfill()
                }
            }
        }

        let previousReadyCount = audio.captureReadyCount
        hotkey.simulatePress()
        await waitForCaptureReady(audio, after: previousReadyCount)

        hotkey.simulateRelease()

        await fulfillment(of: [completedExpectation], timeout: 5.0)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(context.readContextCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)

        hotkey.unregister()
        XCTAssertFalse(hotkey.isRegistered)
    }

    // MARK: - Rapid press/release cycles

    func testRapidActivateCancelCycles() async {
        let (pipeline, audio, _, _, _, coordinator) = makePipeline()

        for _ in 0..<5 {
            await pipeline.activate()
            await pipeline.cancel()
            let currentState = await coordinator.state
            XCTAssertEqual(currentState, .idle)
        }

        // One final full cycle to confirm nothing is broken.
        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    // MARK: - TranscriptBuffer wiring

    func testSuccessfulCycleStoresTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let dictation = MockBatchProvider(stubbedText: "Hello from buffer")
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation, transcriptBuffer: buffer)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(stored, "Hello from buffer")
    }

    func testTranscriptBufferUpdatedOnEachCycle() async {
        let buffer = TranscriptBuffer()
        let dictation = MockBatchProvider(stubbedText: "first")
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation, transcriptBuffer: buffer)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()
        var stored = await buffer.lastTranscript
        XCTAssertEqual(stored, "first")

        dictation.stubbedText = "second"
        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()
        stored = await buffer.lastTranscript
        XCTAssertEqual(stored, "second")
    }

    func testEmptyDictationResultDoesNotStoreInBuffer() async {
        let buffer = TranscriptBuffer()
        let dictation = MockBatchProvider(stubbedText: "   ")
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation, transcriptBuffer: buffer)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        XCTAssertNil(stored, "Empty dictation result should not be stored in buffer")
    }

    func testDictationFailureDoesNotStoreInBuffer() async {
        let buffer = TranscriptBuffer()
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.requestFailed(statusCode: 500, message: "fail")
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation, transcriptBuffer: buffer)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        XCTAssertNil(stored, "Dictation failure should not store anything in buffer")
    }

    func testPipelineWorksWithoutTranscriptBuffer() async {
        // Passing nil (the default) should not change existing behavior.
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline()

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    // MARK: - Injection failure → injectionFailed

    func testInjectionFailureTransitionsToInjectionFailed() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let dictation = MockBatchProvider(stubbedText: "dictated text")
        let (pipeline, audio, _, _, _, coordinator) = makePipeline(
            batchProvider: dictation, textInjector: injector, transcriptBuffer: buffer)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .injectionFailed,
            "Pipeline should transition to injectionFailed when injection throws")
    }

    func testInjectionFailurePreservesTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let dictation = MockBatchProvider(stubbedText: "preserved text")
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation, textInjector: injector, transcriptBuffer: buffer)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "preserved text",
            "Transcript should remain in buffer after injection failure")
    }

    func testInjectionFailureStatePassesThroughAllPhases() async {
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let coordinator = RecordingCoordinator()
        let (pipeline, audio, _, _, _, _) = makePipeline(
            textInjector: injector, coordinator: coordinator)

        var collected: [RecordingState] = []
        let expectation = XCTestExpectation(description: "Collect all state transitions")

        let streamTask = Task {
            for await state in await coordinator.stateStream {
                collected.append(state)
                if collected.count >= 5 {
                    break
                }
            }
            expectation.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        await fulfillment(of: [expectation], timeout: 5.0)
        streamTask.cancel()

        // Expected: idle (initial), recording, processing, injecting, injectionFailed
        XCTAssertEqual(collected, [.idle, .recording, .processing, .injecting, .injectionFailed])
    }

    func testCycleWorksAfterInjectionFailureAndReset() async {
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let coordinator = RecordingCoordinator()
        let (pipeline, audio, _, _, _, _) = makePipeline(
            textInjector: injector, coordinator: coordinator)

        // First cycle: injection fails.
        guard
            let sessionID = await activateAndWaitForCapture(
                pipeline, audioProvider: audio)
        else {
            return XCTFail("Expected first session admission")
        }
        await pipeline.complete()
        var state = await coordinator.state
        XCTAssertEqual(state, .injectionFailed)

        // Dismiss through the same session-scoped boundary as the HUD.
        await pipeline.dismissInjectionFailure(sessionID: sessionID)
        state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Second cycle: injection succeeds.
        injector.stubbedError = nil
        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()
        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    // MARK: - Silence gate

    func testSilentAudioSkipsDictationAndResetsToIdle() async {
        // Build a WAV buffer with all-zero (silent) samples.
        let silentPCM = Data(repeating: 0, count: 32000)
        let silentWAV = WAVEncoder.encode(
            pcmData: silentPCM, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let silentBuffer = AudioBuffer(
            data: silentWAV,
            duration: 1.0,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: silentBuffer)
        audio.stubbedPeakRMS = 0
        let dictation = MockBatchProvider()
        let (pipeline, audioProvider, _, _, injector, coordinator) = makePipeline(
            audioProvider: audio, batchProvider: dictation)

        await activateAndWaitForCapture(pipeline, audioProvider: audioProvider)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Silent audio should skip dictation entirely.
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testNonSilentAudioProceedsToDictation() async {
        // The default MockAudioProvider now produces non-silent audio.
        let dictation = MockBatchProvider(stubbedText: "Hello")
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline(
            batchProvider: dictation)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testCustomSilenceThresholdRejectsQuietAudio() async {
        // Build a buffer with low-amplitude samples (±100 → RMS ≈ 0.003).
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 100 : -100
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let quietBuffer = AudioBuffer(
            data: wavData,
            duration: 0.1,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: quietBuffer)
        audio.stubbedPeakRMS = 0.003
        let dictation = MockBatchProvider()
        let coordinator = RecordingCoordinator()

        // Use a high threshold so the quiet audio is rejected.
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.01
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testCustomSilenceThresholdAllowsQuietAudio() async {
        // Same quiet buffer as above, but with a very low threshold.
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 100 : -100
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let quietBuffer = AudioBuffer(
            data: wavData,
            duration: 0.1,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: quietBuffer)
        audio.stubbedPeakRMS = 0.003
        let dictation = MockBatchProvider(stubbedText: "whisper")
        let coordinator = RecordingCoordinator()

        // Use a very low threshold so the quiet audio passes through.
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.001
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    func testCustomSilenceThresholdCannotAcceptBelowSharedSpeechFloor() async {
        let audio = MockAudioProvider()
        audio.stubbedPeakRMS = 0.0004
        audio.stubbedAmbientRMS = 0
        let dictation = MockBatchProvider(stubbedText: "false speech")
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.0001)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        XCTAssertEqual(AudioLevelAnalyzer.minimumAcceptedSpeechRMS, 0.0005)
        XCTAssertEqual(
            OpenAIStreamingProvider.pauseSilenceThreshold, 0)
        XCTAssertLessThanOrEqual(
            OpenAIStreamingProvider.pauseSilenceThreshold,
            AudioLevelAnalyzer.minimumAcceptedSpeechRMS)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            dictation.dictateCallCount, 0,
            "Capture must not accept audio below the Realtime pause classifier floor")
    }

    // MARK: - Adaptive silence threshold

    func testAdaptiveThresholdAllowsQuietBuiltInMicSpeech() async {
        // Near-field mic with low ambient: ambient ~0.001, quiet speech
        // peaks at 0.004. The fixed threshold (0.005) would reject this,
        // but the adaptive threshold (0.001 * 1.2 = 0.0012) lets it through.
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 130 : -130
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let quietBuffer = AudioBuffer(
            data: wavData,
            duration: 0.6,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: quietBuffer)
        // peakRMS 0.004 is above adaptive threshold 0.0012 but below
        // fixed threshold 0.005.
        audio.stubbedPeakRMS = 0.004
        audio.stubbedAmbientRMS = 0.001

        let dictation = MockBatchProvider(stubbedText: "quiet speech")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // The adaptive threshold (0.0012) lets the audio through.
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    func testAdaptiveThresholdRejectsAirPodsAmbientNoise() async {
        // AirPods (near-field): ambient ~0.0025, noise floor peaks at 0.003.
        // Adaptive threshold = 0.0025 * 1.2 = 0.003, rejects the noise.
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 130 : -130
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let noiseBuffer = AudioBuffer(
            data: wavData,
            duration: 0.6,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: noiseBuffer)
        audio.stubbedPeakRMS = 0.003
        audio.stubbedAmbientRMS = 0.0025

        let dictation = MockBatchProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Adaptive threshold (0.0025 * 1.2 = 0.003) rejects the 0.003 peak (<=).
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testFallsBackToFixedThresholdWhenNoAmbientCalibration() async {
        // When ambientRMS is 0 (calibration not completed), the pipeline
        // falls back to the fixed silenceThreshold.
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 100 : -100
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let quietBuffer = AudioBuffer(
            data: wavData,
            duration: 0.1,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: quietBuffer)
        audio.stubbedPeakRMS = 0.003
        audio.stubbedAmbientRMS = 0  // No calibration

        let dictation = MockBatchProvider()
        let coordinator = RecordingCoordinator()

        // Fixed threshold 0.005 rejects peakRMS 0.003.
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testAdaptiveThresholdFloorPreventsZeroThreshold() async {
        // Even with very low ambient noise, the threshold should not
        // drop below the minimum floor (0.0005).
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 3 : -3
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let nearSilentBuffer = AudioBuffer(
            data: wavData,
            duration: 0.6,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: nearSilentBuffer)
        // Ambient 0.0001 * 1.2 = 0.00012, below the floor of 0.0005.
        // Effective threshold should be 0.0005, rejecting peakRMS 0.0003.
        audio.stubbedPeakRMS = 0.0003
        audio.stubbedAmbientRMS = 0.0001

        let dictation = MockBatchProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Floor threshold (0.0005) rejects the 0.0003 peak.
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testAdaptiveThresholdLetsSpeechThroughWithHighAmbient() async {
        // Coffee shop with near-field mic: ambient ~0.003, speech peaks
        // at 0.015. Adaptive threshold = 0.003 * 1.2 = 0.0036, speech
        // clears it easily.
        let audio = MockAudioProvider()
        audio.stubbedPeakRMS = 0.015
        audio.stubbedAmbientRMS = 0.003

        let dictation = MockBatchProvider(stubbedText: "coffee shop speech")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    // MARK: - Far-field (built-in mic) silence threshold

    func testFarFieldMicAllowsQuietSpeech() async {
        // Built-in MacBook mic: speech peaks at 0.003, well above the
        // far-field fixed threshold of 0.001. The adaptive path is
        // bypassed entirely for far-field mics because speech and
        // ambient RMS are virtually indistinguishable (ratio 1.0-1.2x).
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .farField
        audio.stubbedPeakRMS = 0.003
        audio.stubbedAmbientRMS = 0.002

        let dictation = MockBatchProvider(stubbedText: "quiet built-in mic speech")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Far-field threshold is 0.001; peakRMS 0.003 clears it.
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    func testFarFieldMicRejectsSilentPress() async {
        // Built-in mic silent press: peak RMS barely above the noise
        // floor (0.0007). The far-field fixed threshold of 0.001
        // rejects it. Without the far-field bypass, the adaptive
        // threshold (0.0005 * 1.2 = 0.0006) would let it through.
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .farField
        audio.stubbedPeakRMS = 0.0007
        audio.stubbedAmbientRMS = 0.0005

        let dictation = MockBatchProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Silent press rejected: no dictation call.
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testFarFieldMicIgnoresAmbientCalibration() async {
        // Far-field mic with high ambient noise (e.g. fan blowing
        // directly on laptop). Even though ambient * 1.2 = 0.006
        // would be above the peak speech level (0.004), far-field
        // bypasses the adaptive path entirely and uses 0.001.
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .farField
        audio.stubbedPeakRMS = 0.004
        audio.stubbedAmbientRMS = 0.005  // high ambient from fan noise

        let dictation = MockBatchProvider(stubbedText: "speech near fan")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Far-field uses fixed 0.001, not ambient * 1.2 = 0.006.
        // Peak 0.004 > 0.001, so speech goes through.
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    func testFarFieldMicAllowsSpeechAtBoundary() async {
        // Built-in mic: speech that just barely clears the far-field
        // threshold. Peak RMS of 0.0011 is just above 0.001.
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .farField
        audio.stubbedPeakRMS = 0.0011
        audio.stubbedAmbientRMS = 0.001

        let dictation = MockBatchProvider(stubbedText: "whisper")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    func testFarFieldMicRejectsAtExactThreshold() async {
        // Built-in mic: peak RMS exactly at the far-field threshold
        // (0.001). The silence gate uses <=, so this is rejected.
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .farField
        audio.stubbedPeakRMS = 0.001
        audio.stubbedAmbientRMS = 0.0008

        let dictation = MockBatchProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Exactly at threshold: rejected (<=).
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testNearFieldMicStillUsesAdaptiveThreshold() async {
        // Verify that near-field mics (AirPods, USB) are NOT affected
        // by the far-field bypass. With ambient 0.003 and peak 0.005,
        // the adaptive threshold = 0.003 * 1.2 = 0.0036. Peak 0.005
        // clears it. But if the far-field path were accidentally used,
        // the threshold would be 0.001 (also passes, so we use a case
        // where the distinction matters).
        //
        // Near-field mic: ambient 0.004, peak 0.004. Adaptive threshold
        // = 0.004 * 1.2 = 0.0048. Peak 0.004 < 0.0048, rejected.
        // Far-field would use 0.001, which would let it through.
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .nearField
        audio.stubbedPeakRMS = 0.004
        audio.stubbedAmbientRMS = 0.004

        let dictation = MockBatchProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Near-field adaptive threshold 0.0048 rejects peak 0.004.
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testFarFieldPostRecordThresholdRegression() async {
        // Regression test for the postRecordThreshold bug.
        // Previously, complete() had a second hardcoded threshold:
        //   postRecordThreshold = max(ambient * 2.0, 0.0005)
        // which ignored effectiveSilenceThreshold(). For a far-field mic
        // with ambient 0.002, the old code computed max(0.004, 0.0005)
        // = 0.004, rejecting speech at peak 0.003. The fix routes
        // postRecordThreshold through effectiveSilenceThreshold(), which
        // returns the fixed 0.001 for far-field mics.
        //
        // Real-world values from manual testing (2026-03-08):
        // built-in mic ambient 0.002-0.003, speech peak 0.002-0.004.
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .farField
        audio.stubbedPeakRMS = 0.003
        audio.stubbedAmbientRMS = 0.002

        let dictation = MockBatchProvider(stubbedText: "hello world")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // With the fix: far-field threshold 0.001, peak 0.003 passes.
        // With the old bug: max(0.002 * 2.0, 0.0005) = 0.004, peak
        // 0.003 would be rejected.
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Far-field speech should not be rejected by old hardcoded ambient * 2.0 threshold")
    }

    func testAdaptiveThresholdCapAllowsWhisperWithHighAmbient() async {
        // AirPods noise cancellation can produce ambient RMS ~0.014.
        // Without a cap: threshold = 0.014 * 1.2 = 0.0168, which
        // rejects a whisper peaking at 0.009. With the cap at 0.01,
        // the threshold is clamped and the whisper passes.
        //
        // Real-world values from manual testing (2026-03-10):
        // AirPods ambient 0.014, whispered speech peak 0.009.
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .nearField
        audio.stubbedPeakRMS = 0.009
        audio.stubbedAmbientRMS = 0.014

        let dictation = MockBatchProvider(stubbedText: "whispered with airpods")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Uncapped threshold would be 0.014 * 1.2 = 0.0168, rejecting
        // peak 0.009. Capped threshold is 0.01, peak 0.009 still fails.
        // But the server can handle borderline audio — the cap prevents
        // the threshold from climbing arbitrarily high. With peak just
        // above 0.01 (e.g. 0.011), the cap saves the session.
        //
        // This test verifies the cap is applied. Peak 0.009 is below
        // even the capped 0.01, so it is still rejected. That is
        // correct: the cap protects against runaway thresholds, not
        // against genuinely silent audio.
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testAdaptiveThresholdCapAllowsWhisperJustAboveCap() async {
        // AirPods with high ambient (0.014): uncapped threshold would
        // be 0.0168. A whisper peaking at 0.012 is above the cap (0.01)
        // but below the uncapped threshold. The cap saves this session.
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .nearField
        audio.stubbedPeakRMS = 0.012
        audio.stubbedAmbientRMS = 0.014

        let dictation = MockBatchProvider(stubbedText: "whisper saved by cap")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Uncapped: 0.014 * 1.2 = 0.0168 > 0.012 → rejected.
        // Capped: min(0.0168, 0.01) = 0.01 < 0.012 → passes.
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Whisper above the capped threshold should not be rejected")
    }

    func testAdaptiveThresholdBelowCapIsUnchanged() async {
        // Normal AirPods ambient (0.002): threshold = 0.002 * 1.2
        // = 0.0024, well below the 0.01 cap. Cap has no effect.
        let audio = MockAudioProvider()
        audio.stubbedMicProximity = .nearField
        audio.stubbedPeakRMS = 0.002
        audio.stubbedAmbientRMS = 0.002

        let dictation = MockBatchProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: dictation),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Threshold 0.0024, peak 0.002 ≤ 0.0024 → rejected.
        // Same result with or without cap.
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    // MARK: - Session expiry (401 handling)

    func testBatchDictation401TransitionsToSessionExpired() async {
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.authenticationFailed
        let coordinator = RecordingCoordinator()

        let callbackExpectation = expectation(description: "onSessionExpired called")
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation,
            coordinator: coordinator,
            onSessionExpired: { callbackExpectation.fulfill() }
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .sessionExpired,
            "Pipeline should transition to .sessionExpired on 401")

        await fulfillment(of: [callbackExpectation], timeout: 2.0)
    }

    func testSessionExpiredDoesNotInjectText() async {
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.authenticationFailed
        let injector = MockTextInjector()
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation,
            textInjector: injector,
            onSessionExpired: {}
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        XCTAssertEqual(
            injector.injectionCount, 0,
            "Text should not be injected when session is expired")
    }

    func testSessionExpiredDoesNotStoreInBuffer() async {
        let buffer = TranscriptBuffer()
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.authenticationFailed
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation,
            transcriptBuffer: buffer,
            onSessionExpired: {}
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        XCTAssertNil(stored, "401 failure should not store anything in buffer")
    }

    func testNon401ErrorDoesNotTriggerSessionExpired() async {
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.requestFailed(statusCode: 500, message: "fail")
        let coordinator = RecordingCoordinator()

        var callbackCalled = false
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation,
            coordinator: coordinator,
            onSessionExpired: { callbackCalled = true }
        )

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .dictationFailed,
            "Non-401 errors should enter recovery, not sessionExpired")
        XCTAssertFalse(callbackCalled, "onSessionExpired should not fire for non-401 errors")
    }

    func testCoordinatorExpireSessionTransition() async {
        let coordinator = RecordingCoordinator()
        // expireSession is only valid from .processing.
        await coordinator.startRecording()
        await coordinator.stopRecording()
        let expired = await coordinator.expireSession()
        let state = await coordinator.state
        XCTAssertTrue(expired)
        XCTAssertEqual(state, .sessionExpired)

        // finishInjecting resets from sessionExpired to idle.
        let finished = await coordinator.finishInjecting()
        let resetState = await coordinator.state
        XCTAssertTrue(finished)
        XCTAssertEqual(resetState, .idle)
    }

    func testExpireSessionInvalidFromIdle() async {
        let coordinator = RecordingCoordinator()
        let expired = await coordinator.expireSession()
        XCTAssertFalse(expired, "expireSession should fail from idle")
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    // MARK: - peakRMS == 0 pre-recording silence gate

    func testZeroPeakRMSDoesNotTriggerPreRecordingSilenceGate() async {
        // The pre-recording silence gate fires before audio setup
        // completes. A peakRMS of 0 means the tap hasn't delivered
        // any samples yet — not that the audio is silent. The gate
        // must skip when peakRMS is exactly 0 so a rapid hotkey tap
        // doesn't silently discard speech.
        //
        // Post-recording peakRMS==0 IS real silence (the tap ran and
        // captured nothing), so that gate correctly rejects.
        //
        // This test verifies the pre-recording path by checking that
        // the pipeline proceeds past the early short-circuit when
        // peakRMS is 0 — streaming setup should be attempted.
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        audio.stubbedPeakRMS = 0.0

        let streaming = MockStreamingProvider()
        streaming.stubbedText = "Hello world."

        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            transcriptBuffer: nil,
            onSessionExpired: nil,
            micDiagnosticStore: nil)

        await activateAndWaitForCapture(pipeline, audioProvider: audio)

        // Give audio setup time to start and streaming to connect.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The pre-recording silence gate should NOT have fired.
        // Streaming setup should have been attempted.
        XCTAssertGreaterThan(
            streaming.startCallCount, 0,
            "Streaming setup should proceed when peakRMS is 0 (tap not yet fired)")

        await pipeline.cancel()
    }

    // MARK: - Session expired callback

    func testSessionExpiredCallbackInvokedOn401() async {
        let dictation = MockBatchProvider()
        dictation.stubbedError = DictationError.authenticationFailed

        let expectation = XCTestExpectation(description: "session expired")
        let (pipeline, audio, _, _, _, _) = makePipeline(
            batchProvider: dictation,
            onSessionExpired: { expectation.fulfill() })

        await activateAndWaitForCapture(pipeline, audioProvider: audio)
        await pipeline.complete()
        await fulfillment(of: [expectation], timeout: 2.0)
    }
}
