import AppKit
import Carbon.HIToolbox
import Foundation
import FreeFlowKit

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
    private var transcriptBuffer: TranscriptBuffer?
    private var textInjector: (any TextInjecting)?
    private var messageService: InAppMessageService?

    private var visualStateObservation: Task<Void, Never>?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var globalClickMonitor: Any?
    private var localPasteMonitor: Any?
    private var globalPasteMonitor: Any?
    private var localHandsfreeMonitor: Any?
    private var globalHandsfreeMonitor: Any?

    /// Called when the user dismisses a session-expired HUD to replace the
    /// credential while retaining the failed dictation's recovery audio.
    var onSessionExpired: (() -> Void)?

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
        transcriptBuffer: TranscriptBuffer? = nil,
        textInjector: (any TextInjecting)? = nil,
        messageService: InAppMessageService? = nil
    ) {
        self.coordinator = coordinator
        self.pipeline = pipeline
        self.audioDeviceProvider = audioDeviceProvider
        self.transcriptBuffer = transcriptBuffer
        self.textInjector = textInjector
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
        visualStateObservation?.cancel()
        visualStateObservation = nil
        removeEscapeMonitors()
        removeClickMonitor()
        removePasteShortcutMonitors()
        removeHandsfreeShortcutMonitors()
        viewModel.stop()
        hudWindow?.orderOut(nil)
        hudWindow = nil
    }

    // MARK: - Activation helpers

    /// Call when push-to-talk recording begins (hotkey held).
    func hotkeyHeld() {
        viewModel.hotkeyHeld()
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
        Task {
            await pipeline.cancel()
        }
    }

    /// Complete the current recording. Called from the ■ stop button.
    func completePipeline() {
        guard let pipeline else { return }
        Task {
            await pipeline.complete()
        }
    }

    /// Dismiss the no-target state and return to minimized.
    func dismissNoTarget() {
        viewModel.dismissNoTarget()
        guard let coordinator else { return }
        Task {
            await coordinator.reset()
        }
    }

    /// Re-attempt batch transcription of the saved complete recording.
    func retryDictation() {
        guard let pipeline else { return }
        Task {
            await pipeline.retryDictation()
        }
    }

    /// Discard the saved complete recording and return to minimized.
    func dismissDictationFailure() {
        viewModel.dismissDictationFailure()
        guard let pipeline else { return }
        Task {
            await pipeline.dismissDictationFailure()
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
        viewModel.clickedToStartHandsFree()
        guard let pipeline else { return }
        Task {
            await pipeline.activate()
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
            viewModel.clickedToStartHandsFree()
        case .listeningHandsFree:
            completePipeline()
        default:
            break
        }
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
        guard let transcriptBuffer, let textInjector else { return }

        // Dismiss the no-target hint if it is showing.
        if viewModel.visualState == .noTarget {
            viewModel.dismissNoTarget()
            guard let coordinator else { return }
            Task {
                await coordinator.reset()
            }
        }

        Task {
            guard let transcript = await transcriptBuffer.consume() else {
                Log.debug("[HUD] ⌃⌥V pressed but no transcript in buffer")
                return
            }

            // Read fresh context at the moment of paste.
            let context = await AXAppContextProvider().readContext()

            do {
                try await textInjector.inject(text: transcript, into: context)
                Log.debug("[HUD] ⌃⌥V pasted transcript (\(transcript.count) chars)")
            } catch {
                Log.debug("[HUD] ⌃⌥V paste failed: \(error)")
                // Re-store so the user can try again.
                await transcriptBuffer.store(transcript)
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
