import Foundation

/// Coordinate recording state transitions for the dictation pipeline.
///
/// `RecordingCoordinator` is the single source of truth for the current
/// `RecordingState`. It enforces valid transitions and notifies observers
/// via an `AsyncStream`. All state mutations are serialized through an
/// actor to guarantee thread safety.
public actor RecordingCoordinator {

    // MARK: - State

    private var _state: RecordingState = .idle
    private var continuations: [UUID: AsyncStream<RecordingState>.Continuation] = [:]

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

    private func addContinuation(
        id: UUID,
        continuation: AsyncStream<RecordingState>.Continuation
    ) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // MARK: - Transitions

    /// Transition to `.recording`. Only valid from `.idle`.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func startRecording() -> Bool {
        guard _state == .idle else { return false }
        transition(to: .recording)
        return true
    }

    /// Transition to `.processing`. Only valid from `.recording`.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func stopRecording() -> Bool {
        guard _state == .recording else { return false }
        transition(to: .processing)
        return true
    }

    /// Transition to `.injecting`. Only valid from `.processing`.
    ///
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    public func startInjecting() -> Bool {
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
        guard _state == .injecting else { return false }
        transition(to: .injectionFailed)
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
        guard
            _state == .injecting || _state == .processing
                || _state == .injectionFailed || _state == .sessionExpired
                || _state == .dictationFailed
        else { return false }
        transition(to: .idle)
        return true
    }

    /// Force-reset to `.idle` from any state. Use for error recovery
    /// or cancellation.
    public func reset() {
        transition(to: .idle)
    }

    // MARK: - Internal

    private func transition(to newState: RecordingState) {
        _state = newState
        for (_, continuation) in continuations {
            continuation.yield(newState)
        }
    }
}
