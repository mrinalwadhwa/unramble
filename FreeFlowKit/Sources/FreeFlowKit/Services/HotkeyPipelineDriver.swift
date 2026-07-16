import Foundation

/// Exact physical-press ownership handed to UI when push-to-talk becomes
/// hands-free. Keeping the boundary with the session lets UI Stop publish the
/// same synchronous cutoff after physical release authority is transferred.
public struct HotkeyHeldSession: Sendable {
    public let sessionID: DictationSessionID
    public let releaseBoundary: AudioCaptureReleaseBoundary
    fileprivate let pressID: UUID
}

/// Preserves hotkey callback order and binds release to the session accepted
/// for its press. Activation runs in one tracked task so a release can cancel
/// a reservation suspended behind prior ownership. Once the pipeline admits a
/// session, the activation returns that owner and release completes it.
public final class HotkeyPipelineDriver: @unchecked Sendable {
    private enum Observation: Sendable {
        case sessionAccepted(HotkeyHeldSession)
        case sessionEnded(DictationSessionID)
    }

    private struct PhysicalPress: Sendable {
        let id: UUID
        let releaseBoundary: AudioCaptureReleaseBoundary
    }

    private enum Command: @unchecked Sendable {
        case event(
            HotkeyEvent,
            hostTime: UInt64,
            press: PhysicalPress?
        )
        case transferHeldSession(
            PhysicalPress,
            @Sendable (HotkeyHeldSession?) -> Void
        )
        case activationFinished(UUID, DictationSessionID?)
        case completionFinished(UUID)
        case barrier(CheckedContinuation<Void, Never>)
        case commandBarrier(CheckedContinuation<Void, Never>)
    }

    private enum PendingActivationDisposition: @unchecked Sendable {
        case held
        case released(hostTime: UInt64)
        case transferred(@Sendable (HotkeyHeldSession?) -> Void)
    }

    private struct PendingActivation: @unchecked Sendable {
        let id: UUID
        let task: Task<DictationSessionID?, Never>
        let press: PhysicalPress
        var disposition: PendingActivationDisposition
    }

    private let continuation: AsyncStream<Command>.Continuation
    private let consumer: Task<Void, Never>
    private let observationConsumer: Task<Void, Never>
    private let canAdmitPress: @Sendable (UInt64) -> Bool
    private let ingressLock = NSLock()
    private var ingressPress: PhysicalPress?
    private var acceptsNewPresses = true
    private var ingressTerminated = false

    public init(
        pipeline: any PipelineProviding,
        canAdmitPress: @escaping @Sendable (UInt64) -> Bool = { _ in true },
        sessionAccepted: (@Sendable (DictationSessionID) async -> Void)? = nil,
        heldSessionAccepted: (@Sendable (HotkeyHeldSession) async -> Void)? = nil,
        sessionEnded: (@Sendable (DictationSessionID) async -> Void)? = nil
    ) {
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        let (observations, observationContinuation) =
            AsyncStream<Observation>.makeStream()
        self.continuation = continuation
        self.canAdmitPress = canAdmitPress
        self.observationConsumer = Task {
            for await observation in observations {
                switch observation {
                case .sessionAccepted(let heldSession):
                    await sessionAccepted?(heldSession.sessionID)
                    await heldSessionAccepted?(heldSession)
                case .sessionEnded(let sessionID):
                    await sessionEnded?(sessionID)
                }
            }
        }
        self.consumer = Task {
            var heldSession: HotkeyHeldSession?
            var pendingActivation: PendingActivation?
            var completionTasks: [UUID: Task<Void, Never>] = [:]
            var workBarriers: [CheckedContinuation<Void, Never>] = []

            func startCompletion(
                _ sessionID: DictationSessionID,
                releaseHostTime: UInt64
            ) {
                let id = UUID()
                completionTasks[id] = Task {
                    await pipeline.complete(
                        sessionID: sessionID,
                        releaseHostTime: releaseHostTime)
                    if await pipeline.currentSessionID != sessionID {
                        observationContinuation.yield(
                            .sessionEnded(sessionID))
                    }
                    continuation.yield(.completionFinished(id))
                }
            }

            func settleWorkBarriersIfIdle() {
                guard pendingActivation == nil, completionTasks.isEmpty else {
                    return
                }
                let barriers = workBarriers
                workBarriers.removeAll()
                barriers.forEach { $0.resume() }
            }

            for await command in stream {
                switch command {
                case .event(.pressed, _, let press):
                    guard heldSession == nil, pendingActivation == nil else {
                        continue
                    }
                    if !completionTasks.isEmpty,
                        await pipeline.state != .idle
                    {
                        continue
                    }
                    guard let press else { continue }
                    let id = UUID()
                    let task = Task {
                        let sessionID = await pipeline.activate(
                            releaseBoundary: press.releaseBoundary)
                        continuation.yield(
                            .activationFinished(id, sessionID))
                        return sessionID
                    }
                    pendingActivation = PendingActivation(
                        id: id,
                        task: task,
                        press: press,
                        disposition: .held)
                case .event(.released, let releaseHostTime, let press):
                    guard let press else { continue }
                    if var activation = pendingActivation {
                        guard activation.press.id == press.id else { continue }
                        guard case .held = activation.disposition else {
                            continue
                        }
                        activation.disposition = .released(
                            hostTime: releaseHostTime)
                        pendingActivation = activation
                        activation.task.cancel()
                        continue
                    }
                    guard let ownedSession = heldSession,
                        ownedSession.pressID == press.id
                    else { continue }
                    heldSession = nil
                    startCompletion(
                        ownedSession.sessionID,
                        releaseHostTime: releaseHostTime)
                case .transferHeldSession(let press, let completion):
                    if var activation = pendingActivation,
                        activation.press.id == press.id
                    {
                        switch activation.disposition {
                        case .held:
                            activation.disposition = .transferred(completion)
                            pendingActivation = activation
                        case .released, .transferred:
                            completion(nil)
                        }
                        continue
                    }
                    guard let ownedSession = heldSession,
                        ownedSession.pressID == press.id,
                        ownedSession.releaseBoundary === press.releaseBoundary
                    else {
                        completion(nil)
                        continue
                    }
                    heldSession = nil
                    completion(ownedSession)
                case .activationFinished(let id, let sessionID):
                    guard let activation = pendingActivation,
                        activation.id == id
                    else {
                        // A task that outlived driver shutdown must not retain a
                        // capture that no command state can subsequently own.
                        if let sessionID {
                            await pipeline.cancel(sessionID: sessionID)
                        }
                        continue
                    }
                    pendingActivation = nil

                    let acceptedSession = sessionID.map {
                        HotkeyHeldSession(
                            sessionID: $0,
                            releaseBoundary: activation.press.releaseBoundary,
                            pressID: activation.press.id)
                    }
                    switch activation.disposition {
                    case .held:
                        heldSession = acceptedSession
                    case .released(let releaseHostTime):
                        if let sessionID {
                            startCompletion(
                                sessionID,
                                releaseHostTime: releaseHostTime)
                        }
                    case .transferred(let completion):
                        completion(acceptedSession)
                    }
                    if let acceptedSession {
                        observationContinuation.yield(
                            .sessionAccepted(acceptedSession))
                    }
                    settleWorkBarriersIfIdle()
                case .completionFinished(let id):
                    completionTasks[id] = nil
                    settleWorkBarriersIfIdle()
                case .barrier(let barrier):
                    workBarriers.append(barrier)
                    settleWorkBarriersIfIdle()
                case .commandBarrier(let barrier):
                    barrier.resume()
                }
            }

            if let pendingActivation {
                if case .transferred(let completion) =
                    pendingActivation.disposition
                {
                    completion(nil)
                }
                pendingActivation.task.cancel()
                if let sessionID = await pendingActivation.task.value {
                    await pipeline.cancel(sessionID: sessionID)
                    observationContinuation.yield(.sessionEnded(sessionID))
                }
            }
            pendingActivation = nil
            if let heldSession {
                await pipeline.cancel(sessionID: heldSession.sessionID)
                observationContinuation.yield(
                    .sessionEnded(heldSession.sessionID))
            }
            for task in completionTasks.values {
                await task.value
            }
            completionTasks.removeAll()
            settleWorkBarriersIfIdle()
            observationContinuation.finish()
        }
    }

    deinit {
        invalidate()
    }

    public func submit(_ event: HotkeyEvent) {
        submit(event, hostTime: AudioCaptureReleaseFence.currentHostTime())
    }

    /// Submit a physical event whose timestamp is already in AVAudio Mach host
    /// time. The hotkey provider uses this path to preserve event-tap timing.
    public func submit(_ event: HotkeyEvent, hostTime: UInt64) {
        ingressLock.withLock {
            switch event {
            case .pressed:
                guard acceptsNewPresses, ingressPress == nil,
                    canAdmitPress(hostTime)
                else { return }
                let press = PhysicalPress(
                    id: UUID(),
                    releaseBoundary: AudioCaptureReleaseBoundary(
                        pressHostTime: hostTime))
                ingressPress = press
                continuation.yield(
                    .event(event, hostTime: hostTime, press: press))
            case .released:
                let press = ingressPress
                ingressPress = nil
                press?.releaseBoundary.publish(releaseHostTime: hostTime)
                continuation.yield(
                    .event(event, hostTime: hostTime, press: press))
            }
        }
    }

    /// Fence new physical presses without disturbing a press that already owns
    /// activation. Release events continue through this fence so availability
    /// changes cannot strand or cancel an accepted dictation.
    public func suspendNewPresses() {
        ingressLock.withLock {
            acceptsNewPresses = false
        }
    }

    /// Reopen physical-press admission after the external availability fence
    /// has fully cleared. Returns `false` after permanent invalidation.
    @discardableResult
    public func resumeNewPresses() -> Bool {
        ingressLock.withLock {
            guard !ingressTerminated else { return false }
            acceptsNewPresses = true
            return true
        }
    }

    /// Transfer release ownership to hands-free UI. Submission is synchronous,
    /// so a later physical release is ordered after the transfer request even
    /// when activation is still completing.
    @discardableResult
    public func transferHeldSession(
        _ completion: @escaping @Sendable (HotkeyHeldSession?) -> Void
    ) -> AudioCaptureReleaseBoundary? {
        var transferredBoundary: AudioCaptureReleaseBoundary?
        var terminated = false
        ingressLock.withLock {
            guard let press = ingressPress else { return }
            ingressPress = nil
            transferredBoundary = press.releaseBoundary
            let result = continuation.yield(
                .transferHeldSession(press, completion))
            if case .terminated = result {
                terminated = true
            }
        }
        if transferredBoundary == nil || terminated {
            completion(nil)
            return nil
        }
        return transferredBoundary
    }

    public func invalidate() {
        ingressLock.withLock {
            guard !ingressTerminated else { return }
            ingressTerminated = true
            acceptsNewPresses = false
            ingressPress?.releaseBoundary.publish(
                releaseHostTime: AudioCaptureReleaseFence.currentHostTime())
            ingressPress = nil
            continuation.finish()
        }
    }

    /// Wait until all commands submitted before this call and their tracked
    /// activation/completion work have settled. Internal so tests can
    /// synchronize without timing sleeps.
    func waitForSubmittedEvents() async {
        await withCheckedContinuation { barrier in
            let result = continuation.yield(.barrier(barrier))
            if case .terminated = result {
                barrier.resume()
            }
        }
    }

    /// Wait only for the serial command queue. Unlike
    /// `waitForSubmittedEvents()`, this does not wait for a pending activation
    /// to settle. Used by race tests to open a gate only after release has
    /// issued cancellation.
    func waitForSubmittedCommands() async {
        await withCheckedContinuation { barrier in
            let result = continuation.yield(.commandBarrier(barrier))
            if case .terminated = result {
                barrier.resume()
            }
        }
    }
}
