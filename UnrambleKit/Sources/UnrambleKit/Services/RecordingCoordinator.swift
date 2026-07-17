import Foundation

/// Two-phase ownership for a transition to `.idle`.
///
/// Claiming freezes the coordinator's session without publishing a state
/// change. The pipeline can then release its matching owner before committing
/// the visible idle transition.
struct RecordingIdleTransitionClaim: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let sessionID: DictationSessionID
}

/// Coordinate recording state transitions for the dictation pipeline.
///
/// `RecordingCoordinator` is the single source of truth for the current
/// `RecordingState`. It enforces valid transitions and notifies observers
/// via an `AsyncStream`. All state mutations are serialized through an
/// actor to guarantee thread safety.
public actor RecordingCoordinator {

    // MARK: - State

    private var _state: RecordingState = .idle
    private var sessionID: DictationSessionID?
    private var idleTransitionClaim: RecordingIdleTransitionClaim?
    private var continuations: [UUID: AsyncStream<RecordingState>.Continuation] = [:]
    private var sessionContinuations:
        [UUID: AsyncStream<RecordingStateUpdate>.Continuation] = [:]

    /// The current recording state.
    public var state: RecordingState {
        _state
    }

    public init() {}

    // MARK: - Observation

    /// Stream recording state changes. The current state is emitted
    /// immediately upon subscription, followed by every subsequent change.
    public var stateStream: AsyncStream<RecordingState> {
        let currentState = _state
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(currentState)
            self.addContinuation(id: id, continuation: continuation)
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id: id) }
            }
        }
    }

    /// Stream state changes together with the session that owns each change.
    /// The current state is emitted immediately. An idle transition retains the
    /// ID of the session that ended so a delayed observer cannot clear a newer
    /// session's UI ownership.
    public var sessionStateStream: AsyncStream<RecordingStateUpdate> {
        let currentUpdate = RecordingStateUpdate(
            state: _state,
            sessionID: sessionID)
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(currentUpdate)
            self.addSessionContinuation(
                id: id,
                continuation: continuation)
            continuation.onTermination = { _ in
                Task { await self.removeSessionContinuation(id: id) }
            }
        }
    }

    private func addContinuation(
        id: UUID,
        continuation: AsyncStream<RecordingState>.Continuation
    ) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func addSessionContinuation(
        id: UUID,
        continuation: AsyncStream<RecordingStateUpdate>.Continuation
    ) {
        sessionContinuations[id] = continuation
    }

    private func removeSessionContinuation(id: UUID) {
        sessionContinuations.removeValue(forKey: id)
    }

    // MARK: - Transitions

    /// Transition to `.recording`. Only valid from `.idle`.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func startRecording() -> Bool {
        startRecording(sessionID: DictationSessionID())
    }

    @discardableResult
    public func startRecording(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard _state == .idle else { return false }
        self.sessionID = sessionID
        transition(to: .recording)
        return true
    }

    /// Transition to `.processing`. Only valid from `.recording`.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func stopRecording() -> Bool {
        guard let sessionID else { return false }
        return stopRecording(sessionID: sessionID)
    }

    @discardableResult
    public func stopRecording(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID else { return false }
        guard _state == .recording else { return false }
        transition(to: .processing)
        return true
    }

    /// Transition to `.injecting`. Only valid from `.processing`.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func startInjecting() -> Bool {
        guard let sessionID else { return false }
        return startInjecting(sessionID: sessionID)
    }

    @discardableResult
    public func startInjecting(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID else { return false }
        guard _state == .processing else { return false }
        transition(to: .injecting)
        return true
    }

    /// Transition to `.injectionFailed`. Only valid from `.injecting`.
    ///
    /// The HUD shows the no-target recovery state until the user dismisses
    /// it or pastes via the special shortcut, then call `reset()`.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func failInjection() -> Bool {
        guard let sessionID else { return false }
        return failInjection(sessionID: sessionID)
    }

    @discardableResult
    public func failInjection(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID else { return false }
        guard _state == .injecting else { return false }
        transition(to: .injectionFailed)
        return true
    }

    /// Reclaim a failed publication for one explicit retry. The transition is
    /// atomic, so Retry and manual paste cannot both publish the same session.
    @discardableResult
    public func retryInjection(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID else { return false }
        guard _state == .injectionFailed else { return false }
        transition(to: .injecting)
        return true
    }

    /// Transition to `.sessionExpired`. Valid from `.processing`.
    ///
    /// The HUD shows a "Session expired" message and the app enters
    /// the recovery flow (clear Keychain, open sign-in or onboarding).
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func expireSession() -> Bool {
        guard let sessionID else { return false }
        return expireSession(sessionID: sessionID)
    }

    @discardableResult
    public func expireSession(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID else { return false }
        guard _state == .processing else { return false }
        transition(to: .sessionExpired)
        return true
    }

    /// Transition to `.dictationFailed`. Only valid from `.processing`.
    ///
    /// The HUD shows a retry/dismiss recovery UI until the user acts.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func failDictation() -> Bool {
        guard let sessionID else { return false }
        return failDictation(sessionID: sessionID)
    }

    @discardableResult
    public func failDictation(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID else { return false }
        guard _state == .processing else { return false }
        transition(to: .dictationFailed)
        return true
    }

    /// Make retained dictation available for an explicit retry after the user
    /// replaces an expired credential. Only valid from `.sessionExpired`.
    ///
    /// This transition does not start transcription or injection. The user can
    /// first restore focus to the intended target, then choose Retry.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func prepareDictationRecovery() -> Bool {
        guard let sessionID else { return false }
        return prepareDictationRecovery(sessionID: sessionID)
    }

    @discardableResult
    public func prepareDictationRecovery(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID else { return false }
        guard _state == .sessionExpired else { return false }
        transition(to: .dictationFailed)
        return true
    }

    /// Transition back to `.processing` to re-attempt dictation.
    /// Valid after an ordinary failure or after expired credentials have been
    /// replaced and `prepareDictationRecovery()` has exposed explicit Retry.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func retryDictation() -> Bool {
        guard let sessionID else { return false }
        return retryDictation(sessionID: sessionID)
    }

    @discardableResult
    public func retryDictation(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID else { return false }
        guard _state == .dictationFailed else { return false }
        transition(to: .processing)
        return true
    }

    /// Transition to `.idle`. Valid from `.injecting` (normal completion),
    /// `.processing` (cancellation / error recovery), `.injectionFailed`
    /// (user dismissed the no-target state), `.sessionExpired` (after
    /// the recovery flow has been triggered), or `.dictationFailed`
    /// (user dismissed or recovery succeeded).
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func finishInjecting() -> Bool {
        guard let sessionID else { return false }
        return finishInjecting(sessionID: sessionID)
    }

    @discardableResult
    public func finishInjecting(sessionID: DictationSessionID) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID else { return false }
        guard
            _state == .injecting || _state == .processing
                || _state == .injectionFailed || _state == .sessionExpired
                || _state == .dictationFailed
        else { return false }
        transition(to: .idle)
        self.sessionID = nil
        return true
    }

    /// Reset to `.idle` only when no pipeline is between terminal claim and
    /// ownership release. Session-owned cancellation uses `reset(sessionID:)`
    /// so it can safely adopt a matching in-flight claim.
    @discardableResult
    public func reset() -> Bool {
        guard idleTransitionClaim == nil else { return false }
        transition(to: .idle)
        sessionID = nil
        return true
    }

    /// Reset only if the caller still owns the visible state.
    @discardableResult
    public func reset(sessionID: DictationSessionID) -> Bool {
        guard self.sessionID == sessionID else { return false }
        if let claim = idleTransitionClaim {
            guard claim.sessionID == sessionID else { return false }
            transition(to: .idle)
            self.sessionID = nil
            idleTransitionClaim = nil
            return true
        }
        transition(to: .idle)
        self.sessionID = nil
        return true
    }

    /// Reset a recoverable UI state only if it still belongs to the caller's
    /// session. Both checks are required because a replacement can reach the
    /// same visible state before a delayed dismissal runs.
    @discardableResult
    public func reset(
        sessionID: DictationSessionID,
        ifState expectedState: RecordingState
    ) -> Bool {
        guard idleTransitionClaim == nil else { return false }
        guard self.sessionID == sessionID, _state == expectedState else {
            return false
        }
        transition(to: .idle)
        self.sessionID = nil
        return true
    }

    /// Reserve a normal injection completion without publishing `.idle`.
    func claimFinishInjecting(
        sessionID: DictationSessionID
    ) -> RecordingIdleTransitionClaim? {
        guard idleTransitionClaim == nil, self.sessionID == sessionID else {
            return nil
        }
        guard _state == .injecting else { return nil }
        return reserveIdleTransition(sessionID: sessionID)
    }

    /// Reserve an unconditional session-owned reset without publishing idle.
    func claimReset(
        sessionID: DictationSessionID
    ) -> RecordingIdleTransitionClaim? {
        guard idleTransitionClaim == nil, self.sessionID == sessionID else {
            return nil
        }
        return reserveIdleTransition(sessionID: sessionID)
    }

    /// Reserve a recoverable-state dismissal without allowing Retry to cross it.
    func claimReset(
        sessionID: DictationSessionID,
        ifState expectedState: RecordingState
    ) -> RecordingIdleTransitionClaim? {
        guard idleTransitionClaim == nil, self.sessionID == sessionID,
            _state == expectedState
        else { return nil }
        return reserveIdleTransition(sessionID: sessionID)
    }

    /// Publish the idle transition only for the still-current claim.
    @discardableResult
    func commitIdleTransition(_ claim: RecordingIdleTransitionClaim) -> Bool {
        guard idleTransitionClaim == claim, sessionID == claim.sessionID else {
            return false
        }
        transition(to: .idle)
        sessionID = nil
        idleTransitionClaim = nil
        return true
    }

    /// Release a claim when the pipeline lost ownership before it could commit.
    func cancelIdleTransition(_ claim: RecordingIdleTransitionClaim) {
        guard idleTransitionClaim == claim else { return }
        idleTransitionClaim = nil
    }

    // MARK: - Internal

    private func transition(to newState: RecordingState) {
        _state = newState
        for (_, continuation) in continuations {
            continuation.yield(newState)
        }
        let update = RecordingStateUpdate(
            state: newState,
            sessionID: sessionID)
        for (_, continuation) in sessionContinuations {
            continuation.yield(update)
        }
    }

    private func reserveIdleTransition(
        sessionID: DictationSessionID
    ) -> RecordingIdleTransitionClaim {
        let claim = RecordingIdleTransitionClaim(
            id: UUID(),
            sessionID: sessionID)
        idleTransitionClaim = claim
        return claim
    }
}
