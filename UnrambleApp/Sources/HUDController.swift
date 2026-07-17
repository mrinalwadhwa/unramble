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
    private var audioDeviceProvider: (any AudioDeviceProviding)?
    private var messageService: InAppMessageService?

    private var visualStateObservation: Task<Void, Never>?
    private var sessionOwnershipObservation: Task<Void, Never>?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var globalClickMonitor: Any?
    private var localPasteMonitor: Any?
    private var globalPasteMonitor: Any?
    private var localHandsfreeMonitor: Any?
    private var globalHandsfreeMonitor: Any?
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
        installPasteShortcutMonitors()
        installHandsfreeShortcutMonitors()

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
                let messageChanged = currentMessageID != previousMessageID
                previousMessageID = currentMessageID

                if screenChanged {
                    self.hudWindow?.repositionToCurrentScreen()
                }
                if current != previousState || messageChanged {
                    previousState = current
                    self.hudWindow?.animateToCurrentState()
                }
            }
        }
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
        removePasteShortcutMonitors()
        removeHandsfreeShortcutMonitors()
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
        let activationTask = Task {
            await pipeline.activate(releaseBoundary: releaseBoundary)
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

    /// Install local and global key event monitors for the hands-free
    /// toggle shortcut. Default is ⌘⇧H.
    ///
    /// When idle/minimized/ready, the shortcut starts hands-free dictation.
    /// When already in hands-free listening, the shortcut stops recording
    /// (completes the pipeline).
    private func installHandsfreeShortcutMonitors() {
        localHandsfreeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isHandsfreeShortcut(event) == true {
                self?.handleHandsfreeShortcut()
                return nil  // Consume the event.
            }
            return event
        }

        globalHandsfreeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isHandsfreeShortcut(event) == true {
                self?.handleHandsfreeShortcut()
            }
        }
    }

    private func removeHandsfreeShortcutMonitors() {
        if let monitor = localHandsfreeMonitor {
            NSEvent.removeMonitor(monitor)
            localHandsfreeMonitor = nil
        }
        if let monitor = globalHandsfreeMonitor {
            NSEvent.removeMonitor(monitor)
            globalHandsfreeMonitor = nil
        }
    }

    /// Check whether a key event matches the configured hands-free shortcut.
    private func isHandsfreeShortcut(_ event: NSEvent) -> Bool {
        let binding = Settings.shared.handsfreeShortcutBinding
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return binding.matches(keyCode: event.keyCode, modifierFlags: flags.rawValue)
    }

    /// Toggle hands-free dictation on or off.
    ///
    /// Also handles the case where the hotkey provider started
    /// push-to-talk (listeningHeld) because the handsfree shortcut
    /// shares a modifier key with the dictate hotkey. In that case
    /// we switch to hands-free mode so the user doesn't have to
    /// keep holding.
    private func handleHandsfreeShortcut() {
        switch viewModel.visualState {
        case .minimized, .ready:
            startHandsFreeFromClick()
        case .listeningHeld:
            // The hotkey provider started push-to-talk because the
            // handsfree combo shares a modifier with the dictate key.
            // Switch to hands-free so the user can release the keys.
            let transferToken = UUID()
            heldSessionTransferToken = transferToken
            heldSessionTransferPending = true
            pendingHeldModeSessionID = nil
            viewModel.clickedToStartHandsFree()
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
                    let isStillOwned = await pipeline.currentSessionID
                        == sessionID
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
                return
            }
            handsFreeReleaseBoundary = transferredBoundary
        case .listeningHandsFree:
            completePipeline()
        default:
            break
        }
    }

    private func publishOwnedReleaseBoundary(
        atHostTime hostTime: UInt64 = mach_absolute_time()
    ) {
        handsFreeReleaseBoundary?.publish(releaseHostTime: hostTime)
        hotkeyHeldSession?.releaseBoundary.publish(releaseHostTime: hostTime)
    }

    // MARK: - Paste shortcut handling

    /// Install local and global key event monitors for the paste shortcut.
    ///
    /// The shortcut binding is read from Settings so it updates when the
    /// user changes it in the settings screen. Default is ⌃⌥V.
    ///
    /// When the HUD is in the no-target state, the paste shortcut lets the
    /// user select a text field and paste the buffered transcript without
    /// re-dictating. The shortcut also works when no-target is not showing,
    /// as a general "paste last transcript" action.
    private func installPasteShortcutMonitors() {
        localPasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isPasteShortcut(event) == true {
                self?.handlePasteShortcut()
                return nil  // Consume the event.
            }
            return event
        }

        globalPasteMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isPasteShortcut(event) == true {
                self?.handlePasteShortcut()
            }
        }
    }

    private func removePasteShortcutMonitors() {
        if let monitor = localPasteMonitor {
            NSEvent.removeMonitor(monitor)
            localPasteMonitor = nil
        }
        if let monitor = globalPasteMonitor {
            NSEvent.removeMonitor(monitor)
            globalPasteMonitor = nil
        }
    }

    /// Check whether a key event matches the configured paste shortcut.
    ///
    /// Reads the current binding from Settings so changes made in the
    /// settings screen take effect immediately without restarting.
    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        let binding = Settings.shared.pasteShortcutBinding
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return binding.matches(keyCode: event.keyCode, modifierFlags: flags.rawValue)
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
        case .minimized, .ready, .listeningHeld, .processingCollapsing, .processingBreathing:
            return false
        }
    }

    deinit {
        visualStateObservation?.cancel()
        if let monitor = localHandsfreeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalHandsfreeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localPasteMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalPasteMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
