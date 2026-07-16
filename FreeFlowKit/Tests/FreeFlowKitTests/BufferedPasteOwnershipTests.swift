import XCTest

@testable import FreeFlowKit

final class BufferedPasteOwnershipTests: XCTestCase {

    func testHeldActivationWaitsForBufferedPastePublication() async {
        let buffer = TranscriptBuffer()
        await buffer.store("paste me")
        let injector = BufferedPasteGateInjector()
        let activationProbe = BufferedPasteActivationProbe()
        let (pipeline, audio) = makePipeline(
            buffer: buffer,
            injector: injector,
            activationDidReserve: {
                await activationProbe.markReserved()
            })

        let pasteTask = Task { await pipeline.pasteBufferedTranscript() }
        await injector.waitUntilInjectionStarts()

        let activationTask = Task { await pipeline.activate() }
        await activationProbe.waitUntilReserved()

        XCTAssertEqual(audio.startCallCount, 0)

        await injector.releaseInjection()
        await pasteTask.value
        let admittedSessionID = await activationTask.value
        XCTAssertNotNil(admittedSessionID)
        let captureReady = await waitUntil { audio.captureReadyCount == 1 }
        XCTAssertTrue(captureReady)
        if let admittedSessionID {
            await pipeline.cancel(sessionID: admittedSessionID)
        }
    }

    func testReleasedActivationDoesNotStartAfterBufferedPaste() async {
        let buffer = TranscriptBuffer()
        await buffer.store("paste me")
        let injector = BufferedPasteGateInjector()
        let activationProbe = BufferedPasteActivationProbe()
        let (pipeline, audio) = makePipeline(
            buffer: buffer,
            injector: injector,
            activationDidReserve: {
                await activationProbe.markReserved()
            })
        let driver = HotkeyPipelineDriver(pipeline: pipeline)

        let pasteTask = Task { await pipeline.pasteBufferedTranscript() }
        await injector.waitUntilInjectionStarts()
        driver.submit(.pressed)
        await activationProbe.waitUntilReserved()

        driver.submit(.released)
        await driver.waitForSubmittedCommands()
        XCTAssertEqual(audio.startCallCount, 0)

        await injector.releaseInjection()
        await pasteTask.value
        await driver.waitForSubmittedEvents()

        let owner = await pipeline.currentSessionID
        XCTAssertNil(owner)
        XCTAssertEqual(audio.startCallCount, 0)
        driver.invalidate()
    }

    func testRetirementDrainsBufferedPastePublication() async {
        let buffer = TranscriptBuffer()
        await buffer.store("paste me")
        let injector = BufferedPasteGateInjector()
        let (pipeline, _) = makePipeline(
            buffer: buffer,
            injector: injector)

        let pasteTask = Task { await pipeline.pasteBufferedTranscript() }
        await injector.waitUntilInjectionStarts()

        let retirementFinished = expectation(
            description: "retirement drains buffered publication")
        let retireTask = Task {
            await pipeline.retire()
            retirementFinished.fulfill()
        }
        let earlyResult = await XCTWaiter().fulfillment(
            of: [retirementFinished],
            timeout: 0.1)

        XCTAssertEqual(
            earlyResult,
            .timedOut,
            "Retirement must retain an in-flight target mutation")

        await injector.releaseInjection()
        await pasteTask.value
        await retireTask.value
        let injectionCount = await injector.injectionCount
        XCTAssertEqual(injectionCount, 1)
    }

    func testReplacementSealDrainsAdmittedPasteAndRejectsLaterIdlePaste() async {
        let buffer = TranscriptBuffer()
        await buffer.store("admitted before seal")
        let injector = BufferedPasteGateInjector()
        let (pipeline, _) = makePipeline(
            buffer: buffer,
            injector: injector)

        let admittedPaste = Task { await pipeline.pasteBufferedTranscript() }
        await injector.waitUntilInjectionStarts()

        let seal = Task { await pipeline.sealForReplacement() }
        let didSeal = await waitUntilAsync {
            await pipeline.isSealedForReplacement
        }
        XCTAssertTrue(didSeal)

        await buffer.store("retained after seal")
        await pipeline.pasteBufferedTranscript()

        await injector.releaseInjection()
        await admittedPaste.value
        await seal.value

        let injectionCount = await injector.injectionCount
        let retained = await buffer.lastTranscript
        XCTAssertEqual(injectionCount, 1)
        XCTAssertEqual(retained, "retained after seal")
    }

    func testBufferedPasteFailureRestoresTranscript() async {
        let buffer = TranscriptBuffer()
        await buffer.store("restore me")
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let (pipeline, _) = makePipeline(
            buffer: buffer,
            injector: injector)

        await pipeline.pasteBufferedTranscript()

        let restored = await buffer.lastTranscript
        let owner = await pipeline.currentSessionID
        XCTAssertEqual(restored, "restore me")
        XCTAssertNil(owner)
    }

    func testFailedBufferedPasteCannotOverwriteNewerTranscript() async {
        let buffer = TranscriptBuffer()
        await buffer.store("older transcript")
        let injector = BufferedPasteGateInjector(
            errorAfterRelease: AppTextInjector.InjectionError.noFocusedElement)
        let (pipeline, _) = makePipeline(
            buffer: buffer,
            injector: injector)

        let pasteTask = Task { await pipeline.pasteBufferedTranscript() }
        await injector.waitUntilInjectionStarts()
        await buffer.store("newer transcript")
        await injector.releaseInjection()
        await pasteTask.value

        let retained = await buffer.lastTranscript
        XCTAssertEqual(retained, "newer transcript")
    }

    func testRetirementBeforeBufferedInjectionRestoresTranscript() async {
        let buffer = TranscriptBuffer()
        await buffer.store("restore on retirement")
        let context = BufferedPasteGateContextProvider()
        let injector = MockTextInjector()
        let pipeline = DictationPipeline(
            audioProvider: MockAudioProvider(),
            contextProvider: context,
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: RecordingCoordinator(),
            transcriptBuffer: buffer,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            contextObservationTimeout: 10)

        let pasteTask = Task { await pipeline.pasteBufferedTranscript() }
        await context.waitUntilReadStarts()

        let retirementFinished = expectation(
            description: "retirement drains the reserved paste")
        let retireTask = Task {
            await pipeline.retire()
            retirementFinished.fulfill()
        }
        let earlyResult = await XCTWaiter().fulfillment(
            of: [retirementFinished],
            timeout: 0.1)
        XCTAssertEqual(earlyResult, .timedOut)

        await context.releaseRead()
        await pasteTask.value
        await retireTask.value

        let retained = await buffer.lastTranscript
        XCTAssertEqual(retained, "restore on retirement")
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testPasteRetriesInjectionFailedSessionExactlyOnce() async {
        let buffer = TranscriptBuffer()
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        let streaming = MockStreamingProvider(stubbedText: "retry transcript")
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let coordinator = RecordingCoordinator()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            transcriptBuffer: buffer)

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureReady = await waitUntil {
            audio.captureReadyCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(captureReady)
        await pipeline.complete(sessionID: sessionID)
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .injectionFailed)

        injector.stubbedError = nil
        async let firstPaste: Void = pipeline.pasteBufferedTranscript()
        async let duplicatePaste: Void = pipeline.pasteBufferedTranscript()
        _ = await (firstPaste, duplicatePaste)

        let finalState = await coordinator.state
        let finalOwner = await pipeline.currentSessionID
        let retained = await buffer.lastTranscript
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalOwner)
        XCTAssertNil(retained)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "retry transcript")
    }

    func testPasteWaitsForClaimedDismissalThenPublishesBuffer() async {
        let buffer = TranscriptBuffer()
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        let streaming = MockStreamingProvider(stubbedText: "publish after dismissal")
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let coordinator = RecordingCoordinator()
        let terminalGate = BufferedPasteTerminalGate()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: streaming,
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: coordinator,
            transcriptBuffer: buffer,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            terminalIdleDidClaim: { _ in
                await terminalGate.waitForRelease()
            })

        guard let sessionID = await pipeline.activate() else {
            return XCTFail("Expected session admission")
        }
        let captureReady = await waitUntil {
            audio.captureReadyCount == 1 && streaming.startCallCount == 1
        }
        XCTAssertTrue(captureReady)
        await pipeline.complete(sessionID: sessionID)
        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .injectionFailed)

        injector.stubbedError = nil
        let dismissalTask = Task {
            await pipeline.dismissInjectionFailure(sessionID: sessionID)
        }
        await terminalGate.waitUntilEntered()

        let pasteFinished = expectation(description: "paste waits for terminal commit")
        let pasteTask = Task {
            await pipeline.pasteBufferedTranscript()
            pasteFinished.fulfill()
        }
        let earlyResult = await XCTWaiter().fulfillment(
            of: [pasteFinished],
            timeout: 0.1)
        XCTAssertEqual(earlyResult, .timedOut)

        await terminalGate.release()
        await dismissalTask.value
        await pasteTask.value

        let finalState = await coordinator.state
        let finalOwner = await pipeline.currentSessionID
        let retained = await buffer.lastTranscript
        XCTAssertEqual(finalState, .idle)
        XCTAssertNil(finalOwner)
        XCTAssertNil(retained)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "publish after dismissal")
    }

    private func makePipeline(
        buffer: TranscriptBuffer,
        injector: any TextInjecting,
        activationDidReserve: @escaping @Sendable () async -> Void = {}
    ) -> (DictationPipeline, MockAudioProvider) {
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .cloud(
                realtime: MockStreamingProvider(),
                fallback: MockBatchProvider()),
            textInjector: injector,
            coordinator: RecordingCoordinator(),
            transcriptBuffer: buffer,
            cloudRecordingLimitSleep: { duration in
                try? await Task.sleep(for: duration)
            },
            activationDidReserve: activationDidReserve)
        return (pipeline, audio)
    }

    private func waitUntil(
        attempts: Int = 1_000,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func waitUntilAsync(
        attempts: Int = 1_000,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

}

private actor BufferedPasteGateInjector: TextInjecting {
    private let errorAfterRelease: (any Error)?
    private var injectionStarted = false
    private var injectionReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var injectionCount = 0

    init(errorAfterRelease: (any Error)? = nil) {
        self.errorAfterRelease = errorAfterRelease
    }

    func inject(text: String, into context: AppContext) async throws {
        injectionStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }

        if !injectionReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        if let errorAfterRelease {
            throw errorAfterRelease
        }
        injectionCount += 1
    }

    func waitUntilInjectionStarts() async {
        guard !injectionStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseInjection() {
        guard !injectionReleased else { return }
        injectionReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private actor BufferedPasteGateContextProvider: AppContextProviding {
    private var readStarted = false
    private var readReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func readContext() async -> AppContext {
        readStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }

        if !readReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return .empty
    }

    func waitUntilReadStarts() async {
        guard !readStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseRead() {
        guard !readReleased else { return }
        readReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private actor BufferedPasteActivationProbe {
    private var reserved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markReserved() {
        reserved = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    func waitUntilReserved() async {
        guard !reserved else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor BufferedPasteTerminalGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        entered = true
        let waitingForEntry = enteredWaiters
        enteredWaiters.removeAll()
        waitingForEntry.forEach { $0.resume() }

        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}
