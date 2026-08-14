import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import UnrambleKit

/// Drive the HUD overlay window based on pipeline state and UI-local signals.
///
/// `HUDController` observes `RecordingCoordinator.stateStream` and combines it
/// with hover, activation mode, and slow-processing timer (via `HUDViewModel`)
/// to produce the current `HUDVisualState`. It owns the `HUDOverlayWindow`
/// lifecycle and wires cancel/complete buttons to the pipeline.
@MainActor
final class HUDController {

    private var hudWindow: HUDOverlayWindow?
    let viewModel: HUDViewModel

    private weak var coordinator: RecordingCoordinator?
    private weak var pipeline: DictationPipeline?
    private weak var readAloudCoordinator: ReadAloudCoordinator?
    private weak var conversationCallCoordinator: ConversationCallCoordinator?
    private var audioDeviceProvider: (any AudioDeviceProviding)?
    private var messageService: InAppMessageService?

    private var visualStateObservation: Task<Void, Never>?
    private var sessionOwnershipObservation: Task<Void, Never>?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var globalClickMonitor: Any?
    private let handsfreeHotkeyProvider = CarbonHotkeyProvider()
    private let pasteHotkeyProvider = CarbonHotkeyProvider()
    private let handsfreeSessionHotkeyProviders = [
        CarbonHotkeyProvider(),
        CarbonHotkeyProvider(),
        CarbonHotkeyProvider(),
    ]
    private var handsfreeSessionShortcutsRegistered = false
    private let callSessionHotkeyProvider = CarbonHotkeyProvider()
    private var callSessionShortcutRegistered = false
    private var handsfreeStopOnShortcutRelease = false
    private var currentSessionID: DictationSessionID?
    private var latestSessionUpdate: RecordingStateUpdate?
    private var sessionObservationRevision: UInt64 = 0
    private var pendingHeldModeSessionID: DictationSessionID?
    private var handsFreeActivationTask: Task<DictationSessionID?, Never>?
    private var handsFreeActivationToken: UUID?
    private var handsFreeOwnedSessionID: DictationSessionID?
    private var handsFreeReleaseBoundary: AudioCaptureReleaseBoundary?
    private var hotkeyHeldSession: HotkeyHeldSession?
    private var heldSessionTransferPending = false
    private var heldSessionTransferToken: UUID?

    /// Called when the user dismisses a session-expired HUD to replace the
    /// credential while retaining the failed dictation's recovery audio.
    var onSessionExpired: (() -> Void)?

    /// Transfer a push-to-talk session to hands-free ownership before the
    /// shared physical key release reaches the input driver.
    var onTransferHeldHotkeySession:
        ((@escaping @Sendable (HotkeyHeldSession?) -> Void)
            -> AudioCaptureReleaseBoundary?)?

    // MARK: - Init

    init(
        shortcuts: ShortcutConfiguration = .default
    ) {
        self.viewModel = HUDViewModel(
            shortcuts: shortcuts
        )
        setupViewModelActions()
    }

    // MARK: - Lifecycle

    /// Begin observing the coordinator and pipeline to drive the HUD.
    func start(
        coordinator: RecordingCoordinator,
        pipeline: DictationPipeline? = nil,
        audioDeviceProvider: (any AudioDeviceProviding)? = nil,
        audioProvider: (any AudioProviding)? = nil,
        messageService: InAppMessageService? = nil
    ) {
        self.coordinator = coordinator
        self.pipeline = pipeline
        self.audioDeviceProvider = audioDeviceProvider
        self.messageService = messageService
        viewModel.setMessageService(messageService)

        // Wire audio provider for live level metering.
        viewModel.setAudioProvider(audioProvider)

        // Seed the view model with the current mic name.
        if let provider = audioDeviceProvider {
            Task {
                let device = await provider.currentDevice()
                self.viewModel.activeMicName = device?.name
            }
        }

        viewModel.observe(coordinator: coordinator)
        sessionOwnershipObservation?.cancel()
        sessionOwnershipObservation = Task { [weak self] in
            for await update in await coordinator.sessionStateStream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                self.sessionObservationRevision &+= 1
                let observationRevision = self.sessionObservationRevision
                self.latestSessionUpdate = update

                if update.state == .idle,
                    let sessionID = update.sessionID
                {
                    self.sessionEnded(sessionID)
                } else if let sessionID = update.sessionID {
                    self.currentSessionID = sessionID
                    self.applyPendingHeldModeIfCurrentRecording(update)
                }

                guard update.state == .dictationFailed,
                    let pipeline = self.pipeline,
                    let sessionID = update.sessionID,
                    await pipeline.currentSessionID == sessionID
                else {
                    self.viewModel.setDictationRetryAvailable(false)
                    continue
                }

                let canRetry = await pipeline.canRetryDictation(
                    sessionID: sessionID)
                if self.sessionObservationRevision == observationRevision,
                    self.latestSessionUpdate == update,
                    await pipeline.currentSessionID == sessionID,
                    await pipeline.state == .dictationFailed
                {
                    self.viewModel.setDictationRetryAvailable(canRetry)
                }
            }
        }
        ensureWindow()

        installEscapeMonitors()
        installClickMonitor()
        registerPasteShortcut()
        registerHandsfreeShortcut()

        // Watch visual state changes, mouse screen, and hover to animate
        // the window. Hover detection is done here via global mouse
        // position polling because NSTrackingArea is unreliable on
        // transparent non-activating panels with large invisible regions.
        visualStateObservation?.cancel()
        visualStateObservation = Task { [weak self] in
            var previousState: HUDVisualState?
            var previousScreenFrame: NSRect?
            var wasHovering = false
            var previousMessageID: String?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)  // ~60fps
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let mouseLocation = NSEvent.mouseLocation

                // Detect if the mouse moved to a different screen.
                let currentScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
                let currentScreenFrame = currentScreen?.frame
                let screenChanged = currentScreenFrame != previousScreenFrame
                if screenChanged {
                    previousScreenFrame = currentScreenFrame
                }

                // Hover detection: check if the mouse is over the visible
                // content region (capsule when minimized, full pill when
                // expanded). This replaces NSTrackingArea.
                let isOverContent =
                    self.hudWindow?.isMouseOverVisibleContent(mouseLocation) ?? false
                if isOverContent && !wasHovering {
                    wasHovering = true
                    self.viewModel.mouseEntered()
                } else if !isOverContent && wasHovering {
                    wasHovering = false
                    self.viewModel.mouseExited()
                }

                let current = self.viewModel.visualState
                let currentMessageID = self.viewModel.inAppMessage?.id
                let stateChanged = current != previousState
                let messageChanged = currentMessageID != previousMessageID
                previousMessageID = currentMessageID
                if stateChanged {
                    self.syncHandsfreeSessionShortcuts(for: current)
                    self.syncCallSessionShortcut(for: current)
                }

                if screenChanged {
                    self.hudWindow?.repositionToCurrentScreen()
                }
                if stateChanged || messageChanged {
                    previousState = current
                    self.hudWindow?.animateToCurrentState()
                }
            }
        }
    }

    /// Begin observing a read-aloud coordinator to drive the HUD's read
    /// states. The coordinator is built on first use, so this may run
    /// before or after `start`.
    func attachReadAloud(_ coordinator: ReadAloudCoordinator) {
        readAloudCoordinator = coordinator
        viewModel.observeReadAloud(coordinator: coordinator)
    }

    /// Begin observing a conversation-call coordinator to drive the
    /// HUD's call states. The coordinator is built on first use, so
    /// this may run before or after `start`.
    func attachConversationCall(_ coordinator: ConversationCallCoordinator) {
        conversationCallCoordinator = coordinator
        viewModel.observeConversationCall(coordinator: coordinator)
    }

    /// Stop observing and remove the HUD from screen.
    func stop() {
        let pendingActivation = handsFreeActivationTask
        let pendingActivationPipeline = pipeline
        handsFreeReleaseBoundary?.publish(releaseHostTime: mach_absolute_time())
        hotkeyHeldSession?.releaseBoundary.publish(
            releaseHostTime: mach_absolute_time())
        pendingActivation?.cancel()
        if let pendingActivation, let pendingActivationPipeline {
            Task {
                if let sessionID = await pendingActivation.value {
                    await pendingActivationPipeline.cancel(sessionID: sessionID)
                }
            }
        }
        visualStateObservation?.cancel()
        visualStateObservation = nil
        sessionOwnershipObservation?.cancel()
        sessionOwnershipObservation = nil
        removeEscapeMonitors()
        removeClickMonitor()
        pasteHotkeyProvider.unregister()
        handsfreeHotkeyProvider.unregister()
        handsfreeStopOnShortcutRelease = false
        unregisterHandsfreeSessionShortcuts()
        unregisterCallSessionShortcut()
        conversationCallCoordinator = nil
        handsFreeActivationToken = nil
        handsFreeActivationTask = nil
        handsFreeOwnedSessionID = nil
        handsFreeReleaseBoundary = nil
        hotkeyHeldSession = nil
        pendingHeldModeSessionID = nil
        latestSessionUpdate = nil
        sessionObservationRevision &+= 1
        invalidateHeldSessionTransfer()
        currentSessionID = nil
        readAloudCoordinator = nil
        viewModel.stop()
        hudWindow?.orderOut(nil)
        hudWindow = nil
    }

    // MARK: - Activation helpers

    /// Hint that the input driver accepted this exact push-to-talk session.
    /// The coordinator stream remains authoritative: a delayed hint is applied
    /// only while the same session is visibly recording.
    func hotkeySessionAccepted(_ heldSession: HotkeyHeldSession) {
        let sessionID = heldSession.sessionID
        guard !heldSessionTransferPending,
            handsFreeOwnedSessionID == nil,
            handsFreeActivationTask == nil
        else { return }
        hotkeyHeldSession = heldSession

        guard let latestSessionUpdate else {
            pendingHeldModeSessionID = sessionID
            return
        }

        if latestSessionUpdate.state == .recording,
            latestSessionUpdate.sessionID == sessionID
        {
            pendingHeldModeSessionID = nil
            currentSessionID = sessionID
            viewModel.hotkeyHeld()
        } else if latestSessionUpdate.state == .idle,
            latestSessionUpdate.sessionID != sessionID
        {
            pendingHeldModeSessionID = sessionID
        } else if pendingHeldModeSessionID == sessionID {
            pendingHeldModeSessionID = nil
        }
    }

    private func applyPendingHeldModeIfCurrentRecording(
        _ update: RecordingStateUpdate
    ) {
        guard let pendingSessionID = pendingHeldModeSessionID else { return }
        guard update.state == .recording,
            update.sessionID == pendingSessionID,
            !heldSessionTransferPending,
            handsFreeOwnedSessionID == nil,
            handsFreeActivationTask == nil
        else {
            pendingHeldModeSessionID = nil
            return
        }
        pendingHeldModeSessionID = nil
        viewModel.hotkeyHeld()
    }

    func sessionEnded(_ sessionID: DictationSessionID) {
        if pendingHeldModeSessionID == sessionID {
            pendingHeldModeSessionID = nil
        }
        let endedOwnedSession = currentSessionID == sessionID
            || handsFreeOwnedSessionID == sessionID
        if currentSessionID == sessionID {
            currentSessionID = nil
        }
        if handsFreeOwnedSessionID == sessionID {
            handsFreeOwnedSessionID = nil
        }
        if hotkeyHeldSession?.sessionID == sessionID {
            hotkeyHeldSession = nil
        }
        if endedOwnedSession {
            handsFreeReleaseBoundary = nil
        }
        if endedOwnedSession {
            invalidateHeldSessionTransfer()
            viewModel.setDictationRetryAvailable(false)
        }
    }

    private func invalidateHeldSessionTransfer() {
        heldSessionTransferToken = nil
        heldSessionTransferPending = false
    }

    // MARK: - Pipeline actions

    /// Notify the view model that the user switched microphones and refresh
    /// the active mic name. Called from the menu bar after `selectDevice`.
    func microphoneSwitched() {
        viewModel.requestMicCallout()
        if let provider = audioDeviceProvider {
            Task {
                let device = await provider.currentDevice()
                self.viewModel.activeMicName = device?.name
            }
        }
    }

    /// Show whether a new dictation can be admitted yet.
    func setDictationReadiness(_ readiness: HUDDictationReadiness) {
        viewModel.setDictationReadiness(readiness)
    }

    /// Cancel the current pipeline operation. Called from ✕ buttons and Escape.
    func cancelPipeline() {
        guard let pipeline else { return }
        publishOwnedReleaseBoundary()
        invalidateHeldSessionTransfer()
        pendingHeldModeSessionID = nil
        let capturedSessionID = viewModel.pipelineSessionID ?? currentSessionID
        let activationTask = handsFreeActivationTask
        activationTask?.cancel()
        handsFreeActivationTask = nil
        handsFreeActivationToken = nil
        handsFreeReleaseBoundary = nil
        Task {
            var sessionID = capturedSessionID
            if sessionID == nil {
                sessionID = await activationTask?.value
            }
            guard let sessionID else { return }
            await pipeline.cancel(sessionID: sessionID)
            if self.currentSessionID == sessionID {
                self.currentSessionID = nil
            }
            if self.handsFreeOwnedSessionID == sessionID {
                self.handsFreeOwnedSessionID = nil
            }
        }
    }

    /// Complete the current recording. Called from the ■ stop button.
    func completePipeline() {
        guard let pipeline else { return }
        let releaseHostTime = mach_absolute_time()
        publishOwnedReleaseBoundary(atHostTime: releaseHostTime)
        invalidateHeldSessionTransfer()
        let capturedSessionID = viewModel.pipelineSessionID ?? currentSessionID
        let activationTask = handsFreeActivationTask
        handsFreeActivationTask = nil
        handsFreeActivationToken = nil
        handsFreeReleaseBoundary = nil
        Task {
            var sessionID = capturedSessionID
            if sessionID == nil {
                sessionID = await activationTask?.value
            }
            guard let sessionID else { return }
            await pipeline.complete(
                sessionID: sessionID,
                releaseHostTime: releaseHostTime)
            let remainingSessionID = await pipeline.currentSessionID
            if remainingSessionID != sessionID,
                self.currentSessionID == sessionID
            {
                self.currentSessionID = nil
            }
            if self.handsFreeOwnedSessionID == sessionID {
                self.handsFreeOwnedSessionID = nil
            }
        }
    }

    /// Dismiss the no-target state and return to minimized.
    func dismissNoTarget() {
        guard let pipeline, let sessionID = viewModel.pipelineSessionID else {
            return
        }
        Task {
            await pipeline.dismissInjectionFailure(sessionID: sessionID)
            if await pipeline.currentSessionID != sessionID {
                self.sessionEnded(sessionID)
            }
        }
    }

    /// Re-attempt batch transcription of the saved complete recording.
    func retryDictation() {
        guard let pipeline, let sessionID = viewModel.pipelineSessionID else {
            return
        }
        Task {
            await pipeline.retryDictation(sessionID: sessionID)
            if await pipeline.currentSessionID != sessionID {
                self.sessionEnded(sessionID)
            }
        }
    }

    // MARK: - Read-aloud actions

    /// Stop the read session. Called from the ■ button and Escape; the
    /// read hotkey and dictation start stop it through the app delegate.
    private func stopReading() {
        guard let readAloudCoordinator else { return }
        Task { await readAloudCoordinator.stop() }
    }

    /// Dismiss the no-content guidance. Called from ✕, Escape, click, and
    /// the view model's auto-dismiss timer.
    private func dismissReadingGuidance() {
        guard let readAloudCoordinator else { return }
        Task { await readAloudCoordinator.dismissGuidance() }
    }

    // MARK: - Conversation-call actions

    /// Hang up the call. Called from the hang-up button and Escape;
    /// the call shortcut hangs up through the app delegate.
    private func hangUpCall() {
        guard let conversationCallCoordinator else { return }
        Task { await conversationCallCoordinator.hangUp() }
    }

    /// Send the listening call turn immediately, like the dictation
    /// key does, instead of waiting out the pause.
    private func sendCallTurn() {
        guard let conversationCallCoordinator else { return }
        Task { await conversationCallCoordinator.sendNow() }
    }

    /// Stop the spoken reply and open the mic — the mouse twin of
    /// the Right Option barge-in.
    private func interruptCallSpeech() {
        guard let conversationCallCoordinator else { return }
        Task { await conversationCallCoordinator.bargeIn() }
    }

    /// Dismiss the no-agent guidance. Called from ✕, Escape, and the
    /// view model's auto-dismiss timer.
    private func dismissCallGuidance() {
        guard let conversationCallCoordinator else { return }
        Task { await conversationCallCoordinator.dismissGuidance() }
    }

    /// Discard the saved complete recording and return to minimized.
    func dismissDictationFailure() {
        guard let pipeline, let sessionID = viewModel.pipelineSessionID else {
            return
        }
        Task {
            await pipeline.dismissDictationFailure(sessionID: sessionID)
            if await pipeline.currentSessionID != sessionID {
                self.sessionEnded(sessionID)
            }
        }
    }

    // MARK: - View model wiring

    private func setupViewModelActions() {
        viewModel.onCancel = { [weak self] in
            self?.cancelPipeline()
        }
        viewModel.onStop = { [weak self] in
            self?.completePipeline()
        }
        viewModel.onDismiss = { [weak self] in
            guard let self else { return }
            switch self.viewModel.visualState {
            case .dictationFailed:
                self.dismissDictationFailure()
            default:
                self.dismissNoTarget()
            }
        }
        viewModel.onClickToRecord = { [weak self] in
            self?.startHandsFreeFromClick()
        }
        viewModel.onRetryDictation = { [weak self] in
            self?.retryDictation()
        }
        viewModel.onStopReading = { [weak self] in
            self?.stopReading()
        }
        viewModel.onDismissReadingGuidance = { [weak self] in
            self?.dismissReadingGuidance()
        }
        viewModel.onHangUpCall = { [weak self] in
            self?.hangUpCall()
        }
        viewModel.onSendCallTurn = { [weak self] in
            self?.sendCallTurn()
        }
        viewModel.onInterruptCallSpeech = { [weak self] in
            self?.interruptCallSpeech()
        }
        viewModel.onDismissCallGuidance = { [weak self] in
            self?.dismissCallGuidance()
        }
        viewModel.onMessageTapped = { [weak self] message in
            if let urlString = message.url, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            self?.messageService?.markDismissed(message.id)
        }
        viewModel.onMessageDismissed = { [weak self] message in
            self?.messageService?.markDismissed(message.id)
        }
    }

    // MARK: - Window lifecycle

    private func ensureWindow() {
        guard hudWindow == nil else { return }
        hudWindow = HUDOverlayWindow(viewModel: viewModel)
    }

    /// Start hands-free dictation from a click on the minimized/ready HUD.
    private func startHandsFreeFromClick() {
        guard viewModel.dictationReadiness == .ready else {
            Log.debug(
                "[HUDController] Ignoring hands-free activation while "
                    + "dictation startup is not ready")
            return
        }
        guard handsFreeActivationTask == nil,
            handsFreeOwnedSessionID == nil,
            currentSessionID == nil
        else { return }
        viewModel.clickedToStartHandsFree()
        guard let pipeline else { return }
        let token = UUID()
        let releaseBoundary = AudioCaptureReleaseBoundary()
        handsFreeActivationToken = token
        handsFreeReleaseBoundary = releaseBoundary
        currentSessionID = nil
        let readAloud = readAloudCoordinator
        let activationTask = Task { () -> DictationSessionID? in
            // A read session may be running invisibly (its processing
            // state only shows 300ms after the press). Stop it before
            // capture so synthesized speech never overlaps the
            // microphone; a no-op when no session exists.
            if let readAloud {
                await readAloud.stop()
            }
            return await pipeline.activate(releaseBoundary: releaseBoundary)
        }
        handsFreeActivationTask = activationTask
        Task { [weak self] in
            let sessionID = await activationTask.value
            guard let self, self.handsFreeActivationToken == token else {
                return
            }
            self.handsFreeActivationTask = nil
            self.handsFreeActivationToken = nil
            if let sessionID {
                self.currentSessionID = sessionID
                self.handsFreeOwnedSessionID = sessionID
            } else if self.handsFreeReleaseBoundary === releaseBoundary {
                self.handsFreeReleaseBoundary = nil
            }
        }
    }

    // MARK: - Click-to-record monitor

    /// Install a global mouse click monitor that detects clicks on the
    /// HUD pill. Needed because the window has `ignoresMouseEvents = true`
    /// in minimized, ready, and noTarget states so clicks pass through
    /// to apps behind.
    private func installClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self else { return }
            let state = self.viewModel.visualState
            let mouseLocation = NSEvent.mouseLocation
            guard self.hudWindow?.isMouseOverVisibleContent(mouseLocation) == true else { return }

            switch state {
            case .minimized, .ready:
                self.startHandsFreeFromClick()
            case .noTarget:
                self.dismissNoTarget()
            case .readingNoContent:
                self.dismissReadingGuidance()
            default:
                break
            }
        }
    }

    private func removeClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    // MARK: - Hands-free shortcut handling

    /// Register the hands-free toggle through the macOS global hotkey API.
    ///
    /// When idle/minimized/ready, the shortcut starts hands-free dictation.
    /// When already in hands-free listening, the shortcut stops recording
    /// (completes the pipeline).
    private func registerHandsfreeShortcut() {
        let binding = Settings.shared.handsfreeShortcutBinding
        let setting = HotkeySetting.modifierPlusKey(
            modifierFlags: binding.standardModifierFlags,
            keyCode: binding.keyCode,
            keyName: binding.label)

        handsfreeStopOnShortcutRelease = false
        handsfreeHotkeyProvider.unregister()
        do {
            try handsfreeHotkeyProvider.register(with: setting) {
                [weak self] event in
                Task { @MainActor [weak self] in
                    switch event {
                    case .pressed:
                        self?.handleHandsfreeShortcut()
                    case .released:
                        self?.handleHandsfreeShortcutRelease()
                    }
                }
            }
            Log.debug(
                "[HUDController] Hands-free shortcut registered (\(binding.label))")
        } catch {
            handsfreeHotkeyProvider.unregister()
            Log.debug(
                "[HUDController] Failed to register hands-free shortcut: \(error)")
        }
    }

    /// Apply a Settings change without rebuilding the HUD.
    func reRegisterHandsfreeShortcut() {
        registerHandsfreeShortcut()
    }

    /// Toggle hands-free dictation on or off.
    ///
    /// Also handles the case where the hotkey provider started
    /// push-to-talk (listeningHeld) because the handsfree shortcut
    /// shares a modifier key with the dictate hotkey. In that case
    /// we switch to hands-free mode so the user doesn't have to
    /// keep holding.
    func handleHandsfreeShortcut() {
        // A call owns the microphone and the speech channel; the
        // hands-free toggle is ignored until hangup restores the
        // pre-call state.
        guard !viewModel.visualState.isCallState else { return }
        Log.debug(
            "[HUDController] Hands-free shortcut pressed (state=\(viewModel.visualState))")
        if viewModel.visualState != .listeningHandsFree {
            handsfreeStopOnShortcutRelease = false
        }
        switch viewModel.visualState {
        case .minimized, .ready:
            // Right Option activation is asynchronous. Space can arrive before
            // the coordinator has published `listeningHeld`, so ask the
            // input driver for the pending held session before starting a
            // separate hands-free activation.
            if !transferHeldSessionToHandsFree() {
                startHandsFreeFromClick()
            }
        case .listeningHeld:
            _ = transferHeldSessionToHandsFree()
        case .listeningHandsFree:
            handsfreeStopOnShortcutRelease = true
        case .readingProcessing, .readingSpeaking, .readingNoContent:
            // The activation task stops the read session before capture,
            // which also clears no-content guidance.
            startHandsFreeFromClick()
        default:
            break
        }
    }

    /// Finish only after Option-Space is physically released so its Option
    /// modifier cannot alter the synthetic Command-V used for injection.
    private func handleHandsfreeShortcutRelease() {
        guard handsfreeStopOnShortcutRelease else { return }
        handsfreeStopOnShortcutRelease = false
        guard viewModel.visualState == .listeningHandsFree else { return }
        completePipeline()
    }

    /// Claim Return, keypad Enter, and Escape only while hands-free recording
    /// is active. Return accepts the recording; Escape cancels it.
    private func syncHandsfreeSessionShortcuts(for state: HUDVisualState) {
        guard state == .listeningHandsFree else {
            unregisterHandsfreeSessionShortcuts()
            return
        }
        guard !handsfreeSessionShortcutsRegistered else { return }

        let shortcuts: [(keyCode: UInt16, keyName: String, accepts: Bool)] = [
            (UInt16(kVK_Return), "Return", true),
            (UInt16(kVK_ANSI_KeypadEnter), "Keypad Enter", true),
            (UInt16(kVK_Escape), "Escape", false),
        ]
        handsfreeSessionShortcutsRegistered = true
        do {
            for (provider, shortcut) in zip(
                handsfreeSessionHotkeyProviders,
                shortcuts)
            {
                let setting = HotkeySetting.modifierPlusKey(
                    modifierFlags: 0,
                    keyCode: shortcut.keyCode,
                    keyName: shortcut.keyName)
                try provider.register(with: setting) { [weak self] event in
                    guard event == .pressed else { return }
                    Task { @MainActor [weak self] in
                        if shortcut.accepts {
                            self?.acceptHandsfreeRecording()
                        } else {
                            self?.cancelHandsfreeRecording()
                        }
                    }
                }
            }
            Log.debug(
                "[HUDController] Return accepts and Escape cancels hands-free recording")
        } catch {
            unregisterHandsfreeSessionShortcuts()
            Log.debug(
                "[HUDController] Failed to register hands-free session shortcuts: \(error)")
        }
    }

    private func acceptHandsfreeRecording() {
        guard viewModel.visualState == .listeningHandsFree else { return }
        unregisterHandsfreeSessionShortcuts()
        completePipeline()
    }

    private func cancelHandsfreeRecording() {
        guard viewModel.visualState == .listeningHandsFree else { return }
        unregisterHandsfreeSessionShortcuts()
        cancelPipeline()
    }

    private func unregisterHandsfreeSessionShortcuts() {
        guard handsfreeSessionShortcutsRegistered else { return }
        for provider in handsfreeSessionHotkeyProviders {
            provider.unregister()
        }
        handsfreeSessionShortcutsRegistered = false
    }

    /// Claim Escape only while a call is active, so hanging up never
    /// leaks an Escape keystroke into the agent's terminal.
    private func syncCallSessionShortcut(for state: HUDVisualState) {
        guard state.isCallState else {
            unregisterCallSessionShortcut()
            return
        }
        guard !callSessionShortcutRegistered else { return }
        callSessionShortcutRegistered = true
        do {
            let setting = HotkeySetting.modifierPlusKey(
                modifierFlags: 0,
                keyCode: UInt16(kVK_Escape),
                keyName: "Escape")
            try callSessionHotkeyProvider.register(with: setting) {
                [weak self] event in
                guard event == .pressed else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.viewModel.visualState == .callNoAgent {
                        self.dismissCallGuidance()
                    } else if self.viewModel.visualState.isCallState {
                        self.hangUpCall()
                    }
                }
            }
        } catch {
            unregisterCallSessionShortcut()
            Log.debug(
                "[HUDController] Failed to register call Escape: \(error)")
        }
    }

    private func unregisterCallSessionShortcut() {
        guard callSessionShortcutRegistered else { return }
        callSessionHotkeyProvider.unregister()
        callSessionShortcutRegistered = false
    }

    /// Transfer a held or still-activating Right Option session to the HUD.
    /// Returns false when no push-to-talk press is currently owned, allowing
    /// a plain Option-Space chord to start a fresh hands-free session instead.
    private func transferHeldSessionToHandsFree() -> Bool {
        let transferToken = UUID()
        heldSessionTransferToken = transferToken
        heldSessionTransferPending = true
        pendingHeldModeSessionID = nil
        let pipeline = pipeline
        let transferredBoundary = onTransferHeldHotkeySession? {
            [weak self, pipeline] transferredSession in
            Task { @MainActor in
                guard let self,
                    self.heldSessionTransferToken == transferToken
                else { return }
                guard let transferredSession, let pipeline else {
                    self.invalidateHeldSessionTransfer()
                    return
                }
                let sessionID = transferredSession.sessionID
                let isStillOwned = await pipeline.currentSessionID == sessionID
                guard self.heldSessionTransferToken == transferToken else {
                    return
                }
                self.invalidateHeldSessionTransfer()
                guard isStillOwned else { return }
                self.currentSessionID = sessionID
                self.handsFreeOwnedSessionID = sessionID
                self.hotkeyHeldSession = transferredSession
            }
        }
        guard let transferredBoundary else {
            invalidateHeldSessionTransfer()
            return false
        }
        viewModel.clickedToStartHandsFree()
        handsFreeReleaseBoundary = transferredBoundary
        return true
    }

    private func publishOwnedReleaseBoundary(
        atHostTime hostTime: UInt64 = mach_absolute_time()
    ) {
        handsFreeReleaseBoundary?.publish(releaseHostTime: hostTime)
        hotkeyHeldSession?.releaseBoundary.publish(releaseHostTime: hostTime)
    }

    // MARK: - Paste shortcut handling

    /// Claim Paste Last Dictation as a Carbon hotkey so the foreground app
    /// does not also interpret the configured chord.
    private func registerPasteShortcut() {
        let binding = Settings.shared.pasteShortcutBinding
        let setting = HotkeySetting.modifierPlusKey(
            modifierFlags: binding.standardModifierFlags,
            keyCode: binding.keyCode,
            keyName: binding.label)

        pasteHotkeyProvider.unregister()
        do {
            try pasteHotkeyProvider.register(with: setting) {
                [weak self] event in
                // Wait until the user releases Control/Shift/V before
                // synthesizing Command-V. Firing on key-down leaves the
                // shortcut modifiers physically held, so the foreground app
                // receives a modified paste chord instead of plain Command-V.
                guard event == .released else { return }
                Task { @MainActor [weak self] in
                    self?.handlePasteShortcut()
                }
            }
            Log.debug(
                "[HUDController] Paste shortcut registered (\(binding.label))")
        } catch {
            pasteHotkeyProvider.unregister()
            Log.debug(
                "[HUDController] Failed to register paste shortcut: \(error)")
        }
    }

    /// Apply a Settings change without rebuilding the HUD.
    func reRegisterPasteShortcut() {
        registerPasteShortcut()
    }

    /// Paste the buffered transcript into the currently focused text field.
    private func handlePasteShortcut() {
        guard let pipeline else { return }
        let capturedSessionID = currentSessionID

        Task {
            await pipeline.pasteBufferedTranscript()
            if let capturedSessionID,
                await pipeline.currentSessionID != capturedSessionID
            {
                self.sessionEnded(capturedSessionID)
            }
        }
    }

    // MARK: - Escape key handling

    /// Install local and global key event monitors to handle Escape.
    ///
    /// A local monitor catches Escape when the app is frontmost. A global
    /// monitor catches Escape when another app is frontmost (the typical
    /// case — the user is dictating into another app). Both route to
    /// `handleEscape()` which checks the current visual state.
    private func installEscapeMonitors() {
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                if self?.handleEscape() == true {
                    return nil  // Consume the event.
                }
            }
            return event
        }

        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.handleEscape()
            }
        }
    }

    private func removeEscapeMonitors() {
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            localEscapeMonitor = nil
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeMonitor = nil
        }
    }

    /// Route Escape to the appropriate action based on the current visual state.
    ///
    /// - Returns: `true` if Escape was handled (the event should be consumed).
    @discardableResult
    private func handleEscape() -> Bool {
        switch viewModel.visualState {
        case .listeningHandsFree:
            cancelPipeline()
            return true
        case .processingSlow:
            cancelPipeline()
            return true
        case .noTarget:
            dismissNoTarget()
            return true
        case .sessionExpired:
            onSessionExpired?()
            return true
        case .dictationFailed:
            dismissDictationFailure()
            return true
        case .dictationPreparing:
            return false
        case .readingProcessing, .readingSpeaking:
            stopReading()
            return true
        case .readingNoContent:
            dismissReadingGuidance()
            return true
        case .callListening, .callWaiting, .callSpeaking:
            hangUpCall()
            return true
        case .callNoAgent:
            dismissCallGuidance()
            return true
        case .minimized, .ready, .listeningHeld, .processingCollapsing,
            .processingBreathing:
            return false
        }
    }

    deinit {
        visualStateObservation?.cancel()
        handsfreeHotkeyProvider.unregister()
        pasteHotkeyProvider.unregister()
        for provider in handsfreeSessionHotkeyProviders {
            provider.unregister()
        }
        callSessionHotkeyProvider.unregister()
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
