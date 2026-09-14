import Foundation

/// Owns the read session: snapshot, acquisition, speech, and stop.
///
/// One session exists at a time. Toggling during acquisition or speech
/// stops the session; a press while dictation is recording is ignored so
/// the two features never contend for audio. `toggle` claims or releases
/// the session without suspending, so two rapid presses cannot start two
/// sessions; the dictation check happens inside the session task.
public actor ReadAloudCoordinator {

    private let contextProvider: any AppContextProviding
    private let sources: [any ContentSourceProviding]
    private let scriptBuilder: SpeechScriptBuilder
    private let synthesizer: any SpeechSynthesizing
    private let isDictationActive: @Sendable () async -> Bool
    private let acquisitionTimeout: TimeInterval

    private var sessionTask: Task<Void, Never>?

    /// The most recently stopped session's task, retained so
    /// `waitForSession` can drain an abandoned session deterministically.
    private var stoppedSessionTask: Task<Void, Never>?

    /// Incremented on every session start and stop. A finishing session
    /// commits its teardown only when its generation is still current, so
    /// a stale task cannot clear a newer session's handle or state.
    private var sessionGeneration = 0

    private var state: ReadAloudState = .idle
    private var continuations: [UUID: AsyncStream<ReadAloudState>.Continuation] =
        [:]

    public init(
        contextProvider: any AppContextProviding,
        sources: [any ContentSourceProviding],
        scriptBuilder: SpeechScriptBuilder = SpeechScriptBuilder(),
        synthesizer: any SpeechSynthesizing,
        isDictationActive: @escaping @Sendable () async -> Bool,
        acquisitionTimeout: TimeInterval = 2.0
    ) {
        self.contextProvider = contextProvider
        self.sources = sources
        self.scriptBuilder = scriptBuilder
        self.synthesizer = synthesizer
        self.isDictationActive = isDictationActive
        self.acquisitionTimeout = acquisitionTimeout
    }

    // MARK: - Observation

    /// Stream state changes. The current state is emitted immediately upon
    /// subscription, followed by every subsequent change.
    public var stateStream: AsyncStream<ReadAloudState> {
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

    private func transition(to newState: ReadAloudState) {
        state = newState
        for (_, continuation) in continuations {
            continuation.yield(newState)
        }
    }

    // MARK: - Session control

    /// Start a read session, or stop the one in progress.
    public func toggle() {
        if sessionTask != nil {
            stop()
            return
        }
        startSession()
    }

    /// Stop the current session immediately. Safe to call at any time;
    /// dictation start calls this so speech never overlaps capture. Also
    /// clears lingering no-content guidance so dictation never starts
    /// under a stale read-session state.
    public func stop() {
        guard let task = sessionTask else {
            if state == .noContent {
                transition(to: .idle)
            }
            return
        }
        sessionTask = nil
        stoppedSessionTask = task
        sessionGeneration += 1
        task.cancel()
        synthesizer.stopSpeaking()
        transition(to: .idle)
    }

    /// Dismiss the no-content guidance. Ignored while a session is active
    /// so a delayed dismissal can never disturb a newer session's state.
    public func dismissGuidance() {
        guard sessionTask == nil, state == .noContent else { return }
        transition(to: .idle)
    }

    /// Wait for the in-flight or most recently stopped session to finish.
    func waitForSession() async {
        await sessionTask?.value
        await stoppedSessionTask?.value
    }

    private func startSession() {
        transition(to: .acquiring)
        sessionGeneration += 1
        let generation = sessionGeneration
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.runSession(generation: generation)
        }
    }

    private func runSession(generation: Int) async {
        // Ignored while dictation is recording so a stray press cannot
        // speak over the user's own capture (checked here, inside the
        // claimed session, so the claim itself never suspends).
        guard await !isDictationActive() else {
            finishSession(generation: generation, in: .idle)
            return
        }

        let context = await contextProvider.readContext()
        guard !Task.isCancelled else { return }

        var acquired: ReadableContent?
        for source in sources {
            guard !Task.isCancelled else { return }
            let content = await withTimeout(seconds: acquisitionTimeout) {
                try? await source.readContent(for: context)
            }
            if let content = content ?? nil, !content.isEmpty {
                acquired = content
                Log.debug(
                    "[ReadAloud] session=\(generation) app=\(context.bundleID) "
                        + "source=\(String(describing: type(of: source))) "
                        + "segments=\(content.segments.count)")
                break
            }
        }

        guard !Task.isCancelled else { return }
        guard let acquired else {
            Log.debug("[ReadAloud] No content source yielded content")
            finishSession(generation: generation, in: .noContent)
            return
        }

        // Re-checked after acquisition: dictation that started meanwhile
        // owns the audio path, so the session yields instead of speaking
        // over an open microphone.
        guard await !isDictationActive() else {
            finishSession(generation: generation, in: .idle)
            return
        }

        transitionIfCurrent(generation: generation, to: .speaking)
        let script = scriptBuilder.script(for: acquired)
        Log.debug(
            "[ReadAloud] session=\(generation) script "
                + SpeechDiagnostics.textStructure(script))
        await synthesizer.speak(script)
        finishSession(generation: generation, in: .idle)
    }

    private func transitionIfCurrent(generation: Int, to newState: ReadAloudState) {
        guard generation == sessionGeneration else { return }
        transition(to: newState)
    }

    /// End the session in a terminal state: `.idle` after speech or an
    /// ignored press, `.noContent` when acquisition found nothing so the
    /// UI can show guidance.
    private func finishSession(generation: Int, in terminalState: ReadAloudState) {
        guard generation == sessionGeneration else { return }
        sessionTask = nil
        transition(to: terminalState)
    }
}
