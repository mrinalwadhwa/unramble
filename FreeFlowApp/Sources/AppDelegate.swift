import AppKit
import FreeFlowKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    // MARK: - Services

    private let coordinator = RecordingCoordinator()
    private let permissionProvider = MicrophonePermissionProvider()
    private let hotkeyProvider = CGEventTapHotkeyProvider()
    private let transcriptBuffer = TranscriptBuffer()
    private let textInjector = AppTextInjector()
    private let audioDeviceProvider = CoreAudioDeviceProvider()
    private let soundFeedbackProvider = SoundFeedbackProvider()
    private var pipeline: DictationPipeline?
    private var localModelRuntime: LocalModelRuntime?
    private var localModelPreloadTask: Task<Void, Never>?
    private let pipelineRebuildQueue = AsyncLatestOperationQueue()
    private var pipelineRebuildTask: Task<Void, Never>?

    private struct DetachedPipelineGeneration: Sendable {
        let pipeline: DictationPipeline?
        let runtime: LocalModelRuntime?
        let preloadTask: Task<Void, Never>?

        func drain() async {
            // Fence the pipeline before Qwen cancellation can suspend. The
            // cancellation drain then progresses alongside model teardown.
            await pipeline?.beginRetirement()
            await runtime?.beginShutdown()
            await pipeline?.retire()
            await runtime?.shutdown()
            await preloadTask?.value
        }
    }

    private let keychain = KeychainService()
    private var updaterService: UpdaterService?
    private let micDiagnosticStore = MicDiagnosticStore()
    private var inAppMessageService: InAppMessageService?

    // MARK: - Controllers

    private var hudController: HUDController?
    private var menuBarController: MenuBarController?
    private var permissionController: PermissionController?
    private var onboardingController: OnboardingController?
    private var settingsController: SettingsController?
    private var privateModeMonitor: Any?
    private var privateModeLocalMonitor: Any?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        purgeLegacyV01State()
        setupMenuBar()
        setupPipeline()
        setupUpdater()
        setupInAppMessages()
        setupSettings()
        setupMenuBarState()
        setupPrivateModeShortcut()
        determineLaunchFlow()
    }

    /// Clean up Keychain items and UserDefaults keys left behind by the
    /// v0.1.0 server-backed build. Runs once per install; the marker is
    /// stored in UserDefaults under `didPurgeV01State`.
    ///
    /// v0.1.0 and the current build share the same bundle identifier
    /// (`computer.autonomy.freeflow`) so Sparkle can upgrade in place.
    /// That means the current build inherits the old build's
    /// UserDefaults plist and has read access to the old Keychain
    /// items. None of those are used by the current build and some of
    /// them (session tokens, zone URLs) are security-sensitive, so we
    /// delete them on first launch after upgrading.
    private func purgeLegacyV01State() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didPurgeV01State") else { return }

        Log.debug("[AppDelegate] Purging v0.1.0 legacy state")

        keychain.purgeLegacyV01Items()

        // UserDefaults keys that were meaningful in v0.1.0 but are no
        // longer read. Settings (language, shortcut bindings, sound
        // feedback) are preserved so the user keeps their preferences.
        let legacyDefaults = [
            "hasCompletedOnboarding",
            "hasEmailOnFile",
        ]
        for key in legacyDefaults {
            defaults.removeObject(forKey: key)
        }

        defaults.set(true, forKey: "didPurgeV01State")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipelineRebuildQueue.invalidate()
        pipelineRebuildTask?.cancel()
        localModelPreloadTask?.cancel()
        hotkeyProvider.unregister()
        hudController?.stop()
        menuBarController?.stop()
        permissionController?.stop()
        audioProvider.shutdown()
        soundFeedbackProvider.shutdown()
        onboardingController?.dismissWindow()
        settingsController?.closeWindow()
    }

    // MARK: - Launch Flow

    /// Decide what to show on launch based on stored config.
    ///
    /// Local mode on Apple Silicon needs no API key, so skip straight to
    /// permissions. Cloud mode requires a key — if one is stored, proceed;
    /// otherwise show onboarding.
    private func determineLaunchFlow() {
        if Settings.shared.dictationMode == .local && DictationMode.isLocalAvailable {
            Log.debug("[AppDelegate] Local mode, checking permissions")
            checkPermissions()
        } else if ServiceConfig.shared.isConfigured {
            Log.debug("[AppDelegate] API key present, checking permissions")
            checkPermissions()
        } else {
            Log.debug("[AppDelegate] No API key, showing onboarding")
            showOnboarding()
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        menuBarController?.onReopenOnboarding = { [weak self] in
            self?.onboardingController?.showWindow()
        }
        menuBarController?.setOnboardingMode(true)
        let controller = ensureOnboardingController()
        controller.showWindow()
    }

    private func ensureOnboardingController() -> OnboardingController {
        if let existing = onboardingController {
            return existing
        }

        let controller = OnboardingController(keychain: keychain)

        controller.permissionProvider = permissionProvider
        controller.audioDeviceProvider = audioDeviceProvider
        controller.audioPreviewProvider = audioProvider
        controller.soundFeedbackProvider = soundFeedbackProvider

        controller.onRegisterHotkey = { [weak self] in
            // Rebuild the pipeline so it picks up the API key or
            // dictation mode the user just configured in onboarding.
            self?.rebuildPipeline()
            self?.startOnboardingDictationObserver()
        }

        controller.onComplete = { [weak self] in
            guard let self else { return }
            Log.debug("[AppDelegate] Onboarding complete")
            self.stopOnboardingDictationObserver()
            self.onboardingController = nil
            self.menuBarController?.setOnboardingMode(false)
            self.menuBarController?.onReopenOnboarding = nil
            self.rebuildPipeline()
            self.checkPermissions()
        }

        onboardingController = controller
        return controller
    }

    // MARK: - Onboarding dictation observer

    /// Observe coordinator state changes during onboarding to push
    /// dictation results to the try-it screen via the bridge.
    ///
    /// Uses `stateStream` instead of polling so no transitions are missed.
    /// The transcript buffer is populated before injection starts, so
    /// reading it on any exit from `.injecting` (success or failure)
    /// reliably captures the result.
    private var onboardingDictationTask: Task<Void, Never>?

    private func startOnboardingDictationObserver() {
        stopOnboardingDictationObserver()
        let coord = coordinator
        let buffer = transcriptBuffer
        onboardingDictationTask = Task { [weak self] in
            var previousState: RecordingState = .idle
            for await state in await coord.stateStream {
                if Task.isCancelled { break }

                // Trigger on any exit from .injecting: the transcript
                // buffer was written before the injecting transition,
                // so it is available whether injection succeeded (.idle)
                // or failed (.injectionFailed).
                if previousState == .injecting
                    && (state == .idle || state == .injectionFailed)
                {
                    let text = await buffer.lastTranscript
                    if let text, !text.isEmpty {
                        await MainActor.run {
                            self?.onboardingController?.onDictationResult?(text)
                        }
                    }
                    // During onboarding the system injection target is
                    // the app itself, so .injectionFailed is expected.
                    // Reset to idle to dismiss the no-target HUD hint.
                    if state == .injectionFailed {
                        await coord.finishInjecting()
                    }
                }
                previousState = state
            }
        }
    }

    private func stopOnboardingDictationObserver() {
        onboardingDictationTask?.cancel()
        onboardingDictationTask = nil
    }

    // MARK: - Updater

    private func setupUpdater() {
        updaterService = UpdaterService()
    }

    // MARK: - In-App Messages

    private func setupInAppMessages() {
        let service = InAppMessageService()
        inAppMessageService = service
        Task {
            await service.fetch()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "FreeFlow"
            )
        }

        self.statusItem = statusItem
    }

    // MARK: - Pipeline

    private let audioProvider = AudioCaptureProvider()

    /// Resolve a model directory path, checking the app bundle first,
    /// then Application Support. Returns the directory path as a String,
    /// or nil if not found in either location.
    private static func resolveModelPath(
        _ modelID: String, file: String,
        modelManager: LocalModelManager
    ) -> String? {
        if let bundled = Bundle.main.path(
            forResource: (file as NSString).deletingPathExtension,
            ofType: (file as NSString).pathExtension,
            inDirectory: "models/\(modelID)") {
            return (bundled as NSString).deletingLastPathComponent
        }
        let appSupport = modelManager.modelPath(for: modelID)
        if FileManager.default.fileExists(
            atPath: appSupport.appendingPathComponent(file).path) {
            return appSupport.path
        }
        return nil
    }

    private func setupPipeline() {
        audioProvider.setAudioDeviceProvider(audioDeviceProvider)
        audioProvider.setSoundFeedbackProvider(soundFeedbackProvider)
        audioDeviceProvider.setAudioCaptureProvider(audioProvider)

        let language = Settings.shared.language.languageCode
        let batchProvider: (any BatchDictationProviding)?
        let streamingProvider: (any StreamingDictationProviding)?
        let onSessionExpired: (@Sendable () -> Void)?

        if Settings.shared.dictationMode == .local {
            // Local mode: on-device STT + fine-tuned MLX LLM polish.
            #if arch(arm64)
            Log.debug("[AppDelegate] Using local models (STT + MLX)")
            let modelManager = LocalModelManager()

            // Resolve model paths: app bundle first, then Application Support.
            guard let qwenModelPath = Self.resolveModelPath(
                "qwen3-0.6b-4bit", file: "model.safetensors",
                modelManager: modelManager)
            else {
                fatalError(
                    "Required local model is missing: qwen3-0.6b-4bit")
            }
            guard let adapterPath = Self.resolveModelPath(
                "qwen3-0.6b-4bit-polish-adapter", file: "adapters.safetensors",
                modelManager: modelManager)
            else {
                fatalError(
                    "Required local model is missing: "
                        + "qwen3-0.6b-4bit-polish-adapter")
            }

            let sttEngine: any LocalSTTEngine
            let nemotronDir = modelManager.modelPath(
                for: "nemotron-speech-streaming-en-0.6b-coreml")
            let nemotronVariant = nemotronDir.appendingPathComponent(
                "nemotron_coreml_560ms")
            if FileManager.default.fileExists(
                atPath: nemotronVariant.appendingPathComponent(
                    "tokenizer.json").path) {
                Log.debug("[AppDelegate] Nemotron model found, using NemotronEngine")
                sttEngine = NemotronEngine(
                    modelManager: modelManager,
                    modelPath: nemotronDir.path)
            } else {
                let parakeetPath = Self.resolveModelPath(
                    "parakeet-tdt-0.6b-v3-coreml", file: "tokens.txt",
                    modelManager: modelManager)
                sttEngine = ParakeetEngine(
                    modelManager: modelManager,
                    modelPath: parakeetPath)
            }
            let llmEngine = MLXLLMEngine(
                name: "Qwen3 0.6B Polish",
                modelDirectory: URL(
                    fileURLWithPath: qwenModelPath, isDirectory: true),
                adapterDirectory: URL(
                    fileURLWithPath: adapterPath, isDirectory: true))
            let polisher: any PolishChatClient = MLXPolishClient(
                engine: llmEngine)
            let runtime = LocalModelRuntime(
                sttEngine: sttEngine, llmEngine: llmEngine)
            localModelRuntime = runtime
            batchProvider = nil
            // Allow overriding the streaming cycle interval for tuning.
            let cycleInterval: TimeInterval = {
                if let raw = ProcessInfo.processInfo.environment[
                    "FREEFLOW_CYCLE_INTERVAL"], let value = Double(raw),
                    value > 0 { return value }
                return 3
            }()
            streamingProvider = LocalStreamingProvider(
                sttEngine: sttEngine, polishChatClient: polisher,
                cycleInterval: cycleInterval,
                loadSTT: { try await runtime.loadSTT() })
            onSessionExpired = nil

            startModelPreload(runtime)
            #else
            fatalError("Local mode requires Apple Silicon")
            #endif
        } else {
            // Cloud mode: OpenAI STT + cloud polish.
            let polishClient = OpenAIChatClient(
                apiKey: ServiceConfig.shared.openAIAPIKey ?? "")
            batchProvider = OpenAIBatchProvider(
                apiKey: ServiceConfig.shared.openAIAPIKey ?? "",
                polishChatClient: polishClient)
            streamingProvider = OpenAIStreamingProvider(
                apiKey: ServiceConfig.shared.openAIAPIKey ?? "",
                realtimeModel: "gpt-realtime-2.1",
                polishChatClient: polishClient,
                cloudPolishMode: .realtimeResponse)
            onSessionExpired = { [weak self] in
                Task { @MainActor in self?.resetAPIKey() }
            }
        }

        let isLocal = Settings.shared.dictationMode == .local
        Log.debug("[AppDelegate] setupPipeline: isLocal=\(isLocal), mode=\(Settings.shared.dictationMode.rawValue)")
        let newPipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: AXAppContextProvider(),
            batchProvider: batchProvider,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            streamingProvider: streamingProvider,
            onSessionExpired: onSessionExpired,
            micDiagnosticStore: micDiagnosticStore,
            localMode: isLocal
        )
        pipeline = newPipeline

        // Apply the persisted language setting.
        Task {
            await newPipeline.setLanguage(language)
        }
    }

    private func startModelPreload(_ runtime: LocalModelRuntime) {
        localModelPreloadTask?.cancel()
        localModelPreloadTask = Task { [weak self, runtime] in
            do {
                try await runtime.preload()
                guard !Task.isCancelled, let self,
                    self.localModelRuntime === runtime
                else { return }
                Log.debug("[AppDelegate] Models preloaded")
            } catch {
                guard !Task.isCancelled, let self,
                    self.localModelRuntime === runtime
                else {
                    Log.debug("[AppDelegate] Model preload cancelled")
                    return
                }
                fatalError(
                    "Required local models failed to preload: \(error)")
            }
        }
    }

    // MARK: - HUD

    private func setupHUD() {
        let controller = HUDController()
        controller.start(
            coordinator: coordinator,
            pipeline: pipeline,
            audioProvider: audioProvider,
            transcriptBuffer: transcriptBuffer,
            textInjector: textInjector,
            messageService: inAppMessageService
        )
        controller.onSessionExpired = { [weak self] in
            self?.resetAPIKey()
        }
        controller.viewModel.isPrivateMode = Settings.shared.dictationMode == .local
        hudController = controller
    }

    // MARK: - Menu Bar State

    private func setupMenuBarState() {
        guard let statusItem else { return }
        let controller = MenuBarController()
        controller.start(
            statusItem: statusItem,
            coordinator: coordinator,
            pipeline: pipeline,
            transcriptBuffer: transcriptBuffer,
            textInjector: textInjector,
            audioDeviceProvider: audioDeviceProvider,
            updaterService: updaterService,
            micDiagnosticStore: micDiagnosticStore,
            shortcuts: .default
        )
        menuBarController = controller

        controller.onOpenSettings = { [weak self] in
            self?.showSettings()
        }

        controller.onResetAPIKey = { [weak self] in
            self?.resetAPIKey()
        }

        controller.onTogglePrivateMode = { [weak self] in
            self?.togglePrivateMode()
        }
    }

    /// Register a global keyboard shortcut to toggle private mode.
    /// Works from any app since it uses NSEvent global monitoring.
    /// Reads the binding from Settings so it respects user customization.
    private func setupPrivateModeShortcut() {
        guard DictationMode.isLocalAvailable else { return }

        // Remove any existing monitors to avoid duplicates.
        if let monitor = privateModeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = privateModeLocalMonitor {
            NSEvent.removeMonitor(monitor)
        }

        privateModeMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            let binding = Settings.shared.privateModeShortcutBinding
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if binding.matches(keyCode: event.keyCode, modifierFlags: flags.rawValue) {
                Task { @MainActor in
                    self?.togglePrivateMode()
                }
            }
        }

        privateModeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let binding = Settings.shared.privateModeShortcutBinding
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if binding.matches(keyCode: event.keyCode, modifierFlags: flags.rawValue) {
                Task { @MainActor in
                    self?.togglePrivateMode()
                }
                return nil
            }
            return event
        }
    }

    /// Toggle between cloud and private (local) dictation mode.
    ///
    /// Switching to cloud requires an API key. If none is stored,
    /// show the onboarding flow so the user can enter one.
    private func togglePrivateMode() {
        let isCurrentlyLocal = Settings.shared.dictationMode == .local

        if isCurrentlyLocal && !ServiceConfig.shared.isConfigured {
            // No API key — show just the API key entry screen.
            Log.debug("[AppDelegate] Private mode toggle: no API key, prompting")
            let controller = ensureOnboardingController()
            controller.showAPIKeyEntry()
            return
        }

        let newMode: DictationMode = isCurrentlyLocal ? .cloud : .local
        Settings.shared.dictationMode = newMode
        Log.debug("[AppDelegate] Private mode toggled: \(newMode.rawValue)")

        rebuildPipeline()

        let isPrivate = newMode == .local
        menuBarController?.setPrivateMode(isPrivate)
        hudController?.viewModel.isPrivateMode = isPrivate
    }

    /// Clear the stored API key and return to onboarding.
    ///
    /// - Parameter force: When true, reset even if onboarding is active
    ///   (used by the explicit Reset action in Preferences). When false,
    ///   skip the reset if onboarding is already showing (prevents 401
    ///   errors from reloading the page during the try-it step).
    private func resetAPIKey(force: Bool = false) {
        if !force && onboardingController != nil {
            Log.debug("[AppDelegate] Reset API key requested (ignored — onboarding active)")
            return
        }

        Log.debug("[AppDelegate] Reset API key requested (force=\(force))")

        // Dismiss any existing onboarding window.
        onboardingController?.dismissWindow()
        onboardingController = nil

        let oldGeneration = detachPipelineGeneration()
        let coordinator = self.coordinator
        pipelineRebuildTask = pipelineRebuildQueue.submit(
            cleanup: {
                await oldGeneration.drain()
                await coordinator.reset()
            },
            replacement: {}
        )

        keychain.deleteOpenAIAPIKey()
        showOnboarding()
    }

    // MARK: - Settings

    private func setupSettings() {
        let controller = SettingsController()
        controller.audioDeviceProvider = audioDeviceProvider
        controller.audioPreviewProvider = audioProvider
        controller.soundFeedbackProvider = soundFeedbackProvider
        controller.pipeline = pipeline
        controller.onHotkeyChanged = { [weak self] in
            self?.reRegisterHotkey()
        }
        controller.onDictationModeChanged = { [weak self] in
            self?.rebuildPipeline()
        }
        controller.onResetApp = { [weak self] in
            self?.resetAPIKey(force: true)
        }
        settingsController = controller
    }

    /// Show the settings window.
    private func showSettings() {
        settingsController?.showWindow()
    }

    /// Re-register the hotkey after settings change.
    private func reRegisterHotkey() {
        hotkeyProvider.unregister()
        registerHotkey()
    }

    /// Rebuild the pipeline after dictation mode changes.
    private func rebuildPipeline() {
        Log.debug("[AppDelegate] Rebuilding pipeline for mode: \(Settings.shared.dictationMode.rawValue)")

        let oldGeneration = detachPipelineGeneration()
        pipelineRebuildTask = pipelineRebuildQueue.submit(
            cleanup: { await oldGeneration.drain() },
            replacement: { [weak self] in
                self?.finishPipelineRebuild()
            }
        )
    }

    private func detachPipelineGeneration() -> DetachedPipelineGeneration {
        // Fence input synchronously. Cleanup and replacement are serialized
        // because model teardown must finish before a new generation loads.
        hotkeyProvider.unregister()
        menuBarController?.setHotkeyRegistered(false)
        hudController?.stop()
        hudController = nil

        let oldPipeline = pipeline
        pipeline = nil
        settingsController?.pipeline = nil
        menuBarController?.setPipeline(nil)

        let oldRuntime = localModelRuntime
        localModelRuntime = nil
        let oldPreloadTask = localModelPreloadTask
        localModelPreloadTask = nil
        oldPreloadTask?.cancel()

        return DetachedPipelineGeneration(
            pipeline: oldPipeline,
            runtime: oldRuntime,
            preloadTask: oldPreloadTask
        )
    }

    private func finishPipelineRebuild() {
        setupPipeline()
        setupHUD()
        settingsController?.pipeline = pipeline
        menuBarController?.setPipeline(pipeline)
        menuBarController?.setPrivateMode(
            Settings.shared.dictationMode == .local)

        // Register only after the latest replacement has been published.
        registerHotkey()
    }

    // MARK: - Permissions

    private func checkPermissions() {
        let controller = PermissionController(permissionProvider: permissionProvider)
        controller.onPermissionsGranted = { [weak self] in
            self?.registerHotkey()
        }
        permissionController = controller
        controller.checkPermissions()
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        guard let pipeline else {
            Log.debug("[AppDelegate] Pipeline not initialized, cannot register hotkey")
            return
        }

        // Create the HUD on first hotkey registration.
        if hudController == nil {
            setupHUD()
        }

        let pipelineRef = pipeline
        let hudRef = hudController
        let menuRef = menuBarController

        do {
            try hotkeyProvider.register { event in
                Task { @MainActor in
                    switch event {
                    case .pressed:
                        hudRef?.hotkeyHeld()
                        Task {
                            await pipelineRef.activate()
                        }
                    case .released:
                        Task { await pipelineRef.complete() }
                    }
                }
            }
            menuRef?.setHotkeyRegistered(true)
            Log.debug("[AppDelegate] Global hotkey registered (Right Option)")
        } catch {
            Log.debug("[AppDelegate] Failed to register hotkey: \(error)")
            menuRef?.setHotkeyRegistered(false)
            Task { @MainActor in
                self.showHotkeyRegistrationFailedAlert(error: error)
            }
        }
    }

    // MARK: - Alerts

    @MainActor
    private func showHotkeyRegistrationFailedAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Hotkey Registration Failed"
        alert.informativeText = """
            FreeFlow could not register the global hotkey (Right Option). \
            \(error). \
            Try granting accessibility access and restarting the app.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            permissionProvider.openAccessibilitySettings()
        }
    }
}
