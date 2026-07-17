import AppKit
import UnrambleKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    // MARK: - Services

    private let coordinator = RecordingCoordinator()
    private let permissionProvider = MicrophonePermissionProvider()
    private let hotkeyProvider = CGEventTapHotkeyProvider()
    private let modeHotkeyProvider = CGEventTapHotkeyProvider()
    private var hotkeyPipelineDriver: HotkeyPipelineDriver?
    private var hotkeyPipelineIdentity: ObjectIdentifier?
    private var dictationHotkeyPublicationRequested = false
    private var hotkeyReRegistrationGeneration: UInt = 0
    private var hotkeyReRegistrationTask: Task<Void, Never>?
    private var registeredModeHotkeyBinding: ShortcutBinding?
    private let transcriptBuffer = TranscriptBuffer()
    private let textInjector = SerializedTextInjector(base: AppTextInjector())
    private let audioDeviceProvider = CoreAudioDeviceProvider()
    private let soundFeedbackProvider = SoundFeedbackProvider()
    private var pipeline: DictationPipeline?
    private var pendingSessionRecoveryPipeline: DictationPipeline?
    private var localModelRuntime: LocalModelRuntime?
    private var localModelPreloadTask: Task<Void, Never>?
    private let pipelineRebuildQueue = AsyncLatestOperationQueue()
    private var pipelineRebuildTask: Task<Void, Never>?
    private var modeTransition = DictationModeTransition(
        effectiveMode: Settings.shared.dictationMode)
    private var modeSwitchTask: Task<Void, Never>?
    private var modeSwitchRequest: DictationModeTransition.Request?
    private var alwaysReadyPreviewLease: MicrophoneCaptureLease?
    private var alwaysReadyPreviewTask: Task<Void, Never>?
    private var isAlwaysReadyPreviewAvailable = false
    private var dictationHotkeyMaintenanceIDs: Set<UUID> = []
    private var terminationCaptureDrainTask: Task<Void, Never>?
    private var didFenceApplicationTermination = false
    private var didDrainCaptureForTermination = false

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

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        purgeLegacyV01State()
        if modeTransition.effectiveMode == .local,
            !DictationMode.isLocalAvailable
        {
            modeTransition = DictationModeTransition(effectiveMode: .cloud)
            Settings.shared.dictationMode = .cloud
        }
        setupMenuBar()
        setupPipeline(mode: modeTransition.effectiveMode)
        setupUpdater()
        setupInAppMessages()
        setupSettings()
        setupMenuBarState()
        determineLaunchFlow()
    }

    /// Clean up Keychain items and UserDefaults keys left behind by the
    /// v0.1.0 server-backed build. Runs once per install; the marker is
    /// stored in UserDefaults under `didPurgeV01State`.
    ///
    /// v0.1.0 and the current build share the same bundle identifier
    /// (`computer.autonomy.unramble`) so Sparkle can upgrade in place.
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

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if didDrainCaptureForTermination {
            return .terminateNow
        }

        fenceApplicationForTermination()
        guard terminationCaptureDrainTask == nil else {
            return .terminateLater
        }

        let captureCoordinator = microphoneCaptureCoordinator
        let captureProvider = audioProvider
        terminationCaptureDrainTask = Task { @MainActor [weak self] in
            await captureCoordinator.shutdown()
            captureProvider.shutdown()

            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            self.didDrainCaptureForTermination = true
            self.terminationCaptureDrainTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        fenceApplicationForTermination()
        if !didDrainCaptureForTermination {
            // Fallback for termination paths that bypass the deferred reply.
            audioProvider.shutdown()
        }
        soundFeedbackProvider.shutdown()
        onboardingController?.dismissWindow()
        settingsController?.closeWindow()
    }

    private func fenceApplicationForTermination() {
        guard !didFenceApplicationTermination else { return }
        didFenceApplicationTermination = true
        pipelineRebuildQueue.invalidate()
        pipelineRebuildTask?.cancel()
        modeSwitchTask?.cancel()
        hotkeyReRegistrationGeneration &+= 1
        hotkeyReRegistrationTask?.cancel()
        alwaysReadyPreviewTask?.cancel()
        localModelPreloadTask?.cancel()
        unregisterHotkey()
        unregisterModeHotkey()
        hudController?.stop()
        menuBarController?.stop()
        permissionController?.stop()
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
        if modeTransition.effectiveMode == .local && DictationMode.isLocalAvailable {
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
        guard !didFenceApplicationTermination else { return }
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
        controller.microphoneCaptureCoordinator = microphoneCaptureCoordinator

        controller.onRegisterHotkey = { [weak self] in
            guard let self, !self.didFenceApplicationTermination else {
                return
            }
            let requestedMode = Settings.shared.dictationMode
            let afterPublication: @MainActor @Sendable () -> Void = {
                [weak self] in
                self?.startOnboardingDictationObserver()
            }
            if requestedMode != self.modeTransition.effectiveMode {
                _ = self.requestDictationMode(
                    requestedMode, afterPublication: afterPublication)
            } else if requestedMode == .cloud {
                // The launch-time cloud client may predate key entry.
                self.rebuildPipeline(afterReplacement: afterPublication)
            } else {
                self.registerHotkey()
                afterPublication()
            }
        }

        controller.onComplete = { [weak self] credentialedMode in
            guard let self, !self.didFenceApplicationTermination else {
                return
            }
            Log.debug("[AppDelegate] Onboarding complete")
            self.stopOnboardingDictationObserver()
            self.onboardingController = nil
            self.menuBarController?.setOnboardingMode(false)
            self.menuBarController?.onReopenOnboarding = nil

            if let recoveryPipeline = self.pendingSessionRecoveryPipeline {
                Task { [weak self, recoveryPipeline] in
                    await recoveryPipeline.presentRecoveryAfterAuthentication()
                    await MainActor.run {
                        guard let self,
                            self.pipeline === recoveryPipeline,
                            self.pendingSessionRecoveryPipeline === recoveryPipeline
                        else { return }
                        self.pendingSessionRecoveryPipeline = nil
                        self.registerHotkey()
                    }
                }
                return
            }

            if let credentialedMode {
                _ = self.requestDictationMode(
                    credentialedMode,
                    afterPublication: { [weak self] in
                        self?.checkPermissions()
                    })
                return
            }

            let requestedMode = Settings.shared.dictationMode
            if requestedMode != self.modeTransition.effectiveMode {
                _ = self.requestDictationMode(
                    requestedMode,
                    afterPublication: { [weak self] in
                        self?.checkPermissions()
                    })
            } else {
                self.checkPermissions()
            }
        }

        onboardingController = controller
        return controller
    }

    // MARK: - Onboarding dictation observer

    /// Observe coordinator state changes during onboarding to push
    /// dictation results to the try-it screen via the bridge.
    ///
    /// Uses `sessionStateStream` instead of polling so no transitions are
    /// missed or rebound to a later pipeline session.
    /// The transcript buffer is populated before injection starts, so
    /// reading it on any exit from `.injecting` (success or failure)
    /// reliably captures the result.
    private var onboardingDictationTask: Task<Void, Never>?

    private func startOnboardingDictationObserver() {
        stopOnboardingDictationObserver()
        let coord = coordinator
        let buffer = transcriptBuffer
        let pipeline = pipeline
        onboardingDictationTask = Task { [weak self] in
            var previousUpdate = RecordingStateUpdate(
                state: .idle,
                sessionID: nil)
            for await update in await coord.sessionStateStream {
                if Task.isCancelled { break }
                let state = update.state

                // Trigger on any exit from .injecting: the transcript
                // buffer was written before the injecting transition,
                // so it is available whether injection succeeded (.idle)
                // or failed (.injectionFailed).
                if previousUpdate.state == .injecting
                    && (state == .idle || state == .injectionFailed),
                    let injectingSessionID = previousUpdate.sessionID
                {
                    let text = await buffer.transcript(for: injectingSessionID)
                    if let text, !text.isEmpty {
                        await MainActor.run {
                            self?.onboardingController?.onDictationResult?(text)
                        }
                    }
                    // During onboarding the system injection target is
                    // the app itself, so .injectionFailed is expected.
                    // Reset to idle to dismiss the no-target HUD hint.
                    if state == .injectionFailed,
                        update.sessionID == previousUpdate.sessionID,
                        let pipeline
                    {
                        await pipeline.dismissInjectionFailure(
                            sessionID: injectingSessionID)
                    }
                }
                previousUpdate = update
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
                accessibilityDescription: "Unramble"
            )
        }

        self.statusItem = statusItem
    }

    // MARK: - Pipeline

    private let audioProvider = AudioCaptureProvider()
    private lazy var microphoneCaptureCoordinator =
        MicrophoneCaptureCoordinator(
            audioProvider: audioProvider,
            audioDeviceProvider: audioDeviceProvider,
            withDeviceSelectionTransaction: { [weak self] operation in
                let maintenanceID = UUID()
                guard let pipeline = await MainActor.run(body: {
                    [weak self] () -> DictationPipeline? in
                    guard let self, let pipeline = self.pipeline else {
                        return nil
                    }
                    self.beginDictationHotkeyMaintenance(id: maintenanceID)
                    return pipeline
                }) else {
                    throw MicrophoneCaptureCoordinatorError
                        .deviceSelectionUnavailable
                }
                do {
                    try await pipeline.withQuiescentCaptureMaintenance(operation)
                    await MainActor.run { [weak self] in
                        self?.finishDictationHotkeyMaintenance(id: maintenanceID)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.finishDictationHotkeyMaintenance(id: maintenanceID)
                    }
                    throw error
                }
            })

    /// Resolve a model directory path, checking the app bundle first,
    /// then Application Support. Returns the directory path as a String,
    /// or nil if not found in either location.
    private static func resolveModelPath(
        _ modelID: String, file: String,
        modelManager: LocalModelManager
    ) -> String? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources
                .appendingPathComponent("models")
                .appendingPathComponent(modelID)
            if FileManager.default.fileExists(
                atPath: bundled.appendingPathComponent(file).path) {
                return bundled.path
            }
        }
        let appSupport = modelManager.modelPath(for: modelID)
        if FileManager.default.fileExists(
            atPath: appSupport.appendingPathComponent(file).path) {
            return appSupport.path
        }
        return nil
    }

    private func setupPipeline(mode: DictationMode) {
        audioProvider.setAudioDeviceProvider(audioDeviceProvider)
        audioProvider.setSoundFeedbackProvider(soundFeedbackProvider)
        audioDeviceProvider.setAudioCaptureProvider(audioProvider)

        let language = Settings.shared.language.languageCode
        let backend: DictationBackend
        let onSessionExpired: (@Sendable () -> Void)?

        if mode == .local {
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

            guard let nemotronPath = Self.resolveModelPath(
                "nemotron-speech-streaming-en-0.6b-coreml",
                file: "nemotron_coreml_560ms/tokenizer.json",
                modelManager: modelManager
            ) else {
                fatalError(
                    "Required local model is missing: "
                        + "nemotron-speech-streaming-en-0.6b-coreml")
            }
            let sttEngine = NemotronEngine(
                modelManager: modelManager, modelPath: nemotronPath)
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
            // Allow overriding the streaming cycle interval for tuning.
            let cycleInterval: TimeInterval = {
                if let raw = ProcessInfo.processInfo.environment[
                    "UNRAMBLE_CYCLE_INTERVAL"], let value = Double(raw),
                    value > 0 { return value }
                return 3
            }()
            backend = .local(
                streaming: LocalStreamingProvider(
                    sttEngine: sttEngine, polishChatClient: polisher,
                    cycleInterval: cycleInterval,
                    loadSTT: { try await runtime.loadSTT() }))
            onSessionExpired = nil

            startModelPreload(runtime)
            #else
            fatalError("Local mode requires Apple Silicon")
            #endif
        } else {
            // Cloud mode: OpenAI STT + cloud polish.
            backend = .cloud(
                realtime: OpenAIStreamingProvider(
                    apiKey: ServiceConfig.shared.openAIAPIKey ?? ""),
                fallback: OpenAIFileTranscriber(
                    apiKey: ServiceConfig.shared.openAIAPIKey ?? ""))
            onSessionExpired = { [weak self] in
                Task { @MainActor in self?.beginSessionRecovery() }
            }
        }

        let isLocal = mode == .local
        Log.debug(
            "[AppDelegate] setupPipeline: isLocal=\(isLocal), mode=\(mode.rawValue)")
        let newPipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: AXAppContextProvider(),
            backend: backend,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            language: language,
            onSessionExpired: onSessionExpired,
            micDiagnosticStore: micDiagnosticStore
        )
        pipeline = newPipeline
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
            messageService: inAppMessageService
        )
        controller.onSessionExpired = { [weak self] in
            self?.beginSessionRecovery()
        }
        controller.onTransferHeldHotkeySession = { [weak self] completion in
            guard let driver = self?.hotkeyPipelineDriver else {
                completion(nil)
                return nil
            }
            return driver.transferHeldSession(completion)
        }
        controller.viewModel.isPrivateMode = modeTransition.effectiveMode == .local
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
            audioDeviceProvider: audioDeviceProvider,
            microphoneCaptureCoordinator: microphoneCaptureCoordinator,
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

        updateModePresentation()
    }

    /// Toggle between cloud and private (local) dictation mode.
    private func togglePrivateMode() {
        let newMode: DictationMode = modeTransition.effectiveMode == .local
            ? .cloud : .local
        requestDictationMode(newMode)
    }

    /// Admit one mode request, then preserve every operation already owned by
    /// the old generation before replacing it. Persisted/UI mode remains tied
    /// to the installed backend until the new pipeline is synchronously
    /// published on the main actor.
    @discardableResult
    private func requestDictationMode(
        _ newMode: DictationMode,
        afterPublication: (@MainActor @Sendable () -> Void)? = nil
    ) -> Bool {
        guard !didFenceApplicationTermination else { return false }
        guard pendingSessionRecoveryPipeline == nil else {
            Log.debug(
                "[AppDelegate] Mode request ignored during session recovery")
            return false
        }
        guard let currentPipeline = pipeline else {
            Log.debug("[AppDelegate] Mode request ignored without a pipeline")
            return false
        }

        let isAvailable = newMode == .local
            ? DictationMode.isLocalAvailable
            : ServiceConfig.shared.isConfigured
        switch modeTransition.request(newMode, isAvailable: isAvailable) {
        case .unchanged:
            afterPublication?()
            return true
        case .busy:
            Log.debug("[AppDelegate] Mode request ignored while replacement is pending")
            return false
        case .unavailable:
            if newMode == .cloud {
                Log.debug("[AppDelegate] Cloud mode requires an API key")
                showCloudCredentialEntry()
            }
            return false
        case .accepted(let request):
            modeSwitchRequest = request
            updateModePresentation()

            let switchTask = Task { @MainActor [weak self, currentPipeline] in
                await currentPipeline.sealForReplacement()
                guard let self else { return }
                guard !Task.isCancelled,
                    self.pipeline === currentPipeline,
                    self.modeSwitchRequest == request,
                    self.modeTransition.requestedRequest == request
                else {
                    if self.pipeline === currentPipeline {
                        _ = await currentPipeline.reopenAfterFailedReplacement()
                    }
                    return
                }

                // The credential may have been removed while a live dictation
                // was draining. Reopen this exact quiescent generation instead
                // of leaving working local dictation permanently sealed.
                if request.mode == .cloud,
                    !ServiceConfig.shared.isConfigured
                {
                    let reopened = await currentPipeline
                        .reopenAfterFailedReplacement()
                    guard self.pipeline === currentPipeline,
                        self.modeSwitchRequest == request,
                        self.modeTransition.requestedRequest == request
                    else { return }
                    _ = self.modeTransition.fail(request)
                    self.clearModeSwitchTracking(request)
                    self.updateModePresentation()
                    if reopened {
                        self.showCloudCredentialEntry()
                    }
                    return
                }

                guard
                    let oldGeneration = self.detachPipelineGeneration(
                        ifCurrent: currentPipeline)
                else {
                    _ = self.modeTransition.fail(request)
                    self.clearModeSwitchTracking(request)
                    self.updateModePresentation()
                    return
                }

                let rebuildTask = self.pipelineRebuildQueue.submit(
                    cleanup: { await oldGeneration.drain() },
                    replacement: { [weak self] in
                        guard let self,
                            !self.didFenceApplicationTermination,
                            self.modeSwitchRequest == request,
                            self.modeTransition.requestedRequest == request
                        else { return }

                        self.setupPipeline(mode: request.mode)
                        guard self.modeTransition.publish(request) else {
                            return
                        }
                        Settings.shared.dictationMode = request.mode
                        self.finishPipelinePublication()
                        self.clearModeSwitchTracking(request)
                        self.updateModePresentation()
                        afterPublication?()
                    })
                self.pipelineRebuildTask = rebuildTask
                await rebuildTask.value
            }
            modeSwitchTask = switchTask
            Log.debug("[AppDelegate] Mode replacement requested: \(newMode.rawValue)")
            return true
        }
    }

    private func showCloudCredentialEntry() {
        guard !didFenceApplicationTermination else { return }
        let controller = ensureOnboardingController()
        controller.showAPIKeyEntry()
    }

    private func clearModeSwitchTracking(
        _ request: DictationModeTransition.Request
    ) {
        guard modeSwitchRequest == request else { return }
        modeSwitchTask = nil
        modeSwitchRequest = nil
    }

    private func cancelPendingModeSwitch() {
        modeSwitchTask?.cancel()
        modeSwitchTask = nil
        modeSwitchRequest = nil
        modeTransition.cancelPendingRequest()
        updateModePresentation()
    }

    private func updateModePresentation() {
        menuBarController?.setDictationMode(
            effective: modeTransition.effectiveMode,
            requested: modeTransition.requestedMode)
        hudController?.viewModel.isPrivateMode =
            modeTransition.effectiveMode == .local
    }

    /// Clear the stored API key and return to onboarding.
    ///
    /// - Parameter force: When true, reset even if onboarding is active
    ///   (used by the explicit Reset action in Preferences). When false,
    ///   skip the reset if onboarding is already showing (prevents 401
    ///   errors from reloading the page during the try-it step).
    private func resetAPIKey(force: Bool = false) {
        guard !didFenceApplicationTermination else { return }
        if !force && onboardingController != nil {
            Log.debug("[AppDelegate] Reset API key requested (ignored — onboarding active)")
            return
        }

        Log.debug("[AppDelegate] Reset API key requested (force=\(force))")
        pendingSessionRecoveryPipeline = nil
        cancelPendingModeSwitch()

        // Dismiss any existing onboarding window.
        onboardingController?.dismissWindow()
        onboardingController = nil

        let oldGeneration = detachPipelineGeneration()
        let coordinator = self.coordinator
        pipelineRebuildTask = pipelineRebuildQueue.submit(
            cleanup: {
                await oldGeneration.drain()
                let reset = await coordinator.reset()
                if !reset {
                    Log.debug(
                        "[AppDelegate] Coordinator reset rejected after generation drain")
                }
            },
            replacement: {}
        )

        keychain.deleteOpenAIAPIKey()
        showOnboarding()
    }

    /// Replace an expired cloud credential without retiring the pipeline that
    /// owns the complete recovery WAV. API clients read the new key lazily.
    private func beginSessionRecovery() {
        guard !didFenceApplicationTermination else { return }
        guard pendingSessionRecoveryPipeline == nil else { return }
        guard let pipeline else {
            resetAPIKey()
            return
        }

        Log.debug("[AppDelegate] Beginning API key recovery")
        pendingSessionRecoveryPipeline = pipeline
        unregisterHotkey()
        unregisterModeHotkey()
        menuBarController?.setHotkeyRegistered(false)
        keychain.deleteOpenAIAPIKey()

        menuBarController?.setOnboardingMode(true)
        menuBarController?.onReopenOnboarding = { [weak self] in
            self?.onboardingController?.showAPIKeyEntry()
        }
        let onboarding = ensureOnboardingController()
        onboarding.dismissWindow()
        onboarding.showAPIKeyEntry()
    }

    // MARK: - Settings

    private func setupSettings() {
        let controller = SettingsController()
        controller.audioDeviceProvider = audioDeviceProvider
        controller.microphoneCaptureCoordinator = microphoneCaptureCoordinator
        controller.pipeline = pipeline
        controller.onHotkeyChanged = { [weak self] in
            self?.reRegisterHotkey()
        }
        controller.onModeShortcutChanged = { [weak self] in
            self?.reRegisterModeHotkey()
        }
        controller.onDictationModeChanged = { [weak self] mode in
            self?.requestDictationMode(mode)
        }
        controller.onResetApp = { [weak self] in
            self?.resetAPIKey(force: true)
        }
        settingsController = controller
    }

    /// Show the settings window.
    private func showSettings() {
        guard !didFenceApplicationTermination else { return }
        settingsController?.showWindow()
    }

    /// Re-register the hotkey after settings change.
    private func reRegisterHotkey() {
        guard !didFenceApplicationTermination else { return }
        hotkeyReRegistrationTask?.cancel()
        hotkeyReRegistrationGeneration &+= 1
        let generation = hotkeyReRegistrationGeneration
        let maintenanceID = UUID()
        beginDictationHotkeyMaintenance(id: maintenanceID)

        guard let currentPipeline = pipeline else {
            finishDictationHotkeyMaintenance(id: maintenanceID)
            return
        }

        hotkeyReRegistrationTask = Task { @MainActor [weak self] in
            do {
                try await currentPipeline.withQuiescentCaptureMaintenance {}
            } catch {
                guard let self else { return }
                self.finishDictationHotkeyMaintenance(id: maintenanceID)
                if self.hotkeyReRegistrationGeneration == generation {
                    self.hotkeyReRegistrationTask = nil
                }
                Log.debug(
                    "[AppDelegate] Dictation hotkey re-registration skipped: \(error)")
                return
            }

            guard let self else { return }
            guard self.hotkeyReRegistrationGeneration == generation,
                self.pipeline === currentPipeline
            else {
                self.finishDictationHotkeyMaintenance(id: maintenanceID)
                return
            }

            // The old driver is now quiescent. Replace its physical event tap
            // while the AppDelegate fence still blocks publication.
            self.unpublishDictationHotkey()
            self.finishDictationHotkeyMaintenance(id: maintenanceID)
            self.hotkeyReRegistrationTask = nil
        }
    }

    private func reRegisterModeHotkey() {
        guard !didFenceApplicationTermination else { return }
        unregisterModeHotkey()
        registerModeHotkey()
    }

    /// Rebuild the pipeline after dictation mode changes.
    private func rebuildPipeline(
        afterReplacement: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard !didFenceApplicationTermination else { return }
        let effectiveMode = modeTransition.effectiveMode
        Log.debug(
            "[AppDelegate] Rebuilding effective pipeline: \(effectiveMode.rawValue)")
        pendingSessionRecoveryPipeline = nil
        cancelPendingModeSwitch()

        let oldGeneration = detachPipelineGeneration()
        pipelineRebuildTask = pipelineRebuildQueue.submit(
            cleanup: { await oldGeneration.drain() },
            replacement: { [weak self] in
                self?.finishPipelineRebuild(mode: effectiveMode)
                afterReplacement?()
            }
        )
    }

    private func detachPipelineGeneration(
        ifCurrent expectedPipeline: DictationPipeline
    ) -> DetachedPipelineGeneration? {
        guard pipeline === expectedPipeline else { return nil }
        return detachPipelineGeneration()
    }

    private func detachPipelineGeneration() -> DetachedPipelineGeneration {
        // Fence input synchronously. Cleanup and replacement are serialized
        // because model teardown must finish before a new generation loads.
        unregisterHotkey()
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

    private func finishPipelineRebuild(mode: DictationMode) {
        setupPipeline(mode: mode)
        finishPipelinePublication()
    }

    private func finishPipelinePublication() {
        guard !didFenceApplicationTermination else { return }
        setupHUD()
        settingsController?.pipeline = pipeline
        menuBarController?.setPipeline(pipeline)
        updateModePresentation()

        // Register only after the latest replacement has been published.
        registerHotkey()
    }

    // MARK: - Permissions

    private func checkPermissions() {
        guard !didFenceApplicationTermination else { return }
        let controller = PermissionController(permissionProvider: permissionProvider)
        controller.onPermissionsGranted = { [weak self] in
            self?.registerHotkey()
        }
        permissionController = controller
        controller.checkPermissions()
    }

    // MARK: - Hotkey

    private func unregisterHotkey() {
        dictationHotkeyPublicationRequested = false
        unpublishDictationHotkey()
    }

    private func unpublishDictationHotkey() {
        hotkeyPipelineDriver?.invalidate()
        hotkeyPipelineDriver = nil
        hotkeyPipelineIdentity = nil
        hotkeyProvider.unregister()
        menuBarController?.setHotkeyRegistered(false)
    }

    /// Availability and device maintenance fence only new presses. Keeping the
    /// event tap and driver alive preserves release delivery for a press that
    /// crossed the admission boundary before the fence.
    private func suspendDictationHotkeyAdmission() {
        hotkeyPipelineDriver?.suspendNewPresses()
        menuBarController?.setHotkeyRegistered(false)
    }

    private func beginDictationHotkeyMaintenance(id: UUID) {
        dictationHotkeyMaintenanceIDs.insert(id)
        suspendDictationHotkeyAdmission()
    }

    private func finishDictationHotkeyMaintenance(id: UUID) {
        guard dictationHotkeyMaintenanceIDs.remove(id) != nil else { return }
        guard dictationHotkeyMaintenanceIDs.isEmpty else { return }
        publishDictationHotkeyIfReady()
    }

    private func unregisterModeHotkey() {
        registeredModeHotkeyBinding = nil
        modeHotkeyProvider.unregister()
    }

    private func registerModeHotkey() {
        guard !didFenceApplicationTermination else { return }
        guard DictationMode.isLocalAvailable else { return }
        guard pendingSessionRecoveryPipeline == nil else { return }
        let binding = Settings.shared.privateModeShortcutBinding
        guard registeredModeHotkeyBinding != binding else { return }

        unregisterModeHotkey()
        let setting = HotkeySetting.modifierPlusKey(
            modifierFlags: binding.standardModifierFlags,
            keyCode: binding.keyCode,
            keyName: binding.label)
        do {
            try modeHotkeyProvider.register(with: setting) {
                [weak self] event in
                guard event == .pressed else { return }
                Task { @MainActor [weak self] in
                    self?.togglePrivateMode()
                }
            }
            registeredModeHotkeyBinding = binding
            Log.debug(
                "[AppDelegate] Mode shortcut registered (\(binding.label))")
        } catch {
            modeHotkeyProvider.unregister()
            Log.debug(
                "[AppDelegate] Failed to register mode shortcut: \(error)")
        }
    }

    private func registerHotkey() {
        guard !didFenceApplicationTermination else { return }
        dictationHotkeyPublicationRequested = true
        registerModeHotkey()
        ensureAlwaysReadyMicrophoneCapture()
        publishDictationHotkeyIfReady()
    }

    private func publishDictationHotkeyIfReady() {
        guard !didFenceApplicationTermination else { return }
        guard dictationHotkeyPublicationRequested else { return }
        guard dictationHotkeyMaintenanceIDs.isEmpty else {
            suspendDictationHotkeyAdmission()
            Log.debug(
                "[AppDelegate] Dictation hotkey waiting for microphone maintenance")
            return
        }
        guard isAlwaysReadyPreviewAvailable else {
            suspendDictationHotkeyAdmission()
            Log.debug(
                "[AppDelegate] Dictation hotkey waiting for continuous microphone capture")
            return
        }
        guard let pipeline else {
            Log.debug("[AppDelegate] Pipeline not initialized, cannot register hotkey")
            return
        }
        let pipelineIdentity = ObjectIdentifier(pipeline)
        if let existingDriver = hotkeyPipelineDriver {
            if hotkeyPipelineIdentity == pipelineIdentity,
                existingDriver.resumeNewPresses()
            {
                menuBarController?.setHotkeyRegistered(true)
                Log.debug(
                    "[AppDelegate] Dictation hotkey admission available")
                return
            }
            unpublishDictationHotkey()
        }

        // Create the HUD on first hotkey registration.
        if hudController == nil {
            setupHUD()
        }

        let pipelineRef = pipeline
        let hudRef = hudController
        let menuRef = menuBarController
        let driver = HotkeyPipelineDriver(
            pipeline: pipelineRef,
            canAdmitPress: { [audioProvider] pressHostTime in
                audioProvider.canAdmitDictationPress(at: pressHostTime)
            },
            heldSessionAccepted: { [weak hudRef] heldSession in
                await MainActor.run {
                    hudRef?.hotkeySessionAccepted(heldSession)
                }
            },
            sessionEnded: { [weak hudRef] sessionID in
                await MainActor.run {
                    hudRef?.sessionEnded(sessionID)
                }
            })

        do {
            try hotkeyProvider.registerTimestamped { event, hostTime in
                driver.submit(event, hostTime: hostTime)
            }
            hotkeyPipelineDriver = driver
            hotkeyPipelineIdentity = pipelineIdentity
            menuRef?.setHotkeyRegistered(true)
            Log.debug("[AppDelegate] Global hotkey registered (Right Option)")
        } catch {
            driver.invalidate()
            hotkeyPipelineDriver = nil
            hotkeyPipelineIdentity = nil
            hotkeyProvider.unregister()
            Log.debug("[AppDelegate] Failed to register hotkey: \(error)")
            menuRef?.setHotkeyRegistered(false)
            Task { @MainActor in
                self.showHotkeyRegistrationFailedAlert(error: error)
            }
        }
    }

    /// Keep one quiet preview demand alive after microphone authorization. Its
    /// availability stream withdraws the dictation hotkey while the exact tap
    /// is rotating, then republishes it only after replacement capture exists.
    private func ensureAlwaysReadyMicrophoneCapture() {
        guard permissionProvider.checkMicrophone() == .granted else {
            Log.debug(
                "[AppDelegate] Continuous microphone capture awaits permission")
            return
        }
        guard alwaysReadyPreviewLease == nil,
            alwaysReadyPreviewTask == nil
        else { return }

        let captureCoordinator = microphoneCaptureCoordinator
        alwaysReadyPreviewTask = Task { @MainActor [weak self] in
            var retryDelayNanoseconds: UInt64 = 100_000_000

            while !Task.isCancelled {
                do {
                    let lease = try await captureCoordinator.acquirePreview()
                    try Task.checkCancellation()
                    guard let self else {
                        _ = try? await lease.release()
                        return
                    }

                    self.alwaysReadyPreviewLease = lease
                    retryDelayNanoseconds = 100_000_000
                    for await isAvailable in lease.captureAvailability {
                        guard !Task.isCancelled else { break }
                        self.isAlwaysReadyPreviewAvailable = isAvailable
                        if isAvailable {
                            self.publishDictationHotkeyIfReady()
                        } else {
                            self.suspendDictationHotkeyAdmission()
                        }
                    }

                    self.isAlwaysReadyPreviewAvailable = false
                    self.suspendDictationHotkeyAdmission()
                    self.alwaysReadyPreviewLease = nil
                    _ = try? await lease.release()
                } catch is CancellationError {
                    break
                } catch {
                    Log.debug(
                        "[AppDelegate] Continuous microphone capture failed: \(error)")
                }

                guard !Task.isCancelled else { break }
                do {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                } catch {
                    break
                }
                retryDelayNanoseconds = min(
                    retryDelayNanoseconds * 2,
                    5_000_000_000)
            }

            if let self, let lease = self.alwaysReadyPreviewLease {
                self.alwaysReadyPreviewLease = nil
                self.isAlwaysReadyPreviewAvailable = false
                _ = try? await lease.release()
                self.suspendDictationHotkeyAdmission()
            }
            self?.alwaysReadyPreviewTask = nil
        }
    }

    // MARK: - Alerts

    @MainActor
    private func showHotkeyRegistrationFailedAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Hotkey Registration Failed"
        alert.informativeText = """
            Unramble could not register the global hotkey (Right Option). \
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
