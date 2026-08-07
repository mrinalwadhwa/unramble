import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

/// Thread-safe counter for the stop-read-session seam.
final class ReadSessionStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int { lock.withLock { _count } }

    func increment() {
        lock.withLock { _count += 1 }
    }
}

@Suite("Conversation call coordinator")
struct ConversationCallCoordinatorTests {

    private struct Harness {
        let coordinator: ConversationCallCoordinator
        let resolver: StubAgentSessionResolver
        let contextProvider: MockAppContextProvider
        let pipeline: MockPipelineProvider
        let hub: TurnSignalHub
        let observer: MockInjectionObserver
        let commandGate: MockCallCommandGate
        let submitter: MockTurnSubmitter
        let watcher: MockResponseWatcher
        let cues: MockCallCuePlayer
        let synthesizer: MockSpeechSynthesizer

        /// Publish a signal for the most recently activated capture
        /// session.
        func publish(_ signal: TurnSignal) {
            guard let sessionID = pipeline.activatedSessionIDs.last else {
                return
            }
            hub.publish(signal, for: sessionID)
        }

        /// Publish a strong-speech signal and return only once the
        /// waiting loop has consumed it. Signals and watch events reach
        /// the loop through separate forwarders, so plain `publish`
        /// followed by a `watcher.emit` races: under load the reply can
        /// be processed before the speech is seen, and the coordinator
        /// speaks instead of holding. Awaiting the consumption removes
        /// the race without changing product behavior. Only
        /// strong/emphatic speech is observed by the loop's hook, so
        /// this is for those signals.
        func publishAwaitingObservation(_ signal: TurnSignal) async {
            guard let sessionID = pipeline.activatedSessionIDs.last else {
                return
            }
            let gate = SignalGate(expected: signal)
            await coordinator.setWaitingSignalObserver { gate.observe($0) }
            hub.publish(signal, for: sessionID)
            await withCheckedContinuation { gate.arm($0) }
            await coordinator.setWaitingSignalObserver(nil)
        }
    }

    /// One-shot bridge that resumes a continuation the first time the
    /// coordinator's waiting loop consumes the expected signal.
    private final class SignalGate: @unchecked Sendable {
        private let lock = NSLock()
        private let expected: TurnSignal
        private var fired = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(expected: TurnSignal) { self.expected = expected }

        func observe(_ signal: TurnSignal) {
            guard signal == expected else { return }
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                if fired { return nil }
                fired = true
                let c = continuation
                continuation = nil
                return c
            }
            waiting?.resume()
        }

        func arm(_ continuation: CheckedContinuation<Void, Never>) {
            let alreadyFired: Bool = lock.withLock {
                if fired { return true }
                self.continuation = continuation
                return false
            }
            if alreadyFired { continuation.resume() }
        }
    }

    private func agentSession() -> ResolvedAgentSession {
        ResolvedAgentSession(
            agentName: "claude",
            workingDirectory: "/tmp/project",
            ttyDevice: 5)
    }

    private func context(pid: Int32?) -> AppContext {
        AppContext(
            bundleID: "com.googlecode.iterm2",
            appName: "iTerm2",
            windowTitle: "claude",
            processIdentifier: pid)
    }

    private func makeHarness(
        session: ResolvedAgentSession?,
        injectedText: String? = "Fix the failing resampler test.",
        dictationActive: Bool = false,
        idleTimeout: TimeInterval = 180,
        narrationOnsetGuardSeconds: TimeInterval = 0,
        readSessionStops: ReadSessionStopCounter = ReadSessionStopCounter()
    ) -> Harness {
        let resolver = StubAgentSessionResolver(session: session)
        let contextProvider = MockAppContextProvider()
        let pipeline = MockPipelineProvider()
        let hub = TurnSignalHub()
        let observer = MockInjectionObserver(text: injectedText)
        let commandGate = MockCallCommandGate()
        let submitter = MockTurnSubmitter()
        let watcher = MockResponseWatcher()
        let cues = MockCallCuePlayer()
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = ConversationCallCoordinator(
            contextProvider: contextProvider,
            sessionResolver: resolver,
            pipeline: pipeline,
            signalHub: hub,
            injectionObserver: observer,
            commandGate: commandGate,
            submitter: submitter,
            watcher: watcher,
            cuePlayer: cues,
            synthesizer: synthesizer,
            isDictationActive: { dictationActive },
            stopReadSession: { readSessionStops.increment() },
            idleTimeout: idleTimeout,
            narrationOnsetGuardSeconds: narrationOnsetGuardSeconds)
        return Harness(
            coordinator: coordinator,
            resolver: resolver,
            contextProvider: contextProvider,
            pipeline: pipeline,
            hub: hub,
            observer: observer,
            commandGate: commandGate,
            submitter: submitter,
            watcher: watcher,
            cues: cues,
            synthesizer: synthesizer)
    }

    /// Wait until the coordinator publishes the target state, or five
    /// seconds pass — a bounded wait turns a wedged flow into a
    /// failing expectation instead of a hung suite.
    private func waitForState(
        _ coordinator: ConversationCallCoordinator,
        _ target: ConversationCallState
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let stream = await coordinator.stateStream
                for await state in stream where state == target { return }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Poll until the condition holds; return the final evaluation.
    @discardableResult
    private func eventually(
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    /// A short settle for asserting that something did not happen.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - Call lifecycle

    @Test("The shortcut starts a call when an agent session is reachable")
    func startsCallWhenAgentSessionReachable() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        #expect(harness.pipeline.activatedSessionIDs.count == 1)
        #expect(harness.pipeline.state == .recording)
    }

    @Test("No call starts without a reachable agent session")
    func doesNotStartCallWithoutAgentSession() async {
        let harness = makeHarness(session: nil)

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        #expect(harness.pipeline.activatedSessionIDs.isEmpty)
    }

    @Test("A press with no agent session shows guidance and starts no call")
    func showsGuidanceWithoutAgentSession() async {
        let harness = makeHarness(session: nil)

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .noAgent)

        await harness.coordinator.dismissGuidance()
        let dismissed = await harness.coordinator.stateStream.first { _ in
            true
        }
        #expect(dismissed == .idle)
    }

    @Test("Starting a call stops an active read session first")
    func startingCallStopsActiveReadSession() async {
        let stops = ReadSessionStopCounter()
        let harness = makeHarness(
            session: agentSession(),
            readSessionStops: stops)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        #expect(stops.count == 1)
    }

    @Test("The call reports itself active from start to hangup")
    func isCallActiveReflectsCall() async {
        let harness = makeHarness(session: agentSession())

        #expect(await harness.coordinator.isCallActive == false)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        #expect(await harness.coordinator.isCallActive == true)

        await harness.coordinator.hangUp()
        #expect(await harness.coordinator.isCallActive == false)
    }

    @Test("The call publishes its phases on the state stream")
    func publishesListeningWaitingSpeakingPhases() async {
        let harness = makeHarness(session: agentSession())

        let stream = await harness.coordinator.stateStream
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .idle)

        await harness.coordinator.toggle()
        #expect(await iterator.next() == .listening)

        harness.publish(.strongSpeech)
        harness.publish(.pause)
        #expect(await iterator.next() == .waiting)

        await eventually { harness.watcher.armed.count == 1 }
        harness.watcher.emit(.response(markdown: "It works."))
        #expect(await iterator.next() == .speaking)
        #expect(await iterator.next() == .listening)

        await harness.coordinator.hangUp()
        #expect(await iterator.next() == .idle)
    }

    @Test("Escape hangs up: capture stops and the state returns to idle")
    func escapeHangsUp() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        await harness.coordinator.hangUp()
        await harness.coordinator.waitForCall()

        #expect(
            harness.pipeline.cancelledSessionIDs
                == harness.pipeline.activatedSessionIDs)
        #expect(harness.pipeline.state == .idle)
        #expect(harness.watcher.cancelCount == 1)
        #expect(harness.synthesizer.stopCount == 1)
    }

    @Test("A second shortcut press hangs up, identically to Escape")
    func secondShortcutPressHangsUp() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        #expect(
            harness.pipeline.cancelledSessionIDs
                == harness.pipeline.activatedSessionIDs)
        #expect(harness.pipeline.state == .idle)
    }

    @Test("Hangup restores the prior input mode: dictation can start again")
    func hangupRestoresPriorInputMode() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        await harness.coordinator.hangUp()
        await harness.coordinator.waitForCall()

        // The pipeline is idle again, so an ordinary dictation press is
        // admitted exactly as before the call.
        let dictationSession = await harness.pipeline.activate()
        #expect(dictationSession != nil)
    }

    @Test("The call shortcut is ignored while dictation is recording")
    func ignoresCallShortcutWhileDictationRecording() async {
        let harness = makeHarness(
            session: agentSession(),
            dictationActive: true)

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        #expect(harness.pipeline.activatedSessionIDs.isEmpty)
    }

    @Test("A hangup that races activation cancels the accepted capture")
    func hangupRacingActivationCancelsCapture() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await harness.coordinator.hangUp()
        await harness.coordinator.waitForCall()

        // Whether or not activation won the race, no capture survives.
        #expect(
            harness.pipeline.cancelledSessionIDs
                == harness.pipeline.activatedSessionIDs)
        #expect(harness.pipeline.state == .idle)
    }

    @Test("A failed pipeline activation ends the call audibly in idle")
    func failedActivationEndsCall() async {
        let harness = makeHarness(session: agentSession())
        harness.pipeline.nextActivateFails = true

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .idle)
        #expect(harness.cues.doneCueCount == 1)
    }

    @Test("A silent call ends itself audibly after the idle window")
    func idleCallEndsAudibly() async {
        let harness = makeHarness(
            session: agentSession(),
            idleTimeout: 0.05)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        await harness.coordinator.waitForCall()

        #expect(await harness.coordinator.isCallActive == false)
        #expect(harness.cues.doneCueCount == 1)
        #expect(
            harness.pipeline.cancelledSessionIDs
                == harness.pipeline.activatedSessionIDs)
    }

    @Test("Speech in the turn stands the idle deadline down")
    func speechStandsIdleDeadlineDown() async {
        let harness = makeHarness(
            session: agentSession(),
            idleTimeout: 0.2)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)

        // Let the deadline pass with speech already heard, then
        // endpoint normally: the turn still sends.
        try? await Task.sleep(nanoseconds: 300_000_000)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        // Hang up before the waiting phase's own short deadline can
        // fire; this test is about the listening turn's window.
        await harness.coordinator.hangUp()

        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.submitter.submitCount == 1)
        #expect(harness.cues.doneCueCount == 0)
    }

    @Test("A silent waiting phase ends the call after the idle window")
    func idleWaitingEndsCallAudibly() async {
        let harness = makeHarness(
            session: agentSession(),
            idleTimeout: 0.25)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        // The watch stays silent and so does the user; the waiting
        // phase's open microphone must not persist forever.
        await eventually {
            await harness.coordinator.isCallActive == false
        }
        #expect(await harness.coordinator.isCallActive == false)
        #expect(harness.cues.doneCueCount == 1)
    }

    @Test("Strong speech during waiting stands the idle deadline down")
    func speechInWaitingStandsIdleDeadlineDown() async {
        let harness = makeHarness(
            session: agentSession(),
            idleTimeout: 0.3)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        harness.publish(.strongSpeech)
        try? await Task.sleep(nanoseconds: 450_000_000)

        #expect(await harness.coordinator.isCallActive == true)
        #expect(harness.cues.doneCueCount == 0)
        await harness.coordinator.hangUp()
    }

    @Test("A visibly working agent holds the idle window open")
    func agentActivityHoldsIdleWindowOpen() async {
        let harness = makeHarness(
            session: agentSession(),
            idleTimeout: 0.3)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        // The user is silent, but tool records keep landing; the
        // deadline re-arms instead of hanging up under the agent.
        for _ in 0..<4 {
            harness.watcher.emit(.stillWorking)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        #expect(await harness.coordinator.isCallActive == true)
        #expect(harness.cues.doneCueCount == 0)

        // Silence on both sides still closes the call.
        await eventually {
            await harness.coordinator.isCallActive == false
        }
        #expect(await harness.coordinator.isCallActive == false)
        #expect(harness.cues.doneCueCount == 1)
    }

    // MARK: - Turn loop

    @Test("The call captures speech with no key held")
    func capturesSpeechWithoutKeyHeld() async {
        let harness = makeHarness(session: agentSession())

        // The coordinator has no hotkey seam at all; toggling alone
        // opens capture and holds it open.
        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        #expect(harness.pipeline.state == .recording)
    }

    @Test("Call captures start and stop without dictation cues")
    func callCapturesAreSilent() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        // Every call session is cueless, including the waiting
        // phase's open microphone racing this assertion.
        #expect(
            harness.pipeline.activationCaptureCues.allSatisfy { $0 == false })
        #expect(harness.pipeline.activationCaptureCues.isEmpty == false)
    }

    @Test("Transcribed speech followed by the pause sends the turn")
    func sendPauseInjectsTranscribedTurn() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        let captureSession = harness.pipeline.activatedSessionIDs.first

        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.pipeline.completedSessionIDs.first == captureSession)
    }

    @Test("An agent target is submitted after injection")
    func submitsOnlyForAgentTargets() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.submitter.submitCount == 1)
    }

    @Test("The pinned delivery address is exposed for the call's life")
    func exposesPinnedDeliveryDuringCall() async {
        let harness = makeHarness(session: agentSession())
        harness.contextProvider.stubbedContext = context(pid: 111)

        #expect(await harness.coordinator.pinnedDelivery == nil)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        #expect(
            await harness.coordinator.pinnedDelivery
                == PinnedDelivery(
                    bundleID: "com.googlecode.iterm2",
                    processIdentifier: 111,
                    ttyDevice: 5))

        await harness.coordinator.hangUp()
        #expect(await harness.coordinator.pinnedDelivery == nil)
    }

    @Test("A sent agent turn arms the response watch on the injected text")
    func armsWatchReplacingEarlierWatch() async {
        let harness = makeHarness(
            session: agentSession(),
            injectedText: "Run the tests again.")

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.watcher.armed.count == 1)
        #expect(harness.watcher.armed.first?.anchor == "Run the tests again.")
        #expect(harness.watcher.armed.first?.session == agentSession())
    }

    @Test("The send cue plays at the moment the turn goes")
    func playsSendCueOnSend() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.cues.sendCueCount == 1)
    }

    @Test("A noise turn that injects nothing plays no send cue")
    func noiseTurnPlaysNoCue() async {
        let harness = makeHarness(
            session: agentSession(),
            injectedText: nil)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)

        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.cues.sendCueCount == 0)
        #expect(harness.submitter.submitCount == 0)
    }

    @Test("A pause with no transcribed speech sends nothing")
    func emptyTurnSendsNothing() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.pause)
        await settle()

        #expect(harness.pipeline.completedSessionIDs.isEmpty)
        #expect(harness.pipeline.activatedSessionIDs.count == 1)
        #expect(harness.cues.sendCueCount == 0)
        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .listening)
    }

    @Test("The dictation key sends the turn immediately")
    func dictationKeySendsImmediately() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        await harness.coordinator.sendNow()
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.submitter.submitCount == 1)
    }

    @Test("A pause arriving before its transcript sends on the late text")
    func pauseBeforeTranscriptSendsOnLateTranscript() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.pause)
        harness.publish(.strongSpeech)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.pipeline.completedSessionIDs.count == 1)
    }

    @Test("Resumed speech clears a pending pause instead of sending")
    func audibleSpeechClearsPendingPause() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.pause)
        harness.publish(.audibleSpeech)
        harness.publish(.strongSpeech)
        await settle()

        #expect(harness.pipeline.completedSessionIDs.isEmpty)

        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        #expect(harness.pipeline.completedSessionIDs.count == 1)
    }

    // MARK: - Waiting and completion

    @Test("A completed response is spoken after the reply cue, then relisten")
    func speaksReplyAndRelistens() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "All tests pass."))
        await waitForState(harness.coordinator, .listening)

        #expect(harness.cues.replyCueCount == 1)
        #expect(harness.synthesizer.spokenTexts.count == 1)
        #expect(
            harness.synthesizer.spokenTexts.first?.contains("All tests pass")
                == true)
        // The waiting mic, the narration's watch-only session, and
        // the fresh opening after it.
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
        }
        #expect(harness.pipeline.cancelledSessionIDs.count == 2)
    }

    @Test("A tool-only turn relistens quietly")
    func toolOnlyTurnRelistensQuietly() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.toolOnly)
        await waitForState(harness.coordinator, .listening)

        #expect(harness.cues.doneCueCount == 0)
        #expect(harness.synthesizer.spokenTexts.isEmpty)
        // The waiting mic is discarded and a full listening turn
        // opens in its place.
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 3
        }
        #expect(harness.pipeline.cancelledSessionIDs.count == 1)
    }

    @Test("An interim narration returns the call to an open waiting mic")
    func narratesInterimAndReopensMic() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(
            .interimMessage(markdown: "Checking the resampler."))
        await eventually { harness.synthesizer.spokenTexts.count == 1 }

        // The waiting mic was discarded for the narration; a fresh
        // one opens under the same armed watch.
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
        }
        #expect(harness.watcher.armed.count == 1)
        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .waiting)
    }

    @Test("An empty pause keeps the waiting mic open")
    func emptyPauseKeepsWaitingMicOpen() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        // Silence while the agent works is not a "never mind": the
        // pause re-arms and the same session keeps listening.
        harness.publish(.pause)
        await settle()

        #expect(harness.pipeline.activatedSessionIDs.count == 2)
        #expect(harness.pipeline.cancelledSessionIDs.isEmpty)
        #expect(harness.pipeline.completedSessionIDs.count == 1)
        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .waiting)
    }

    @Test("Speech into the waiting mic sends and re-arms the watch")
    func speechInWaitingSendsAndRearms() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await eventually { harness.watcher.armed.count == 2 }

        #expect(harness.pipeline.completedSessionIDs.count == 2)
        #expect(harness.submitter.submitCount == 2)
    }

    @Test("A stale interim buffered under a narration is dropped")
    func dropsInterimsBufferedUnderNarration() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.interimMessage(markdown: "First update."))
        await harness.synthesizer.waitUntilSpeaking()

        // Progress that arrives while its predecessor still plays is
        // stale by the time the voice ends; the transcript is the
        // source of truth.
        harness.watcher.emit(.interimMessage(markdown: "Stale progress."))
        harness.synthesizer.stopSpeaking()
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
        }
        await settle()
        #expect(harness.synthesizer.spokenTexts.count == 1)

        // A fresh final response still speaks.
        harness.watcher.emit(.response(markdown: "Fresh answer."))
        await eventually { harness.synthesizer.spokenTexts.count == 2 }
        harness.synthesizer.stopSpeaking()
        await waitForState(harness.coordinator, .listening)
    }

    @Test("A completion of already-played text resolves the watch quietly")
    func playedCompletionResolvesWatch() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.interimMessage(markdown: "The answer."))
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
        }

        // The turn completes with the text the interim narration
        // already offered; the watch resolves into a full relisten
        // without replaying it.
        harness.watcher.emit(.completed(markdown: "The answer."))
        await waitForState(harness.coordinator, .listening)

        await eventually {
            harness.pipeline.activatedSessionIDs.count == 5
        }
        #expect(harness.synthesizer.spokenTexts.count == 1)
        #expect(harness.cues.doneCueCount == 0)
        #expect(harness.watcher.armed.count == 1)
    }

    @Test("A queued completion speaks after the user's turn sends")
    func queuedCompletionSpeaksAfterSend() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        // The user is mid-utterance when the response lands: progress
        // drops, but the answer itself queues — it must not vanish
        // behind the send.
        await harness.publishAwaitingObservation(.strongSpeech)
        harness.watcher.emit(.interimMessage(markdown: "Progress."))
        harness.watcher.emit(.completed(markdown: "The answer."))
        await settle()
        #expect(harness.synthesizer.spokenTexts.isEmpty)

        harness.publish(.pause)
        await eventually { harness.watcher.armed.count == 2 }
        await eventually { harness.synthesizer.spokenTexts.count == 1 }
        #expect(
            harness.synthesizer.spokenTexts.first?.contains("The answer")
                == true)
        #expect(harness.submitter.submitCount == 2)
    }

    @Test("The watched agent is exposed for presentation until hangup")
    func exposesResolvedAgentForWatchedTurn() async {
        let harness = makeHarness(session: agentSession())

        #expect(await harness.coordinator.lastResolvedAgent == nil)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(await harness.coordinator.lastResolvedAgent == agentSession())

        await harness.coordinator.hangUp()
        #expect(await harness.coordinator.lastResolvedAgent == nil)
    }

    @Test("The call waits as long as the watch stays silent")
    func waitingPersistsWithoutEvent() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await settle()

        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .waiting)
        // Waiting is not deaf: exactly one open microphone runs
        // through it, alongside the completed listening turn.
        #expect(harness.pipeline.activatedSessionIDs.count == 2)
        #expect(harness.pipeline.state == .recording)
    }

    // MARK: - Speaking and barge-in

    @Test("The microphone is open while call speech plays")
    func keepsMicOpenWhileSpeaking() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        // The reply is playing over an already-open capture session.
        #expect(harness.pipeline.state == .recording)

        harness.synthesizer.stopSpeaking()
        await waitForState(harness.coordinator, .listening)
        // The waiting mic and the narration's capture are both
        // discarded; a fresh clean turn opens in their place.
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
                && harness.pipeline.state == .recording
        }
        #expect(harness.pipeline.cancelledSessionIDs.count == 2)
    }

    @Test("Strong speech during narration stops the voice and sends")
    func voiceBargeInDuringNarration() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        // The user talks over the voice; the voice yields, their
        // barging sentence is absorbed through its pause, and a
        // fresh clean turn opens after it.
        harness.publish(.emphaticSpeech)
        await eventually { harness.synthesizer.stopCount == 1 }
        harness.publish(.pause)
        await waitForState(harness.coordinator, .listening)
        #expect(harness.synthesizer.stopCount == 1)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
        }

        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually { harness.submitter.submitCount == 2 }
        #expect(harness.watcher.armed.count == 2)
    }

    @Test("A voice barge is a stop signal; its sentence never sends")
    func bargeSentenceIsAbsorbed() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        // The barge stops the voice, but the mic does not recycle:
        // the discarded session keeps absorbing the barging sentence.
        harness.publish(.emphaticSpeech)
        await eventually { harness.synthesizer.stopCount == 1 }
        harness.publish(.audibleSpeech)
        harness.publish(.transcribedSpeech)
        await settle()
        #expect(harness.pipeline.activatedSessionIDs.count == 3)

        // The sentence's own pause closes the absorb; the whole
        // utterance dies with the discarded session — nothing new
        // was completed or submitted — and the barge cue hands the
        // floor back audibly.
        harness.publish(.pause)
        await waitForState(harness.coordinator, .listening)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
        }
        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.submitter.submitCount == 1)

        // The next utterance, into the fresh session, is the message.
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await eventually { harness.submitter.submitCount == 2 }
        #expect(harness.watcher.armed.count == 2)
        // With no retrievable audio, nothing was carried forward.
        #expect(harness.pipeline.seededTranscripts.isEmpty)
    }

    @Test("A voice barge carries its sentence into the fresh session")
    func bargeSentenceIsCarried() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true
        let bargeText = "Let's start planning the release."
        harness.pipeline.transcribeRecentCaptureStub = bargeText

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        // The barge is absorbed through its pause, and the absorbed
        // sentence's audio is sliced out of the doomed watch session
        // with pre-roll ahead of the barge's onset.
        harness.publish(.emphaticSpeech)
        await eventually { harness.synthesizer.stopCount == 1 }
        harness.publish(.pause)

        // The interruption is the message: the carried sentence
        // sends by itself the moment its fresh session opens.
        await eventually { harness.submitter.submitCount == 2 }
        let request = harness.pipeline.transcribeRecentCaptureRequests.last
        #expect((request?.seconds ?? 0) >= 1.5)
        let seeded = harness.pipeline.seededTranscripts.last
        #expect(seeded?.text == bargeText)
        #expect(harness.watcher.armed.count == 2)
    }

    @Test("A carried sentence of the narration's own words is rejected")
    func bargeEchoOfNarrationIsRejected() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true
        // Live failure: loud playback echoed into the mic, tripped
        // the emphatic gate, and the carry transcribed the voice's
        // own tail — which then sent as the user's turn.
        harness.pipeline.transcribeRecentCaptureStub = "incognito mode."

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(
            markdown: "Open a window in incognito mode to browse."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        harness.publish(.emphaticSpeech)
        await eventually { harness.synthesizer.stopCount == 1 }
        harness.publish(.pause)

        // The echo is rejected: the fresh session opens listening
        // with no seed and nothing sends by itself.
        await waitForState(harness.coordinator, .listening)
        #expect(harness.submitter.submitCount == 1)
        #expect(harness.pipeline.seededTranscripts.isEmpty)
    }

    @Test("Echo fragments of the spoken script are recognized")
    func narrationEchoDetection() {
        let spoken = """
            To browse privately, open a window in incognito mode. \
            In incognito, history is not saved.
            """
        #expect(ConversationCallCoordinator.isNarrationEcho(
            "mode. In incognito...", spoken: spoken))
        #expect(ConversationCallCoordinator.isNarrationEcho(
            "incognito", spoken: spoken))
        #expect(!ConversationCallCoordinator.isNarrationEcho(
            "no stop use the regular window instead", spoken: spoken))
        #expect(!ConversationCallCoordinator.isNarrationEcho(
            "wait what about incognito mode on my phone", spoken: spoken))
    }

    @Test("A barge over an interim reply carries into the waiting mic")
    func bargeOverInterimCarriesIntoWaiting() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true
        let bargeText = "Actually, use the staging config."
        harness.pipeline.transcribeRecentCaptureStub = bargeText

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.interimMessage(markdown: "Still working."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        harness.publish(.emphaticSpeech)
        await eventually { harness.synthesizer.stopCount == 1 }
        harness.publish(.pause)

        // The interruption is the message: the reopened session
        // seeds the carried words and sends immediately.
        await eventually { harness.submitter.submitCount == 2 }
        let seeded = harness.pipeline.seededTranscripts.last
        #expect(seeded?.text == bargeText)
        #expect(harness.watcher.armed.count == 2)
    }

    @Test("Audible residual during narration does not stop the voice")
    func audibleResidualKeepsNarration() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        // Reverberant residual is audible — and can even cross the
        // open-session strong bar — but it never reaches emphatic;
        // it must not take the floor from the narration.
        harness.publish(.audibleSpeech)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await settle()
        #expect(harness.synthesizer.stopCount == 0)
        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .speaking)

        harness.synthesizer.stopSpeaking()
        await waitForState(harness.coordinator, .listening)
    }

    @Test("Nothing heard under a narration can send")
    func narrationCaptureIsDiscarded() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        // The recognizer transcribes residual under the voice; the
        // narration's whole capture session dies with the voice, so
        // none of it can ever send.
        harness.publish(.audibleSpeech)
        harness.publish(.pause)
        harness.synthesizer.stopSpeaking()
        await waitForState(harness.coordinator, .listening)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
        }

        // The fresh opening hears nothing: an empty pause re-arms
        // listening and nothing ever sends.
        harness.publish(.pause)
        await settle()
        #expect(harness.pipeline.activatedSessionIDs.count == 4)
        #expect(harness.submitter.submitCount == 1)
        #expect(harness.watcher.armed.count == 1)
    }

    @Test("Onset-guard leak neither barges nor becomes a sendable turn")
    func onsetGuardSwallowsLeak() async {
        let harness = makeHarness(
            session: agentSession(),
            narrationOnsetGuardSeconds: 60)
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        // The canceller leaks the voice's own onset as speech-shaped
        // audio; inside the guard even emphatic signals must not
        // stop the voice.
        harness.publish(.emphaticSpeech)
        harness.publish(.emphaticSpeech)
        await settle()
        #expect(harness.synthesizer.stopCount == 0)
        let speaking = await harness.coordinator.stateStream.first { _ in
            true
        }
        #expect(speaking == .speaking)

        // The voice finishes; the leaked signals left no trace, so
        // a fresh opening replaces the discarded narration capture.
        harness.synthesizer.stopSpeaking()
        await waitForState(harness.coordinator, .listening)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
        }
        #expect(harness.submitter.submitCount == 1)
        #expect(harness.watcher.armed.count == 1)
    }

    @Test("The dictation key during narration only stops the voice")
    func bargeInStopsSpeechBeforeCapture() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await waitForState(harness.coordinator, .speaking)
        await harness.synthesizer.waitUntilSpeaking()

        await harness.coordinator.dictationKeyPressed()

        // Stopping the voice is the whole barge; the discarded
        // narration capture is replaced by a fresh open turn. The
        // button is explicit, so no handoff cue plays.
        #expect(harness.synthesizer.stopCount == 1)
        await waitForState(harness.coordinator, .listening)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 4
        }
        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .listening)
    }

    @Test("A reply arriving mid-speech queues instead of talking over")
    func replyQueuesBehindActiveSpeech() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        // The user is mid-utterance in the waiting mic; the reply
        // must not take the floor from them.
        await harness.publishAwaitingObservation(.strongSpeech)
        harness.watcher.emit(.response(markdown: "Held back."))
        await settle()
        #expect(harness.synthesizer.spokenTexts.isEmpty)

        // Their endpoint sends, and the held answer plays after it.
        harness.publish(.pause)
        await eventually { harness.watcher.armed.count == 2 }
        await eventually { harness.synthesizer.spokenTexts.count == 1 }
        #expect(
            harness.synthesizer.spokenTexts.first?.contains("Held back")
                == true)
    }

    @Test("Progress arriving mid-speech drops instead of queueing")
    func progressDropsBehindActiveSpeech() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        await harness.publishAwaitingObservation(.strongSpeech)
        harness.watcher.emit(.interimMessage(markdown: "Stale progress."))
        harness.publish(.pause)
        await eventually { harness.watcher.armed.count == 2 }
        await settle()
        #expect(harness.synthesizer.spokenTexts.isEmpty)

        // Fresh events on the re-armed watch still speak.
        harness.watcher.emit(.response(markdown: "Fresh answer."))
        await eventually { harness.synthesizer.spokenTexts.count == 1 }
        #expect(
            harness.synthesizer.spokenTexts.first?.contains("Fresh answer")
                == true)
    }

    @Test("A queued reply still plays when the turn injects nothing")
    func queuedReplyPlaysWhenTurnInjectsNothing() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        // The reply lands mid-utterance, but the utterance turns out
        // to inject nothing. The agent was never redirected, so the
        // answer still plays and the watch resolves.
        harness.observer.stubbedText = nil
        harness.publish(.strongSpeech)
        harness.watcher.emit(.response(markdown: "The final answer."))
        harness.publish(.pause)

        await eventually { harness.synthesizer.spokenTexts.count == 1 }
        #expect(
            harness.synthesizer.spokenTexts.first?.contains(
                "The final answer") == true)
        #expect(harness.watcher.armed.count == 1)
        #expect(harness.submitter.submitCount == 1)
        await waitForState(harness.coordinator, .listening)
    }

    @Test("The dictation key during waiting sends the open turn")
    func dictationKeyDuringWaitingSends() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        // The mic is already open; the key is a send, not a barge.
        await harness.coordinator.dictationKeyPressed()
        await eventually { harness.watcher.armed.count == 2 }

        #expect(harness.pipeline.completedSessionIDs.count == 2)
        #expect(harness.submitter.submitCount == 2)
    }

    // MARK: - Spoken meta-commands

    @Test("A spoken hang-up ends the call like Escape")
    func spokenHangUpEndsCall() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        // The gate held the utterance back from injection: nothing
        // was recorded, and the command is pending after completion.
        harness.commandGate.pendingCommand = .hangUp
        harness.observer.stubbedText = nil
        harness.publish(.strongSpeech)
        harness.publish(.pause)
        await harness.coordinator.waitForCall()

        #expect(await harness.coordinator.isCallActive == false)
        #expect(harness.commandGate.resetCount == 1)
        #expect(harness.submitter.submitCount == 0)
        #expect(harness.cues.sendCueCount == 0)
        #expect(harness.watcher.armed.isEmpty)
        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .idle)
    }

    @Test("A force-send with no speech injects nothing and relistens")
    func forceSendWithoutSpeechKeepsListening() async {
        let harness = makeHarness(
            session: agentSession(),
            injectedText: nil)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        await harness.coordinator.sendNow()

        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.submitter.submitCount == 0)
        #expect(harness.cues.sendCueCount == 0)
    }
}
