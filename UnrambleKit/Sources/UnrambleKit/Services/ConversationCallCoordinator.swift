import Foundation

/// Owns the conversation call: an explicit voice session with a
/// coding agent.
///
/// One call exists at a time. The call shortcut toggles it — a press
/// while a call is active hangs up, identically to Escape. A call
/// starts only when the frontmost window hosts a coding-agent session
/// and dictation is not recording, so the two features never contend
/// for audio. `toggle` claims or releases the call without suspending,
/// so two rapid presses cannot start two calls; the dictation check
/// happens inside the claimed call task.
///
/// While the call listens, the streaming provider publishes
/// `TurnSignal`s for the capture session. A pause sends the turn only
/// when speech was transcribed — silence and background noise never
/// send — and the dictation key sends immediately. The conversation
/// is pinned to the session resolved at call start: every sent turn
/// is delivered to it — refocusing its application first when the
/// user has wandered — then submitted and watched.
///
/// The microphone is one continuous concern for the life of the call.
/// A send does not close it: the waiting phase hosts a live capture
/// session of its own, so speech after a send endpoints exactly as it
/// does while listening and supersedes the watch. Agent replies weave
/// around that speech instead of interrupting it — a reply arriving
/// mid-speech queues behind it, progress messages drop as stale, and
/// a final response that never actually played is always spoken. An
/// empty pause re-arms listening rather than closing the mic.
///
/// Narrations play over a watch-only, echo-cancelled microphone:
/// strong speech stops the voice mid-sentence, everything heard under
/// the voice is discarded — a recognizer reads reverberant residual
/// ears cannot — and a fresh clean session opens the moment the voice
/// stops. A turn whose whole utterance is a spoken meta-command —
/// "hang up" — executes against the call itself and is never sent.
public actor ConversationCallCoordinator {

    private enum TurnEnd {
        case send(sawTranscribedSpeech: Bool)

        /// Nobody spoke for the whole idle window; the call ends
        /// rather than holding an open microphone forever.
        case idleTimedOut
    }

    /// How one capture turn resolved.
    private enum TurnOutcome {
        case ended
        case listeningContinues
        case watchArmed(AsyncStream<ResponseWatchEvent>)
    }

    /// How the consumption of one armed watch resolved.
    private enum WatchOutcome {
        case relisten
        case ended

        /// A send superseded the watch; a final response that queued
        /// behind the user's speech rides along so the next watch
        /// phase can still speak it.
        case rearmed(
            AsyncStream<ResponseWatchEvent>, pendingNarration: String?)
    }

    /// How completing a sendable endpoint resolved.
    private enum SendResolution {
        case ended

        /// Nothing reached the agent — the injection was empty or no
        /// agent is pinned — so the microphone keeps listening.
        case keepListening

        case watchArmed(AsyncStream<ResponseWatchEvent>)
    }

    /// How a narration hosted over the watch resolved.
    private enum NarrationOutcome {
        /// The voice ran out, was stopped by a button, or was barged
        /// by the user's voice — whose whole sentence was absorbed
        /// through its pause, so the user is silent when this
        /// resolves. A voice barge carries the absorbed sentence's
        /// transcription here so it can open the next message instead
        /// of dying with the watch.
        case finished(bargedText: String?)

        /// The call ended mid-narration.
        case ended
    }

    private enum TurnEvent: Sendable {
        case signal(TurnSignal)
        case force
        case idleTimeout

        /// The turn's narration finished playing, by running out or
        /// by being stopped.
        case narrationEnded

        /// The narration onset guard expired; speech-shaped signals
        /// are the user from here on.
        case bargeArmed
    }

    /// One arrival in the watch phase's select: the agent's watch,
    /// the open waiting session, or the end of the watch stream.
    private enum WatchPhaseEvent {
        case watch(ResponseWatchEvent, arrivedAt: Date)
        case watchEnded
        case turn(TurnEvent, session: DictationSessionID)
    }

    /// The subscription backing one turn's endpoint wait. Created
    /// before the listening state becomes visible, so no signal
    /// published against the fresh capture session can be missed.
    private struct TurnWait {
        let events: AsyncStream<TurnEvent>
        let continuation: AsyncStream<TurnEvent>.Continuation
        let forwarder: Task<Void, Never>
        let idleTimer: Task<Void, Never>?
    }

    /// The open microphone hosted through one stretch of the waiting
    /// phase, with its signal forwarder and idle deadline.
    private struct WaitingSession {
        let id: DictationSessionID
        let forwarder: Task<Void, Never>
        let idleTimer: Task<Void, Never>
    }

    private let contextProvider: any AppContextProviding
    private let sessionResolver: any AgentSessionResolving
    private let pipeline: any PipelineProviding
    private let signalHub: TurnSignalHub
    private let injectionObserver: any InjectionObserving
    private let commandGate: any CallCommandGating
    private let submitter: any TurnSubmitting
    private let watcher: any ResponseWatching
    private let cuePlayer: any CallCuePlaying
    private let scriptBuilder: SpeechScriptBuilder
    private let synthesizer: any SpeechSynthesizing
    private let farEndHub: FarEndPlaybackHub?
    private let isDictationActive: @Sendable () async -> Bool
    private let stopReadSession: @Sendable () async -> Void

    /// How long an open session may go without voice-level speech
    /// before the call ends itself. An unattended open microphone is
    /// a privacy and cost hazard. Every phase listens, so every phase
    /// carries the window; agent activity recycles the waiting
    /// session and so keeps a working call alive.
    private let idleTimeout: TimeInterval

    private var callTask: Task<Void, Never>?

    /// The most recently ended call's task, retained so `waitForCall`
    /// can drain an abandoned call deterministically.
    private var stoppedCallTask: Task<Void, Never>?

    /// Pipeline and watch teardown issued by hangup, retained for the
    /// same deterministic drain.
    private var teardownTask: Task<Void, Never>?

    /// Incremented on every call start and hangup. A finishing call
    /// commits its teardown only when its generation is still current,
    /// so a stale task cannot clear a newer call's handle or state.
    private var callGeneration = 0

    /// The dictation session that captures the call's audio while the
    /// call is listening.
    private var captureSessionID: DictationSessionID?

    /// Resumes the in-flight turn wait when the user force-sends.
    private var forceSendTrigger: (@Sendable () -> Void)?

    /// How long after a narration starts before speech-shaped
    /// signals count as the user. The echo canceller converges on
    /// new playback over its first second or so, and until then the
    /// synthesized voice leaks into the microphone as convincing
    /// speech — enough to barge its own narration. During the guard
    /// the buttons still barge.
    private let narrationOnsetGuardSeconds: TimeInterval

    /// A barging sentence's transcription, recovered from the
    /// discarded watch session and waiting to open the next message.
    /// The audio slice behind it starts just before the barge's
    /// onset, where the user's voice dominates any narration
    /// residual, so it reads as their words on speakers as well as
    /// in-ear. Text, not audio: carried audio fed to a live session
    /// ages out of the recognizer's rolling window undecoded.
    private var pendingBargeText: String?

    #if DEBUG
        /// Test-only hook fired as the waiting loop dequeues a turn
        /// signal. Each signal's state effect is applied synchronously
        /// before the loop next suspends, so a test that resumes on this
        /// hook is guaranteed the effect has landed before its follow-up
        /// event is processed — making signal-vs-watch ordering
        /// deterministic under load. Nil and unused in production.
        var waitingSignalObserver: (@Sendable (TurnSignal) -> Void)?

        func setWaitingSignalObserver(
            _ observer: (@Sendable (TurnSignal) -> Void)?
        ) {
            waitingSignalObserver = observer
        }
    #endif

    /// Pre-roll carried ahead of the barge's emphatic signal, which
    /// fires a sustained run after the voice's true onset. Too little
    /// clips the sentence opening — the original absorb-only design
    /// existed because a clipped opening transcribes as garbage.
    private let bargeCarryPreRollSeconds: TimeInterval = 1.5

    /// Upper bound on carried barge audio.
    private let bargeCarryMaximumSeconds: TimeInterval = 30

    private var state: ConversationCallState = .idle
    private var continuations:
        [UUID: AsyncStream<ConversationCallState>.Continuation] = [:]

    /// The agent session this conversation is pinned to, resolved
    /// once at call start and cleared when the call ends. Every turn
    /// is delivered to it and the watch always observes it, no
    /// matter where focus wanders.
    public private(set) var lastResolvedAgent: ResolvedAgentSession?

    /// The application hosting the pinned session's pane. The
    /// injection chain reads this to focus the exact tab at the
    /// instant of delivery.
    private var pinnedApplication: Int32?
    private var pinnedBundleID: String?

    /// The pinned delivery address for the injection chain, or nil
    /// outside calls.
    public var pinnedDelivery: PinnedDelivery? {
        guard let pinnedBundleID else { return nil }
        return PinnedDelivery(
            bundleID: pinnedBundleID,
            processIdentifier: pinnedApplication,
            ttyDevice: lastResolvedAgent?.ttyDevice)
    }

    public init(
        contextProvider: any AppContextProviding,
        sessionResolver: any AgentSessionResolving,
        pipeline: any PipelineProviding,
        signalHub: TurnSignalHub,
        injectionObserver: any InjectionObserving,
        commandGate: any CallCommandGating,
        submitter: any TurnSubmitting,
        watcher: any ResponseWatching,
        cuePlayer: any CallCuePlaying,
        scriptBuilder: SpeechScriptBuilder = SpeechScriptBuilder(),
        synthesizer: any SpeechSynthesizing,
        farEndHub: FarEndPlaybackHub? = nil,
        isDictationActive: @escaping @Sendable () async -> Bool,
        stopReadSession: @escaping @Sendable () async -> Void = {},
        idleTimeout: TimeInterval = 180,
        narrationOnsetGuardSeconds: TimeInterval = 2.0
    ) {
        self.contextProvider = contextProvider
        self.sessionResolver = sessionResolver
        self.pipeline = pipeline
        self.signalHub = signalHub
        self.injectionObserver = injectionObserver
        self.commandGate = commandGate
        self.submitter = submitter
        self.watcher = watcher
        self.cuePlayer = cuePlayer
        self.scriptBuilder = scriptBuilder
        self.synthesizer = synthesizer
        self.farEndHub = farEndHub
        self.isDictationActive = isDictationActive
        self.stopReadSession = stopReadSession
        self.idleTimeout = idleTimeout
        self.narrationOnsetGuardSeconds = narrationOnsetGuardSeconds
    }

    /// Whether a call is active in any phase. The app ignores the
    /// hands-free toggle while this is true.
    public var isCallActive: Bool {
        callTask != nil
    }

    // MARK: - Observation

    /// Stream call state changes. The current state is emitted
    /// immediately upon subscription, followed by every subsequent
    /// change.
    public var stateStream: AsyncStream<ConversationCallState> {
        let currentState = state
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(currentState)
            self.continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func transition(to newState: ConversationCallState) {
        guard state != newState else { return }
        Log.debug(
            "[Call] \(state) → \(newState)"
                + " at \(CFAbsoluteTimeGetCurrent())")
        state = newState
        for (_, continuation) in continuations {
            continuation.yield(newState)
        }
    }

    private func transitionIfCurrent(
        generation: Int,
        to newState: ConversationCallState
    ) {
        guard generation == callGeneration else { return }
        transition(to: newState)
    }

    // MARK: - Call control

    /// Start a call, or hang up the one in progress.
    public func toggle() {
        if callTask != nil {
            hangUp()
            return
        }
        startCall()
    }

    /// End the call immediately: speech stops, capture stops, the
    /// armed watch is cancelled, and the state returns to idle. Safe
    /// to call at any time; Escape and a second shortcut press both
    /// land here.
    public func hangUp() {
        guard let task = callTask else { return }
        callTask = nil
        stoppedCallTask = task
        callGeneration += 1
        lastResolvedAgent = nil
        pinnedApplication = nil
        pinnedBundleID = nil
        pendingBargeText = nil
        task.cancel()
        synthesizer.stopSpeaking()
        let sessionID = captureSessionID
        captureSessionID = nil
        let pipeline = pipeline
        let watcher = watcher
        teardownTask = Task {
            if let sessionID {
                await pipeline.cancel(sessionID: sessionID)
            }
            await watcher.cancelWatch()
        }
        transition(to: .idle)
    }

    /// Send the turn being listened to immediately, without waiting
    /// out the send pause. The dictation key triggers this while the
    /// call listens.
    public func sendNow() {
        forceSendTrigger?()
    }

    /// The dictation key during a call: send immediately while the
    /// mic listens — which it does through waiting too — and stop
    /// the voice while a reply plays.
    public func dictationKeyPressed() {
        switch state {
        case .listening, .waiting:
            sendNow()
        case .speaking:
            bargeIn()
        case .idle, .noAgent:
            break
        }
    }

    /// Stop call speech. During a narration the microphone is already
    /// open with the synthesized voice cancelled out of it, so
    /// stopping the voice is the entire barge — the session that
    /// opens when the voice ends hears whatever the user says next.
    public func bargeIn() {
        guard callTask != nil else { return }
        synthesizer.stopSpeaking()
    }

    /// Wait for the in-flight or most recently ended call work to
    /// finish.
    func waitForCall() async {
        await callTask?.value
        await stoppedCallTask?.value
        await teardownTask?.value
    }

    private func startCall() {
        callGeneration += 1
        pendingBargeText = nil
        let generation = callGeneration
        callTask = Task { [weak self] in
            guard let self else { return }
            await self.runCall(generation: generation)
        }
    }

    private func runCall(generation: Int) async {
        // Ignored while dictation is recording so the call never takes
        // the microphone from the user's own capture (checked here,
        // inside the claimed call, so the claim itself never suspends).
        guard await !isDictationActive() else {
            finishCall(generation: generation)
            return
        }

        // The call takes over the speech channel from any read session.
        await stopReadSession()
        guard !Task.isCancelled else { return }

        let context = await contextProvider.readContext()
        guard !Task.isCancelled else { return }

        // Pin the conversation: the session focused at start is the
        // other end for the whole call.
        guard let pinned = await sessionResolver.resolveSession(for: context)
        else {
            finishCall(generation: generation, in: .noAgent)
            return
        }
        guard !Task.isCancelled else { return }
        lastResolvedAgent = pinned
        pinnedApplication = context.processIdentifier
        pinnedBundleID = context.bundleID

        await runTurnLoop(generation: generation)
    }

    /// Dismiss the no-agent guidance. Ignored while a call is active
    /// so a delayed dismissal can never disturb a newer call's state.
    public func dismissGuidance() {
        guard callTask == nil, state == .noAgent else { return }
        transition(to: .idle)
    }

    /// Listen, send on the endpoint, and keep listening after turns
    /// that stayed plain dictation. A submitted agent turn hands the
    /// call to the watch phase, which keeps the microphone open while
    /// it consumes the response. The loop leaves through hangup or a
    /// failed activation.
    private func runTurnLoop(generation: Int) async {
        while !Task.isCancelled, generation == callGeneration {
            let outcome = await performTurn(generation: generation)
            switch outcome {
            case .ended:
                return
            case .listeningContinues:
                continue
            case .watchArmed(var watchEvents):
                var pendingNarration: String?
                watching: while true {
                    let watchOutcome = await waitOutWatch(
                        watchEvents,
                        generation: generation,
                        carriedNarration: pendingNarration)
                    switch watchOutcome {
                    case .ended:
                        return
                    case .relisten:
                        break watching
                    case .rearmed(let newEvents, let carried):
                        watchEvents = newEvents
                        pendingNarration = carried
                    }
                }
            }
        }
    }

    /// One capture turn: listen, endpoint, and deliver.
    private func performTurn(generation: Int) async -> TurnOutcome {
        guard let sessionID = await pipeline.activate(playsCaptureCues: false)
        else {
            // The pipeline refused capture — e.g. a failed dictation
            // session holds admission for an explicit retry. End the
            // call audibly instead of vanishing mid-conversation.
            if generation == callGeneration, !Task.isCancelled {
                cuePlayer.playDoneCue()
            }
            finishCall(generation: generation)
            return .ended
        }

        // A barge that resolved into relistening carries its
        // sentence: it is already a complete message, so it sends
        // the moment this fresh session opens.
        if let seed = takePendingBargeText() {
            await pipeline.seedTranscript(seed, sessionID: sessionID)
            Log.debug("[Call] barge text seeded")
            guard
                adoptCapture(generation: generation, sessionID: sessionID)
            else {
                await pipeline.cancel(sessionID: sessionID)
                return .ended
            }
            switch await completeSend(
                generation: generation, sessionID: sessionID)
            {
            case .ended:
                return .ended
            case .keepListening:
                return .listeningContinues
            case .watchArmed(let events):
                return .watchArmed(events)
            }
        }

        // Subscribe to the session's signals before listening becomes
        // visible, so no early signal is dropped.
        let turnWait = beginTurnWait(
            sessionID: sessionID, idleTimeout: idleTimeout)

        // A hangup that raced activation must not leak the capture.
        guard
            adoptCapture(generation: generation, sessionID: sessionID)
        else {
            endTurnWait(turnWait)
            await pipeline.cancel(sessionID: sessionID)
            return .ended
        }

        guard
            let turnEnd = await awaitTurnEnd(turnWait),
            generation == callGeneration, !Task.isCancelled
        else { return .ended }
        Log.debug("[Call] turn end: \(turnEnd)")

        switch turnEnd {
        case .idleTimedOut:
            // Nobody spoke for the whole idle window; end the call
            // audibly instead of holding an open microphone forever.
            if generation == callGeneration, !Task.isCancelled {
                cuePlayer.playDoneCue()
            }
            hangUp()
            return .ended

        case .send:
            switch await completeSend(
                generation: generation, sessionID: sessionID)
            {
            case .ended:
                return .ended
            case .keepListening:
                return .listeningContinues
            case .watchArmed(let events):
                return .watchArmed(events)
            }
        }
    }

    /// Complete a sendable endpoint: transcribe, deliver to the
    /// pinned session, submit, and arm the response watch. Delivery
    /// targeting happens inside the injection chain — the pinned
    /// session is focused at the instant the text injects.
    private func completeSend(
        generation: Int,
        sessionID: DictationSessionID
    ) async -> SendResolution {
        await injectionObserver.reset()
        await commandGate.reset()
        await pipeline.complete(sessionID: sessionID)
        clearCapture(generation: generation, sessionID: sessionID)
        guard generation == callGeneration, !Task.isCancelled else {
            return .ended
        }

        // A turn whose whole utterance was a meta-command was held
        // back from injection; execute it instead.
        if let command = await commandGate.takePendingCommand() {
            return perform(command)
        }

        // An empty turn injected nothing; keep listening. Noise can
        // endpoint as a sendable turn whose transcript turns out
        // empty, so the send cue waits for delivered text — an honest
        // cue over an early one.
        guard let injected = await injectionObserver.lastInjectedText(),
            !injected.isEmpty
        else { return .keepListening }
        cuePlayer.playSendCue()

        guard let target = lastResolvedAgent else {
            return .keepListening
        }
        await submitter.submitTurn()
        let watchEvents = await watcher.arm(
            session: target, anchor: injected)
        transitionIfCurrent(generation: generation, to: .waiting)
        return .watchArmed(watchEvents)
    }

    /// Execute a spoken meta-command and return how the send resolved.
    private func perform(_ command: CallMetaCommand) -> SendResolution {
        Log.debug("[Call] meta-command: \(command)")
        switch command {
        case .hangUp:
            hangUp()
            return .ended
        }
    }

    /// Consume the armed watch while keeping the microphone open.
    ///
    /// Waiting is not a passive state: a capture session runs for the
    /// whole phase, selected against the watch's events. The user can
    /// speak at any moment — right after the send, between replies,
    /// over the tail of a narration — and their speech endpoints
    /// exactly as it does while listening, superseding the watch.
    /// Agent messages weave around that speech: a reply arriving
    /// mid-speech queues behind it (interim progress drops as stale),
    /// an empty pause re-arms listening rather than closing the mic,
    /// and a final response that never actually played always speaks —
    /// carried into the next watch when a send supersedes this one.
    private func waitOutWatch(
        _ events: AsyncStream<ResponseWatchEvent>,
        generation: Int,
        carriedNarration: String? = nil
    ) async -> WatchOutcome {
        let (merged, mergedContinuation) =
            AsyncStream<WatchPhaseEvent>.makeStream()
        let pump = Task {
            for await event in events {
                mergedContinuation.yield(.watch(event, arrivedAt: Date()))
            }
            guard !Task.isCancelled else { return }
            mergedContinuation.yield(.watchEnded)
        }
        defer { pump.cancel() }

        /// Texts whose playback started this watch, so a completion
        /// event never replays what was already offered.
        var playedThisWatch: Set<String> = []

        /// A final response waiting for the user's speech to finish.
        /// It must eventually play; only its own barge skips it.
        var pendingFinal: String?

        /// Interim messages older than the last narration or send are
        /// stale progress; the transcript stays the source of truth.
        var dropInterimsBefore: Date?

        /// Set when the watch delivered its resolution while the user
        /// was mid-speech; the phase then only finishes their turn.
        var watchResolved = false

        /// When the watch last showed signs of life. A silent user
        /// under a visibly working agent re-arms the idle deadline
        /// instead of hanging up mid-work.
        var lastWatchEventAt = Date()

        /// Play one narration; the waiting session is already
        /// discarded when this runs. A voice barge's carried sentence
        /// is stashed for whichever session opens next.
        func narrate(_ markdown: String) async -> NarrationOutcome {
            playedThisWatch.insert(markdown)
            cuePlayer.playReplyCue()
            let outcome = await narrateOverWatch(
                generation: generation, markdown: markdown)
            if case .finished(let bargedText) = outcome,
                let bargedText
            {
                pendingBargeText = bargedText
            }
            dropInterimsBefore = Date()
            return outcome
        }

        // A response queued behind the previous watch plays before
        // anything else: it is an answer the user never heard.
        if let carriedNarration {
            switch await narrate(carriedNarration) {
            case .ended:
                return .ended
            case .finished:
                break
            }
        }

        let initialSeed = takePendingBargeText()
        guard
            var session = await openWaitingSession(
                generation: generation, into: mergedContinuation,
                seeding: initialSeed)
        else { return .ended }

        var sawStrongSpeech = false
        var pendingPause = false

        /// Whether the most recent reopen carried a barge seed.
        var reopenWasSeeded = false

        /// Reopen the microphone after a narration and reset the
        /// endpoint state for the fresh session.
        func reopen() async -> Bool {
            let seed = takePendingBargeText()
            reopenWasSeeded = seed != nil
            guard
                let fresh = await openWaitingSession(
                    generation: generation, into: mergedContinuation,
                    seeding: seed)
            else { return false }
            session = fresh
            sawStrongSpeech = false
            pendingPause = false
            return true
        }

        /// Discard the open session and play a final response; the
        /// watch is resolved either way once it has played.
        func narrateFinal(_ markdown: String) async -> WatchOutcome {
            await discardWaitingSession(session, generation: generation)
            switch await narrate(markdown) {
            case .ended:
                return .ended
            case .finished:
                return .relisten
            }
        }

        /// Resolve a sendable endpoint of the waiting session. A nil
        /// return means the phase continues on a fresh session.
        func resolveSend() async -> WatchOutcome? {
            closeWaitingTasks(session)
            switch await completeSend(
                generation: generation, sessionID: session.id)
            {
            case .ended:
                return .ended
            case .watchArmed(let newEvents):
                return .rearmed(newEvents, pendingNarration: pendingFinal)
            case .keepListening:
                // The turn injected nothing. The watch is still the
                // live concern: play anything queued, or keep
                // waiting on a fresh session.
                if let final = pendingFinal {
                    pendingFinal = nil
                    switch await narrate(final) {
                    case .ended:
                        return .ended
                    case .finished:
                        return .relisten
                    }
                }
                if watchResolved { return .relisten }
                guard await reopen() else {
                    return .ended
                }
                return nil
            }
        }

        // An interruption is the message: a carried sentence sends
        // the moment its session opens.
        if initialSeed != nil, let outcome = await resolveSend() {
            return outcome
        }

        var iterator = merged.makeAsyncIterator()
        while let event = await iterator.next() {
            guard generation == callGeneration, !Task.isCancelled else {
                closeWaitingTasks(session)
                return .ended
            }
            switch event {
            case .turn(let turnEvent, let eventSession):
                // Stragglers from a discarded session must not steer
                // the fresh one.
                guard eventSession == session.id else { continue }
                switch turnEvent {
                case .signal(.strongSpeech), .signal(.emphaticSpeech):
                    sawStrongSpeech = true
                    #if DEBUG
                        if case .signal(let s) = turnEvent {
                            waitingSignalObserver?(s)
                        }
                    #endif
                    if pendingPause {
                        if let outcome = await resolveSend() {
                            return outcome
                        }
                    }
                case .signal(.transcribedSpeech):
                    // Content without voice-level evidence: a
                    // recognizer captions residual and noise, so
                    // cycle text alone never gates anything.
                    continue
                case .signal(.audibleSpeech):
                    pendingPause = false
                case .signal(.pause):
                    if sawStrongSpeech {
                        if let outcome = await resolveSend() {
                            return outcome
                        }
                    } else if let final = pendingFinal {
                        pendingFinal = nil
                        return await narrateFinal(final)
                    } else {
                        // An empty pause re-arms; the mic stays open.
                        pendingPause = true
                    }
                case .force:
                    if let outcome = await resolveSend() {
                        return outcome
                    }
                case .idleTimeout:
                    // Voice-level evidence means the user is present;
                    // their endpoint will come. A watch with recent
                    // signs of life means the agent is mid-work, and
                    // hanging up under it would orphan the response —
                    // the deadline re-arms instead. Only a silent
                    // user under a silent agent closes the call: an
                    // open microphone must not outlive the
                    // conversation.
                    if !sawStrongSpeech {
                        if Date().timeIntervalSince(lastWatchEventAt)
                            < idleTimeout
                        {
                            session.idleTimer.cancel()
                            session = WaitingSession(
                                id: session.id,
                                forwarder: session.forwarder,
                                idleTimer: makeWaitingIdleTimer(
                                    sessionID: session.id,
                                    into: mergedContinuation))
                        } else {
                            closeWaitingTasks(session)
                            cuePlayer.playDoneCue()
                            hangUp()
                            return .ended
                        }
                    }
                case .narrationEnded, .bargeArmed:
                    continue
                }

            case .watch(let watchEvent, let arrivedAt):
                lastWatchEventAt = Date()
                switch watchEvent {
                case .stillWorking:
                    // The agent's transcript is moving; nothing to
                    // narrate, but the conversation is alive.
                    continue
                case .interimMessage(let markdown):
                    guard !watchResolved else { continue }
                    if sawStrongSpeech {
                        Log.debug("[Call] interim dropped behind speech")
                        continue
                    }
                    if let dropInterimsBefore,
                        arrivedAt < dropInterimsBefore
                    {
                        Log.debug("[Call] interim dropped as stale")
                        continue
                    }
                    await discardWaitingSession(
                        session, generation: generation)
                    switch await narrate(markdown) {
                    case .ended:
                        return .ended
                    case .finished:
                        guard await reopen() else {
                            return .ended
                        }
                        // An interruption is the message: a carried
                        // sentence sends the moment its session opens.
                        if reopenWasSeeded,
                            let outcome = await resolveSend()
                        {
                            return outcome
                        }
                    }
                case .response(let markdown):
                    if sawStrongSpeech {
                        Log.debug("[Call] final queued behind speech")
                        pendingFinal = markdown
                        continue
                    }
                    return await narrateFinal(markdown)
                case .completed(let markdown):
                    if playedThisWatch.contains(markdown) {
                        // Its text already took the floor this watch.
                        if sawStrongSpeech {
                            watchResolved = true
                            continue
                        }
                        await discardWaitingSession(
                            session, generation: generation)
                        return .relisten
                    }
                    if sawStrongSpeech {
                        Log.debug("[Call] completion queued behind speech")
                        pendingFinal = markdown
                        continue
                    }
                    return await narrateFinal(markdown)
                case .toolOnly:
                    // No cue: with tool-heavy agents the window
                    // expires constantly, and the pill's return to
                    // listening already shows it. The done cue is
                    // reserved for the call itself ending.
                    if sawStrongSpeech {
                        watchResolved = true
                        continue
                    }
                    await discardWaitingSession(
                        session, generation: generation)
                    return .relisten
                }

            case .watchEnded:
                // The watch ended with nothing left to deliver; play
                // anything queued, or finish the user's turn first.
                if let final = pendingFinal, !sawStrongSpeech {
                    pendingFinal = nil
                    return await narrateFinal(final)
                }
                if sawStrongSpeech {
                    watchResolved = true
                    continue
                }
                await discardWaitingSession(session, generation: generation)
                return .relisten
            }
        }
        closeWaitingTasks(session)
        return .ended
    }

    /// Open the waiting phase's capture session and forward its turn
    /// events into the watch select. Returns nil when the call is
    /// over — the pipeline refused capture, which finishes the call
    /// audibly here, or a hangup raced the activation.
    private func openWaitingSession(
        generation: Int,
        into merged: AsyncStream<WatchPhaseEvent>.Continuation,
        seeding seed: String? = nil
    ) async -> WaitingSession? {
        guard let sessionID = await pipeline.activate(playsCaptureCues: false)
        else {
            if generation == callGeneration, !Task.isCancelled {
                cuePlayer.playDoneCue()
            }
            finishCall(generation: generation)
            return nil
        }
        // Seed before capture adoption so the carried sentence sits
        // ahead of whatever the live audio decodes.
        if let seed {
            await pipeline.seedTranscript(seed, sessionID: sessionID)
            Log.debug("[Call] barge text seeded")
        }
        let signals = signalHub.signals(for: sessionID)
        let forwarder = Task {
            for await signal in signals {
                merged.yield(.turn(.signal(signal), session: sessionID))
            }
        }
        forceSendTrigger = {
            merged.yield(.turn(.force, session: sessionID))
        }
        let idleTimer = makeWaitingIdleTimer(
            sessionID: sessionID, into: merged)
        guard
            adoptCapture(
                generation: generation, sessionID: sessionID, into: .waiting)
        else {
            forwarder.cancel()
            idleTimer.cancel()
            await pipeline.cancel(sessionID: sessionID)
            return nil
        }
        return WaitingSession(
            id: sessionID, forwarder: forwarder, idleTimer: idleTimer)
    }

    /// Schedule one idle deadline for a waiting session. The watch
    /// loop re-arms it while the agent shows signs of life.
    private func makeWaitingIdleTimer(
        sessionID: DictationSessionID,
        into merged: AsyncStream<WatchPhaseEvent>.Continuation
    ) -> Task<Void, Never> {
        let timeout = idleTimeout
        return Task {
            try? await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            merged.yield(.turn(.idleTimeout, session: sessionID))
        }
    }

    /// Take the carried barge sentence, if any, leaving none behind.
    private func takePendingBargeText() -> String? {
        let text = pendingBargeText
        pendingBargeText = nil
        return text
    }

    /// Stop a waiting session's forwarding tasks without touching its
    /// pipeline session — for endpoints whose completion now owns it,
    /// and for exits where hangup owns the teardown.
    private func closeWaitingTasks(_ session: WaitingSession) {
        forceSendTrigger = nil
        session.forwarder.cancel()
        session.idleTimer.cancel()
    }

    /// Discard a waiting session entirely: whatever it heard dies
    /// with it.
    private func discardWaitingSession(
        _ session: WaitingSession,
        generation: Int
    ) async {
        closeWaitingTasks(session)
        clearCapture(generation: generation, sessionID: session.id)
        await pipeline.cancel(sessionID: session.id)
    }

    private func speak(_ markdown: String) async {
        let content = ReadableContent(
            segments: MarkdownSegmenter.segments(from: markdown))
        Log.debug("[Call] speak begin at \(CFAbsoluteTimeGetCurrent())")
        await synthesizer.speak(scriptBuilder.script(for: content))
        Log.debug("[Call] speak end at \(CFAbsoluteTimeGetCurrent())")
    }

    /// Subscribe to the capture session's signals and install the
    /// force-send trigger. A non-nil idle timeout schedules the
    /// turn's idle deadline; the endpoint ignores it once any speech
    /// was heard.
    private func beginTurnWait(
        sessionID: DictationSessionID,
        idleTimeout: TimeInterval?
    ) -> TurnWait {
        let (events, continuation) = AsyncStream<TurnEvent>.makeStream()
        let signals = signalHub.signals(for: sessionID)
        let forwarder = Task {
            for await signal in signals {
                continuation.yield(.signal(signal))
            }
        }
        forceSendTrigger = { continuation.yield(.force) }
        let idleTimer = idleTimeout.map { timeout in
            Task {
                try? await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                continuation.yield(.idleTimeout)
            }
        }
        return TurnWait(
            events: events,
            continuation: continuation,
            forwarder: forwarder,
            idleTimer: idleTimer)
    }

    private func endTurnWait(_ wait: TurnWait) {
        forceSendTrigger = nil
        wait.forwarder.cancel()
        wait.idleTimer?.cancel()
        wait.continuation.finish()
    }

    /// Consume the capture session's turn signals until an endpoint.
    ///
    /// A pause sends only when speech was transcribed. A pause that
    /// arrives before the transcript catches up is held pending: the
    /// late-arriving transcript sends the turn, unless speech audio
    /// resumed first, which re-arms the endpoint. Returns nil when
    /// the call was hung up mid-listen.
    private func awaitTurnEnd(_ wait: TurnWait) async -> TurnEnd? {
        defer { endTurnWait(wait) }

        var sawStrongSpeech = false
        var pendingPause = false
        for await event in wait.events {
            guard !Task.isCancelled else { return nil }
            switch event {
            case .signal(.strongSpeech), .signal(.emphaticSpeech):
                sawStrongSpeech = true
                if pendingPause {
                    return .send(sawTranscribedSpeech: true)
                }
            case .signal(.transcribedSpeech):
                // Content without voice-level evidence: a recognizer
                // captions residual and noise, so cycle text alone
                // neither gates a send nor holds the idle deadline.
                continue
            case .signal(.audibleSpeech):
                pendingPause = false
            case .signal(.pause):
                if sawStrongSpeech {
                    return .send(sawTranscribedSpeech: true)
                }
                pendingPause = true
            case .force:
                return .send(sawTranscribedSpeech: sawStrongSpeech)
            case .idleTimeout:
                // Voice-level evidence anywhere in the turn means the
                // user is present; the endpoint will come, so the
                // deadline stands down. Merely audible noise must not
                // hold an open microphone forever.
                if !sawStrongSpeech {
                    return .idleTimedOut
                }
            case .narrationEnded, .bargeArmed:
                continue
            }
        }
        return nil
    }

    /// Narrate over a watch-only capture and discard everything it
    /// heard.
    ///
    /// The canceller removes the voice's direct echo, but a sensitive
    /// microphone still hears the room's reverberant residual —
    /// inaudible to ears, legible to a recognizer, which live testing
    /// showed transcribing whole narrations back as turns. So the
    /// capture running under a narration exists only to watch levels:
    /// strong speech stops the voice, the buttons stop the voice, and
    /// when the voice ends — either way — the session is cancelled,
    /// its transcript dies with it, and the caller opens a fresh
    /// clean session.
    private func narrateOverWatch(
        generation: Int,
        markdown: String
    ) async -> NarrationOutcome {
        guard let sessionID = await pipeline.activate(playsCaptureCues: false)
        else {
            if generation == callGeneration, !Task.isCancelled {
                cuePlayer.playDoneCue()
            }
            finishCall(generation: generation)
            return .ended
        }
        let turnWait = beginTurnWait(sessionID: sessionID, idleTimeout: nil)
        guard
            adoptCapture(
                generation: generation,
                sessionID: sessionID,
                into: .speaking)
        else {
            endTurnWait(turnWait)
            await pipeline.cancel(sessionID: sessionID)
            return .ended
        }

        let continuation = turnWait.continuation
        let hub = farEndHub
        Task { [weak self] in
            // Capture activation can resolve before the transport
            // renders; narrating ahead of the far-end channel would
            // fall back to an engine the canceller only hears as
            // other audio.
            if let hub,
                await hub.waitForActiveChannel(timeoutSeconds: 1.0) == nil
            {
                Log.debug("[Call] narrating without a far-end channel")
            }
            await self?.speak(markdown)
            continuation.yield(.narrationEnded)
        }

        let outcome = await watchNarration(
            turnWait, sessionID: sessionID, narration: markdown)
        clearCapture(generation: generation, sessionID: sessionID)
        await pipeline.cancel(sessionID: sessionID)
        guard generation == callGeneration, !Task.isCancelled
        else { return .ended }
        return outcome
    }

    /// Whether a barge-carried sentence is the narration's own echo.
    ///
    /// Live failure: loud playback survived cancellation, tripped the
    /// emphatic gate right at speak-end, and the carry transcribed
    /// the voice's own words ("mode. In incognito...") — which then
    /// sent as the user's turn. A real barge brings the user's own
    /// words; an echo brings only the voice's. Judge by containment:
    /// when nearly every carried word appears in the spoken script,
    /// the carry is echo. A user genuinely quoting narration words
    /// adds their own around them and stays under the bar.
    static func isNarrationEcho(_ carried: String, spoken: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let carriedWords = words(carried)
        guard !carriedWords.isEmpty else { return true }
        let spokenWords = Set(words(spoken))
        guard !spokenWords.isEmpty else { return false }
        let contained = carriedWords.filter(spokenWords.contains).count
        return Double(contained) / Double(carriedWords.count) >= 0.8
    }

    /// Watch a narration's capture for the voice's stopping
    /// conditions only. Nothing heard here can send; the session is
    /// discarded when the narration resolves.
    ///
    /// A voice barge stops the playback but does not resolve the
    /// watch: the user's barging sentence is still in flight. The
    /// watch session absorbs the whole sentence through its pause,
    /// then its audio — sliced from just before the barge's onset —
    /// is carried into the fresh session that follows, so the words
    /// that stopped the voice open the user's next message instead
    /// of vanishing. The watch session's own transcript still dies
    /// with it: everything before the onset is narration residual.
    ///
    /// A carried sentence whose words all come from the narration
    /// itself is the voice's own echo — loud playback can survive
    /// cancellation, trip the emphatic gate, and arrive here as a
    /// "barge" — so it is rejected instead of sent as the user.
    private func watchNarration(
        _ wait: TurnWait,
        sessionID: DictationSessionID,
        narration: String
    ) async -> NarrationOutcome {
        defer { endTurnWait(wait) }

        var narrationRunning = true
        var absorbingBarge = false
        var bargeStartedAt: Date?
        var bargeArmed = narrationOnsetGuardSeconds <= 0
        var armTask: Task<Void, Never>?
        if !bargeArmed {
            let continuation = wait.continuation
            let guardSeconds = narrationOnsetGuardSeconds
            armTask = Task {
                try? await Task.sleep(
                    nanoseconds: UInt64(guardSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                continuation.yield(.bargeArmed)
            }
        }
        defer {
            armTask?.cancel()
            if narrationRunning { synthesizer.stopSpeaking() }
        }
        for await event in wait.events {
            guard !Task.isCancelled else { return .ended }
            switch event {
            case .signal(.emphaticSpeech):
                guard bargeArmed else {
                    Log.debug("[Call] onset guard swallowed strong speech")
                    continue
                }
                guard !absorbingBarge else { continue }
                Log.debug("[Call] voice barge-in over narration")
                narrationRunning = false
                absorbingBarge = true
                bargeStartedAt = Date()
                synthesizer.stopSpeaking()
            case .signal(.pause):
                if absorbingBarge {
                    Log.debug("[Call] barge sentence absorbed")
                    // No cue here: the carried sentence sends
                    // immediately, and the send cue at injection is
                    // the confirmation the user was trained on.
                    let carrySeconds = min(
                        Date().timeIntervalSince(bargeStartedAt ?? Date())
                            + bargeCarryPreRollSeconds,
                        bargeCarryMaximumSeconds)
                    let carried = await pipeline.transcribeRecentCapture(
                        sessionID: sessionID, seconds: carrySeconds)
                    if let carried {
                        let spoken = scriptBuilder.script(
                            for: ReadableContent(
                                segments: MarkdownSegmenter.segments(
                                    from: narration)))
                        if Self.isNarrationEcho(carried, spoken: spoken) {
                            Log.debug(
                                "[Call] barge carry rejected as narration echo")
                            return .finished(bargedText: nil)
                        }
                        Log.debug(
                            "[Call] barge sentence carried: \(carried)")
                    }
                    return .finished(bargedText: carried)
                }
                // The cancelled voice's silence means nothing.
                continue
            case .signal(.transcribedSpeech), .signal(.audibleSpeech),
                .signal(.strongSpeech):
                // The recognizer captions the voice's own residual, so
                // cycle text is meaningless here, as are audible
                // swells — and residual can cross the open-session
                // strong bar. Only the emphatic contour of a voice
                // takes the floor.
                continue
            case .bargeArmed:
                bargeArmed = true
            case .narrationEnded:
                narrationRunning = false
                // Under an absorb the voice was already stopped; the
                // user's sentence is still finishing.
                if absorbingBarge { continue }
                return .finished(bargedText: nil)
            case .force:
                // The send key during a narration stops the voice;
                // the fresh session that follows is what can send.
                narrationRunning = false
                synthesizer.stopSpeaking()
                return .finished(bargedText: nil)
            case .idleTimeout:
                continue
            }
        }
        return .ended
    }

    /// Bind the accepted capture session to the still-current call
    /// and enter listening — or the caller's phase, for waiting and
    /// narration sessions.
    private func adoptCapture(
        generation: Int,
        sessionID: DictationSessionID,
        into initialState: ConversationCallState = .listening
    ) -> Bool {
        guard generation == callGeneration else { return false }
        captureSessionID = sessionID
        transition(to: initialState)
        return true
    }

    /// Release a capture session that completion now owns.
    private func clearCapture(
        generation: Int,
        sessionID: DictationSessionID
    ) {
        guard generation == callGeneration, captureSessionID == sessionID
        else { return }
        captureSessionID = nil
    }

    /// End the call without a capture to tear down: the start was
    /// refused or failed before listening began. A refusal with no
    /// reachable agent session ends in the guidance state.
    private func finishCall(
        generation: Int,
        in terminalState: ConversationCallState = .idle
    ) {
        guard generation == callGeneration else { return }
        callTask = nil
        lastResolvedAgent = nil
        pinnedApplication = nil
        pinnedBundleID = nil
        transition(to: terminalState)
    }
}
