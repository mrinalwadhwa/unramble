import AVFoundation
import AppKit
import FreeFlowKit

/// Drive the local onboarding flow: API key entry, accessibility and
/// microphone permissions, mic selection, and a try-it dictation step.
///
/// The controller owns the OnboardingWindow and OnboardingBridge. It is
/// created by AppDelegate when no API key is configured and dismissed
/// when the user completes the flow.
@MainActor
final class OnboardingController {

    private let keychain: KeychainService

    private let bridge: OnboardingBridge
    private(set) var window: OnboardingWindow?

    /// Called when onboarding completes successfully. AppDelegate uses
    /// this to register the hotkey and transition to the active state.
    var onComplete: ((_ credentialedMode: DictationMode?) -> Void)?

    /// Called when the user needs to register the hotkey during the
    /// try-it onboarding step. AppDelegate wires this to its own
    /// registerHotkey method.
    var onRegisterHotkey: (() -> Void)?

    /// Called when a dictation result should be pushed to the try-it
    /// screen. AppDelegate wires the pipeline to call this.
    var onDictationResult: ((_ text: String) -> Void)?

    /// The accessibility permission provider, set by AppDelegate.
    var permissionProvider: (any PermissionProviding)?

    /// The audio device provider for mic selection, set by AppDelegate.
    var audioDeviceProvider: CoreAudioDeviceProvider?

    /// Shared owner of microphone preview demand, set by AppDelegate.
    var microphoneCaptureCoordinator: MicrophoneCaptureCoordinator?

    /// Polling timer for accessibility permission checks.
    private var accessibilityPollTimer: Timer?

    private var microphoneListTask: Task<Void, Never>?
    private var microphoneListGeneration: UInt64 = 0
    private var microphoneSelectionTask: Task<Void, Never>?
    private var microphoneSelectionGeneration: UInt64 = 0
    private var microphonePreviewClient: MicrophonePreviewClient?
    private var isPreviewWindowSessionActive = false
    private var isPreviewCaptureAvailable = false

    /// API-key-only onboarding must not persist cloud mode until key storage
    /// succeeds. The requested mode is delivered with successful completion.
    private var isAPIKeyOnlyFlow = false
    private var credentialedMode: DictationMode?

    // MARK: - Initialization

    init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
        self.bridge = OnboardingBridge()

        setupBridgeHandlers()
    }

    // MARK: - Window management

    /// Open the onboarding window showing only the API key entry step.
    /// Used when toggling off private mode without a stored key.
    func showAPIKeyEntry() {
        dismissWindow()
        isPreviewWindowSessionActive = true
        isAPIKeyOnlyFlow = true
        credentialedMode = .cloud
        let win = OnboardingWindow(bridge: bridge)
        bridge.webView = win.webView
        window = win

        win.onClose = { [weak self, weak win] in
            guard let self, self.window === win else { return }
            self.dismissWindow()
        }

        win.onDidFinishNavigation = { [weak self] in
            self?.bridge.pushStepIcons()
        }
        win.loadBundledOnboarding(query: "mode=api-key-only")
        win.present()
    }

    /// Open the onboarding window and load the bundled onboarding page.
    func showWindow() {
        dismissWindow()
        isPreviewWindowSessionActive = true
        isAPIKeyOnlyFlow = false
        credentialedMode = nil
        // Always create a fresh window. The previous window's bridge
        // handler is removed on close/dismiss, so reusing it would
        // leave the JS bridge non-functional.
        let win = OnboardingWindow(bridge: bridge)
        bridge.webView = win.webView
        window = win

        win.onClose = { [weak self, weak win] in
            guard let self, self.window === win else { return }
            self.dismissWindow()
        }

        win.onDidFinishNavigation = { [weak self] in
            self?.bridge.pushOnboardingState()
            self?.bridge.pushStepIcons()
        }
        win.loadBundledOnboarding()
        win.present()
    }

    /// Dismiss the onboarding window and clean up.
    func dismissWindow() {
        isPreviewWindowSessionActive = false
        stopAccessibilityPolling()
        invalidateMicrophoneDeviceTasks()
        handleStopMicPreview()
        window?.dismiss()
        window = nil
    }

    // MARK: - Bridge action handlers

    private func setupBridgeHandlers() {
        bridge.onSetDictationMode = { [weak self] mode in
            self?.handleSetDictationMode(mode: mode)
        }

        bridge.onStoreAPIKey = { [weak self] key in
            self?.handleStoreAPIKey(key: key)
        }

        bridge.onCheckAccessibility = { [weak self] in
            self?.handleCheckAccessibility()
        }

        bridge.onOpenAccessibilitySettings = { [weak self] in
            self?.handleOpenAccessibilitySettings()
        }

        bridge.onRequestMicrophone = { [weak self] in
            self?.handleRequestMicrophone()
        }

        bridge.onListMicrophones = { [weak self] in
            self?.handleListMicrophones()
        }

        bridge.onSelectMicrophone = { [weak self] id in
            self?.handleSelectMicrophone(id: id)
        }

        bridge.onStartMicPreview = { [weak self] in
            self?.handleStartMicPreview()
        }

        bridge.onStopMicPreview = { [weak self] in
            self?.handleStopMicPreview()
        }

        bridge.onRegisterHotkey = { [weak self] in
            self?.handleRegisterHotkey()
        }

        bridge.onCompleteOnboarding = { [weak self] in
            self?.handleCompleteOnboarding()
        }

        // Wire dictation results back to the bridge.
        onDictationResult = { [weak self] text in
            self?.bridge.pushDictationResult(text: text)
        }
    }

    // MARK: - Action: storeAPIKey

    private func handleSetDictationMode(mode: String) {
        guard let newMode = DictationMode(rawValue: mode) else { return }
        if isAPIKeyOnlyFlow {
            credentialedMode = newMode
            return
        }
        Settings.shared.dictationMode = newMode
    }

    private func handleStoreAPIKey(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            bridge.pushAPIKeyStoreResult(error: "API key cannot be empty.")
            return
        }
        let saved = keychain.saveOpenAIAPIKey(trimmed)
        if saved {
            bridge.pushAPIKeyStoreResult()
        } else {
            bridge.pushAPIKeyStoreResult(error: "Failed to save API key to Keychain.")
        }
    }

    // MARK: - Action: listMicrophones

    private func handleListMicrophones() {
        guard let audioDeviceProvider else { return }
        microphoneListGeneration &+= 1
        let generation = microphoneListGeneration
        microphoneListTask?.cancel()
        microphoneListTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let devices = await audioDeviceProvider.availableDevices()
            guard !Task.isCancelled else { return }
            let current = await audioDeviceProvider.currentDevice()
            guard !Task.isCancelled,
                let self,
                generation == self.microphoneListGeneration
            else { return }
            let isAutoDetect = audioDeviceProvider.isAutoDetect

            let defaultDevice = devices.first(where: { $0.isDefault })
            let defaultLabel = defaultDevice?.transportType == .builtIn
                ? "Built-in mic" : (defaultDevice?.name ?? "System Default")

            var deviceList: [[String: Any]] = [[
                "id": 0,
                "name": "Auto-detect (\(defaultLabel))",
                "isSelected": isAutoDetect,
            ]]

            for device in devices {
                let name = device.transportType == .builtIn
                    ? "Built-in mic (recommended)" : device.name
                deviceList.append([
                    "id": device.id,
                    "name": name,
                    "isSelected": !isAutoDetect && device.id == current?.id,
                ])
            }

            bridge.pushMicrophoneList(
                devices: deviceList,
                currentId: isAutoDetect ? 0 : current?.id
            )
            microphoneListTask = nil
        }
    }

    // MARK: - Action: selectMicrophone

    private func handleSelectMicrophone(id: UInt32) {
        guard let microphoneCaptureCoordinator else { return }
        microphoneListGeneration &+= 1
        microphoneListTask?.cancel()
        microphoneListTask = nil
        microphoneSelectionGeneration &+= 1
        let generation = microphoneSelectionGeneration
        microphoneSelectionTask?.cancel()
        microphoneSelectionTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await microphoneCaptureCoordinator.selectDevice(
                    id: id == 0 ? nil : id)
                guard !Task.isCancelled,
                    let self,
                    generation == self.microphoneSelectionGeneration
                else { return }
                self.bridge.pushMicrophoneSelected(id: id)
            } catch {
                guard !Task.isCancelled,
                    let self,
                    generation == self.microphoneSelectionGeneration
                else {
                    return
                }
                Log.debug("[OnboardingController] selectMicrophone failed: \(error)")
            }
            guard !Task.isCancelled,
                let self,
                generation == self.microphoneSelectionGeneration
            else { return }
            self.microphoneSelectionTask = nil
            self.pushMicPreviewAvailability(self.isPreviewCaptureAvailable)
            self.handleListMicrophones()
        }
    }

    private func invalidateMicrophoneDeviceTasks() {
        microphoneListGeneration &+= 1
        microphoneListTask?.cancel()
        microphoneListTask = nil

        microphoneSelectionGeneration &+= 1
        microphoneSelectionTask?.cancel()
        microphoneSelectionTask = nil
    }

    // MARK: - Action: startMicPreview

    private func handleStartMicPreview() {
        guard isPreviewWindowSessionActive,
            let microphoneCaptureCoordinator
        else { return }

        let client: MicrophonePreviewClient
        if let microphonePreviewClient {
            client = microphonePreviewClient
        } else {
            client = MicrophonePreviewClient(
                coordinator: microphoneCaptureCoordinator)
            microphonePreviewClient = client
        }
        client.start(
            isEligible: { [weak self] in
                self?.isPreviewWindowSessionActive == true
            },
            onAudioLevel: { [weak self] level in
                self?.bridge.pushAudioLevel(level: level)
            },
            onAvailability: { [weak self] isAvailable in
                self?.pushMicPreviewAvailability(isAvailable)
            })
    }

    private func pushMicPreviewAvailability(_ isAvailable: Bool) {
        isPreviewCaptureAvailable = isAvailable
        bridge.pushEvent(
            name: "micPreviewAvailability",
            data: ["available": isAvailable])
    }

    // MARK: - Action: stopMicPreview

    private func handleStopMicPreview() {
        stopMicPreviewSync()
    }

    private func stopMicPreviewSync() {
        guard let microphonePreviewClient else {
            pushMicPreviewAvailability(false)
            return
        }
        microphonePreviewClient.stop()
    }

    // MARK: - Action: checkAccessibility

    private func handleCheckAccessibility() {
        let granted = permissionProvider?.checkAccessibility() == .granted

        // Check the actual system microphone authorization status rather
        // than relying on a UserDefaults flag that may not be set if the
        // permission was granted outside the onboarding flow.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micGranted = micStatus == .authorized

        bridge.pushPermissionStatus(
            accessibility: granted ? "granted" : "denied",
            microphone: micGranted ? "granted" : (micStatus == .denied ? "denied" : "unknown")
        )

        // Start polling every 2s until granted.
        if !granted {
            startAccessibilityPolling()
        }
    }

    private func startAccessibilityPolling() {
        stopAccessibilityPolling()
        accessibilityPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollAccessibility()
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
    }

    private func pollAccessibility() {
        let granted = permissionProvider?.checkAccessibility() == .granted

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micGranted = micStatus == .authorized

        bridge.pushPermissionStatus(
            accessibility: granted ? "granted" : "denied",
            microphone: micGranted ? "granted" : (micStatus == .denied ? "denied" : "unknown")
        )

        if granted {
            stopAccessibilityPolling()
        }
    }

    // MARK: - Action: openAccessibilitySettings

    private func handleOpenAccessibilitySettings() {
        permissionProvider?.openAccessibilitySettings()
    }

    // MARK: - Action: requestMicrophone

    private func handleRequestMicrophone() {
        Task {
            let granted = await requestMicrophoneAccess()

            let accGranted = permissionProvider?.checkAccessibility() == .granted
            bridge.pushPermissionStatus(
                accessibility: accGranted ? "granted" : "denied",
                microphone: granted ? "granted" : "denied"
            )
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Action: registerHotkey

    private func handleRegisterHotkey() {
        onRegisterHotkey?()
    }

    // MARK: - Action: completeOnboarding

    private func handleCompleteOnboarding() {
        let completedMode = isAPIKeyOnlyFlow ? credentialedMode : nil
        dismissWindow()
        onComplete?(completedMode)
    }
}
