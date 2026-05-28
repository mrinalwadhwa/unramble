import AVFoundation
import AppKit
import FreeFlowKit

/// Provide audio capture for mic preview during onboarding.
protocol AudioPreviewProviding: AnyObject {
    func startRecording() async throws
    func stopRecording() async throws -> FreeFlowKit.AudioBuffer
    var audioLevelStream: AsyncStream<Float>? { get }
}

extension AudioCaptureProvider: AudioPreviewProviding {}

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
    var onComplete: (() -> Void)?

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

    /// The audio capture provider for mic preview, set by AppDelegate.
    var audioPreviewProvider: AudioPreviewProviding?

    /// The sound feedback provider, set by AppDelegate. Used to mute
    /// start/stop cues during mic preview so onboarding is silent.
    var soundFeedbackProvider: SoundFeedbackProvider?

    /// Polling timer for accessibility permission checks.
    private var accessibilityPollTimer: Timer?

    /// Task for streaming audio levels during mic preview.
    private var audioLevelTask: Task<Void, Never>?

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
        let win = OnboardingWindow(bridge: bridge)
        bridge.webView = win.webView
        window = win

        window?.onDidFinishNavigation = { [weak self] in
            self?.bridge.pushStepIcons()
        }
        window?.loadBundledOnboarding(query: "mode=api-key-only")
        window?.present()
    }

    /// Open the onboarding window and load the bundled onboarding page.
    func showWindow() {
        // Always create a fresh window. The previous window's bridge
        // handler is removed on close/dismiss, so reusing it would
        // leave the JS bridge non-functional.
        let win = OnboardingWindow(bridge: bridge)
        bridge.webView = win.webView
        window = win

        window?.onDidFinishNavigation = { [weak self] in
            self?.bridge.pushOnboardingState()
            self?.bridge.pushStepIcons()
        }
        window?.loadBundledOnboarding()
        window?.present()
    }

    /// Dismiss the onboarding window and clean up.
    func dismissWindow() {
        stopAccessibilityPolling()
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
        Task {
            let devices = await audioDeviceProvider.availableDevices()
            let current = await audioDeviceProvider.currentDevice()
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
        }
    }

    // MARK: - Action: selectMicrophone

    private func handleSelectMicrophone(id: UInt32) {
        guard let audioDeviceProvider else { return }
        Task {
            do {
                // Stop current preview and wait for it to complete.
                await stopMicPreviewAsync()

                // Select the device, or clear to auto-detect.
                if id == 0 {
                    audioDeviceProvider.clearSelection()
                } else {
                    try await audioDeviceProvider.selectDevice(id: id)
                }
                bridge.pushMicrophoneSelected(id: id)

                // Small delay to let the audio system settle after device change.
                try await Task.sleep(nanoseconds: 100_000_000)

                // Start preview with the new device.
                await startMicPreviewAsync()
            } catch {
                Log.debug("[OnboardingController] selectMicrophone failed: \(error)")
            }
        }
    }

    // MARK: - Action: startMicPreview

    private func handleStartMicPreview() {
        Task {
            await startMicPreviewAsync()
        }
    }

    private func startMicPreviewAsync() async {
        guard let audioPreviewProvider else { return }

        // Stop any existing preview first.
        await stopMicPreviewAsync()

        do {
            // Mute sound feedback during preview so the mic selection
            // step does not play the start/stop cues.
            if let capture = audioPreviewProvider as? AudioCaptureProvider {
                capture.setSoundFeedbackProvider(nil)
            }

            try await audioPreviewProvider.startRecording()

            // Stream audio levels to the bridge.
            audioLevelTask = Task { [weak self] in
                guard let stream = audioPreviewProvider.audioLevelStream else {
                    return
                }
                for await level in stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self?.bridge.pushAudioLevel(level: level)
                    }
                }
            }
        } catch {
            Log.debug("[OnboardingController] startMicPreview failed: \(error)")
        }
    }

    // MARK: - Action: stopMicPreview

    private func handleStopMicPreview() {
        Task {
            await stopMicPreviewAsync()
        }
    }

    private func stopMicPreviewAsync() async {
        audioLevelTask?.cancel()
        audioLevelTask = nil

        guard let audioPreviewProvider else { return }
        _ = try? await audioPreviewProvider.stopRecording()
        // Restore sound feedback after preview stops.
        if let soundFeedbackProvider,
            let capture = audioPreviewProvider as? AudioCaptureProvider
        {
            capture.setSoundFeedbackProvider(soundFeedbackProvider)
        }
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
        dismissWindow()
        onComplete?()
    }
}
