import AppKit
import UnrambleKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    // MARK: - Services

    private let coordinator = RecordingCoordinator()
    private let permissionProvider = MicrophonePermissionProvider()
    private let hotkeyProvider = CGEventTapHotkeyProvider()
    private let modeHotkeyProvider = CarbonHotkeyProvider()
    private let readAloudHotkeyProvider = CarbonHotkeyProvider()
    private var registeredReadAloudBinding: ShortcutBinding?
    private var readAloudCoordinator: ReadAloudCoordinator?
    private var readAloudObservationTask: Task<Void, Never>?
    private let callHotkeyProvider = CarbonHotkeyProvider()
    private var registeredCallBinding: ShortcutBinding?
    private var conversationCallCoordinator: ConversationCallCoordinator?
    private var callObservationTask: Task<Void, Never>?
    private let turnSignalHub = TurnSignalHub()
    private let callActivity = CallActivityFlag()
    private var sharedSpeechSynthesizer: (any SpeechSynthesizing)?

    /// Return the conversation-call coordinator, building it on first
    /// use so ordinary dictation never constructs the call graph.
    private func ensureConversationCallCoordinator()
        -> ConversationCallCoordinator
    {
        if let conversationCallCoordinator { return conversationCallCoordinator }
        let recordingCoordinator = coordinator
        let created = ConversationCallCoordinator(
            contextProvider: AXAppContextProvider(),
            sessionResolver: AgentSessionResolver(
                processTable: LibprocProcessTable(),
                terminalFocusReader: AppleEventTerminalFocusReader()),
            pipeline: CurrentPipelineProxy { [weak self] in
                await MainActor.run { self?.pipeline }
            },
            signalHub: turnSignalHub,
            injectionObserver: textInjector,
            commandGate: callCommandGate,
            // The submit re-runs the pinned focus handshake: a user
            // clicking around between transcription and delivery must
            // not receive the Return in whatever window they reached.
            submitter: PinnedFocusSubmitter(
                focuser: AppleEventTerminalFocuser(),
                pinnedDelivery: { [weak self] in
                    let coordinator = await MainActor.run {
                        self?.conversationCallCoordinator
                    }
                    return await coordinator?.pinnedDelivery
                },
                wrapping: ReturnKeySubmitter()),
            watcher: TranscriptResponseWatcher(
                narratesInterimMessages: {
                    Settings.shared.interimNarrationEnabled
                }),
            cuePlayer: DictationSoundCallCues(feedback: soundFeedbackProvider),
            synthesizer: ensureSpeechSynthesizer(),
            farEndHub: farEndPlaybackHub,
            isDictationActive: {
                await recordingCoordinator.state != .idle
            },
            stopReadSession: { [weak self] in
                let readAloud = await MainActor.run {
                    self?.readAloudCoordinator
                }
                await readAloud?.stop()
            })
        conversationCallCoordinator = created
        hudController?.attachConversationCall(created)
        callObservationTask = Task { [weak self, callActivity] in
            for await state in await created.stateStream {
                guard !Task.isCancelled else { break }
                let active =
                    state == .listening || state == .waiting
                    || state == .speaking
                callActivity.setActive(active)
                await MainActor.run {
                    self?.menuBarController?.setConversationActive(active)
                }
            }
        }
        return created
    }

    /// Return the read-aloud coordinator, building it on first use so
    /// termination and dictation paths never construct the feature's
    /// graph just to stop a session that does not exist.
    private func ensureReadAloudCoordinator() -> ReadAloudCoordinator {
        if let readAloudCoordinator { return readAloudCoordinator }
        let recordingCoordinator = coordinator
        let created = ReadAloudCoordinator(
            contextProvider: AXAppContextProvider(),
            sources: [
                SelectionContentSource(
                    selectionReader: AXSelectionReader()),
                CopySelectionContentSource(
                    supportedBundleIDs: ["dev.zed.Zed"],
                    selectionReader: PasteboardCopySelectionReader()),
                CodingAgentTranscriptSource(
                    processTable: LibprocProcessTable(),
                    terminalFocusReader: AppleEventTerminalFocusReader()),
                ChatLastMessageContentSource(),
                WebAreaContentSource(
                    webReader: AXWebContentReader()),
            ],
            synthesizer: ensureSpeechSynthesizer(),
            isDictationActive: {
                await recordingCoordinator.state != .idle
            })
        readAloudCoordinator = created
        hudController?.attachReadAloud(created)
        readAloudObservationTask = Task { [weak self] in
            for await state in await created.stateStream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    // Guidance is not a stoppable session, so the menu
                    // offers "Stop Reading" only while one is active.
                    self?.menuBarController?.setReadAloudSpeaking(
                        state == .acquiring || state == .speaking)
                }
            }
        }
        return created
    }

    /// Return the one speech synthesizer read-aloud and conversation
    /// calls share, so stopping speech from either feature silences
    /// whatever is playing.
    private func ensureSpeechSynthesizer() -> any SpeechSynthesizing {
        if let sharedSpeechSynthesizer { return sharedSpeechSynthesizer }
        let created = makeSpeechSynthesizer()
        sharedSpeechSynthesizer = created
        return created
    }

    /// Build the read-aloud voice: the local Kokoro MLX voice when the
    /// model pack carries its weights and English G2P resources, else the
    /// system synthesizer.
    private func makeSpeechSynthesizer() -> any SpeechSynthesizing {
        // Cloud mode's voice streams from OpenAI — its users chose cloud
        // processing, often on machines that cannot run the local model —
        // with the system voice as the offline fallback. Local mode keeps
        // the voice on the machine. The mode is read per utterance.
        let cloudVoice = OpenAISpeechSynthesizer(
            apiKey: ServiceConfig.shared.openAIAPIKey ?? "",
            fallback: SystemSpeechSynthesizer(),
            farEndHub: farEndPlaybackHub)
        let localVoice = makeLocalVoice()
        return DictationModeSpeechSynthesizer(
            localVoice: localVoice,
            cloudVoice: cloudVoice,
            isCloudMode: { Settings.shared.dictationMode == .cloud })
    }

    /// The local voice: Kokoro when the model pack carries its weights
    /// and English G2P resources, else the system synthesizer.
    private func makeLocalVoice() -> any SpeechSynthesizing {
        #if arch(arm64)
        if let modelsRoot = Bundle.main.resourceURL?
            .appendingPathComponent("models")
        {
            let kokoro = modelsRoot.appendingPathComponent("kokoro-82m-bf16")
            let g2p = modelsRoot.appendingPathComponent("kokoro-g2p-en")
            let hasWeights = FileManager.default.fileExists(
                atPath: kokoro.appendingPathComponent(
                    "kokoro-v1_0.safetensors").path)
            let hasG2P = FileManager.default.fileExists(
                atPath: g2p.appendingPathComponent("us_gold.json").path)
            if hasWeights, hasG2P {
                Log.debug("[AppDelegate] Read-aloud local voice: Kokoro")
                return KokoroSpeechSynthesizer(
                    modelDirectory: kokoro,
                    g2pResourcesDirectory: g2p,
                    farEndHub: farEndPlaybackHub)
            }
        }
        #endif
        Log.debug("[AppDelegate] Read-aloud local voice: system synthesizer")
        return SystemSpeechSynthesizer()
    }

    private var hotkeyPipelineDriver: HotkeyPipelineDriver?
    private var hotkeyPipelineIdentity: ObjectIdentifier?
    private var dictationHotkeyPublicationRequested = false
    private var hotkeyReRegistrationGeneration: UInt = 0
    private var hotkeyReRegistrationTask: Task<Void, Never>?
    private var registeredModeHotkeyBinding: ShortcutBinding?
    private let transcriptBuffer = TranscriptBuffer()
    /// The recorder wraps the injector so a conversation call can
    /// observe the exact text a completed turn delivered.
    private let textInjector = InjectionRecorder(
        wrapping: SerializedTextInjector(base: AppTextInjector()))
    /// The gate wraps the delivery chain so a call turn whose
    /// utterance is a spoken meta-command executes instead of
    /// injecting; a content turn then focuses the pinned session at
    /// the instant of injection. Outside calls both layers pass text
    /// straight through.
    private lazy var callCommandGate = CallCommandGate(
        interpreter: PhraseMetaCommandInterpreter(),
        isCallTurnActive: { [callActivity] in callActivity.isActive },
        wrapping: PinnedFocusInjector(
            focuser: AppleEventTerminalFocuser(),
            contextProvider: AXAppContextProvider(),
            pinnedDelivery: { [weak self] in
                let coordinator = await MainActor.run {
                    self?.conversationCallCoordinator
                }
                return await coordinator?.pinnedDelivery
            },
            wrapping: textInjector))
    private let audioDeviceProvider = CoreAudioDeviceProvider()
    private let soundFeedbackProvider = SoundFeedbackProvider()
    private var pipeline: DictationPipeline?
    private var pendingSessionRecoveryPipeline: DictationPipeline?
    private var localModelRuntime: LocalModelRuntime?
    private var localModelPreloadTask: Task<Void, Never>?
    private var localModelsReady = true
    private var captureTransportReady = false
    private var captureTransportPreparationTask: Task<Void, Never>?
    private let pipelineRebuildQueue = AsyncLatestOperationQueue()
    private var pipelineRebuildTask: Task<Void, Never>?
    private var modeTransition = DictationModeTransition(
        effectiveMode: Settings.shared.dictationMode)
    private var modeSwitchTask: Task<Void, Never>?
    private var modeSwitchRequest: DictationModeTransition.Request?
    private var dictationHotkeyMaintenanceIDs: Set<UUID> = []
    private var terminationCaptureDrainTask: Task<Void, Never>?
    private var didFenceApplicationTermination = false
    private var didDrainCaptureForTermination = false

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
        let resolvedMode = DictationModeAvailability.resolveEffectiveMode(
            stored: modeTransition.effectiveMode,
            isLocalAvailable: DictationMode.isLocalAvailable)
        if resolvedMode != modeTransition.effectiveMode {
            modeTransition = DictationModeTransition(effectiveMode: resolvedMode)
            Settings.shared.dictationMode = resolvedMode
        }
        setupMenuBar()
        setupPipeline(mode: modeTransition.effectiveMode)
        setupUpdater()
        setupInAppMessages()
        setupSettings()
        setupMenuBarState()
        determineLaunchFlow()

        // Building the capture transport takes seconds when voice processing
        // is enabled. Prepare it before admitting the first dictation so the
        // opening words are not spoken while the mic is still starting.
        prepareCaptureTransport()
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
        localModelPreloadTask?.cancel()
        captureTransportPreparationTask?.cancel()
        unregisterHotkey()
        unregisterModeHotkey()
        unregisterReadAloudHotkey()
        unregisterConversationCallHotkey()
        readAloudObservationTask?.cancel()
        callObservationTask?.cancel()
        if let readAloud = readAloudCoordinator {
            Task { await readAloud.stop() }
        }
        if let call = conversationCallCoordinator {
            Task { await call.hangUp() }
        }
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
    /// permissions once onboarding is finished; a local user who quit before
    /// finishing resumes onboarding. Cloud mode requires a key — if one is
    /// stored, proceed; otherwise show onboarding.
    private func determineLaunchFlow() {
        if modeTransition.effectiveMode == .local && DictationMode.isLocalAvailable {
            if hasFinishedOnboarding {
                Log.debug("[AppDelegate] Local mode, checking permissions")
                checkPermissions()
            } else {
                Log.debug("[AppDelegate] Local mode not onboarded, resuming onboarding")
                showOnboarding()
            }
        } else if ServiceConfig.shared.isConfigured {
            Log.debug("[AppDelegate] API key present, checking permissions")
            checkPermissions()
        } else {
            Log.debug("[AppDelegate] No API key, showing onboarding")
            showOnboarding()
        }
    }

    /// Whether the user finished onboarding, or onboarded before the app
    /// recorded a completion flag. Fall back to granted permissions so an
    /// existing local-mode user is never sent back through onboarding.
    private var hasFinishedOnboarding: Bool {
        if Settings.shared.hasCompletedOnboarding { return true }
        return permissionProvider.checkAccessibility() == .granted
            && permissionProvider.checkMicrophone() == .granted
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
            Settings.shared.hasCompletedOnboarding = true
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

    /// Meeting point between voice-processed capture and speech
    /// playback: while the mic captures through the voice processing
    /// unit, narration renders through its output bus so the echo
    /// canceller subtracts it from the microphone as its own
    /// reference.
    private let farEndPlaybackHub = FarEndPlaybackHub()

    private lazy var audioProvider = AUHALAudioCaptureProvider(
        farEndHub: farEndPlaybackHub)
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

    private func setupPipeline(mode: DictationMode) {
        localModelsReady = mode != .local
        updateDictationReadiness()
        audioProvider.setAudioDeviceProvider(audioDeviceProvider)
        audioProvider.setSoundFeedbackProvider(soundFeedbackProvider)
        audioDeviceProvider.setAudioCaptureProvider(audioProvider)

        let language = Settings.shared.language.languageCode
        let composition: DictationComposition

        if mode == .local {
            // Local mode: on-device STT + fine-tuned MLX LLM polish.
            #if arch(arm64)
            Log.debug("[AppDelegate] Using local models (STT + MLX)")
            let modelManager = LocalModelManager()
            let bundledModelsRoot = Bundle.main.resourceURL?
                .appendingPathComponent("models")
            let captureProvider = audioProvider
            composition = DictationCompositionFactory.makeLocal(
                modelManager: modelManager,
                bundledModelsRoot: bundledModelsRoot,
                cycleInterval: DictationCompositionFactory.cycleInterval(
                    from: ProcessInfo.processInfo.environment),
                turnSignals: turnSignalHub,
                captureGain: { [weak captureProvider] in
                    captureProvider?.gainFactor ?? 1
                })
            localModelRuntime = composition.localRuntime
            if let runtime = composition.localRuntime {
                startModelPreload(runtime)
            }
            #else
            fatalError("Local mode requires Apple Silicon")
            #endif
        } else {
            // Cloud mode: OpenAI STT + cloud polish.
            composition = DictationCompositionFactory.makeCloud(
                apiKey: ServiceConfig.shared.openAIAPIKey ?? "",
                onSessionExpired: { [weak self] in
                    Task { @MainActor in self?.beginSessionRecovery() }
                },
                turnSignals: turnSignalHub)
        }

        let isLocal = mode == .local
        Log.debug(
            "[AppDelegate] setupPipeline: isLocal=\(isLocal), mode=\(mode.rawValue)")
        let newPipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: AXAppContextProvider(),
            backend: composition.backend,
            textInjector: callCommandGate,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            language: language,
            onSessionExpired: composition.onSessionExpired,
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
                Log.debug("[AppDelegate] Required local preload complete")
                self.localModelsReady = true
                self.updateDictationReadiness()
                self.publishDictationHotkeyIfReady()
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

    /// Prepare the physical capture transport before publishing the dictation
    /// hotkey. The preparation may finish before permissions are granted, so
    /// it is repeated from the permission callback as well.
    private func prepareCaptureTransport() {
        captureTransportPreparationTask?.cancel()
        captureTransportReady = false
        suspendDictationHotkeyAdmission()
        updateDictationReadiness()

        let captureProvider = audioProvider
        captureTransportPreparationTask = Task { @MainActor [weak self] in
            await captureProvider.prepareTransport()
            guard !Task.isCancelled, let self else { return }
            self.captureTransportReady = true
            self.updateDictationReadiness()
            self.publishDictationHotkeyIfReady()
        }
    }

    private var dictationReadiness: HUDDictationReadiness {
        if modeTransition.effectiveMode == .local, !localModelsReady {
            return .loadingLocalModels
        }
        if !captureTransportReady {
            return .preparingMicrophone
        }
        return .ready
    }

    private func updateDictationReadiness() {
        hudController?.setDictationReadiness(dictationReadiness)
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
        controller.setDictationReadiness(dictationReadiness)
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
        controller.viewModel.isIncognitoMode = modeTransition.effectiveMode == .local
        if let conversationCallCoordinator {
            controller.attachConversationCall(conversationCallCoordinator)
        }
        if let readAloudCoordinator {
            controller.attachReadAloud(readAloudCoordinator)
        }
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

        controller.onToggleIncognitoMode = { [weak self] in
            self?.toggleIncognitoMode()
        }

        controller.onReadAloud = { [weak self] in
            guard let self else { return }
            let readAloud = self.ensureReadAloudCoordinator()
            Task { await readAloud.toggle() }
        }

        controller.onStartConversation = { [weak self] in
            guard let self else { return }
            let call = self.ensureConversationCallCoordinator()
            Task { await call.toggle() }
        }

        updateModePresentation()
    }

    /// Toggle between cloud and incognito (on-device) dictation mode.
    private func toggleIncognitoMode() {
        let newMode: DictationMode = modeTransition.effectiveMode == .local
            ? .cloud : .local
        requestDictationMode(newMode)
    }

    private func handleModeShortcut() {
        toggleIncognitoMode()
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

        let isAvailable = DictationModeAvailability.isAvailable(
            for: newMode,
            isLocalAvailable: DictationMode.isLocalAvailable,
            isConfigured: ServiceConfig.shared.isConfigured)
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
        hudController?.viewModel.isIncognitoMode =
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
        controller.onHandsfreeShortcutChanged = { [weak self] in
            self?.hudController?.reRegisterHandsfreeShortcut()
            self?.reRegisterHotkey()
        }
        controller.onPasteShortcutChanged = { [weak self] in
            self?.hudController?.reRegisterPasteShortcut()
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
            self?.prepareCaptureTransport()
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
        let binding = Settings.shared.incognitoModeShortcutBinding
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
                    self?.handleModeShortcut()
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
        registerReadAloudHotkey()
        registerConversationCallHotkey()
        publishDictationHotkeyIfReady()
    }

    private func registerReadAloudHotkey() {
        guard !didFenceApplicationTermination else { return }
        let binding = Settings.shared.readAloudShortcutBinding
        guard registeredReadAloudBinding != binding else { return }

        unregisterReadAloudHotkey()
        let setting = HotkeySetting.modifierPlusKey(
            modifierFlags: binding.standardModifierFlags,
            keyCode: binding.keyCode,
            keyName: binding.label)
        do {
            try readAloudHotkeyProvider.register(with: setting) {
                [weak self] event in
                guard event == .pressed else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.ensureReadAloudCoordinator().toggle()
                }
            }
            registeredReadAloudBinding = binding
            Log.debug(
                "[AppDelegate] Read-aloud shortcut registered (\(binding.label))")
        } catch {
            readAloudHotkeyProvider.unregister()
            Log.debug(
                "[AppDelegate] Failed to register read-aloud shortcut: \(error)")
        }
    }

    private func unregisterReadAloudHotkey() {
        readAloudHotkeyProvider.unregister()
        registeredReadAloudBinding = nil
    }

    private func registerConversationCallHotkey() {
        guard !didFenceApplicationTermination else { return }
        let binding = Settings.shared.conversationCallShortcutBinding
        guard registeredCallBinding != binding else { return }

        unregisterConversationCallHotkey()
        let setting = HotkeySetting.modifierPlusKey(
            modifierFlags: binding.standardModifierFlags,
            keyCode: binding.keyCode,
            keyName: binding.label)
        do {
            try callHotkeyProvider.register(with: setting) {
                [weak self] event in
                guard event == .pressed else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.ensureConversationCallCoordinator().toggle()
                }
            }
            registeredCallBinding = binding
            Log.debug(
                "[AppDelegate] Conversation-call shortcut registered"
                    + " (\(binding.label))")
        } catch {
            callHotkeyProvider.unregister()
            Log.debug(
                "[AppDelegate] Failed to register conversation-call"
                    + " shortcut: \(error)")
        }
    }

    private func unregisterConversationCallHotkey() {
        callHotkeyProvider.unregister()
        registeredCallBinding = nil
    }

    private func publishDictationHotkeyIfReady() {
        guard !didFenceApplicationTermination else { return }
        guard dictationHotkeyPublicationRequested else { return }
        guard let pipeline else {
            Log.debug("[AppDelegate] Pipeline not initialized, cannot register hotkey")
            return
        }

        // Build the HUD before the readiness check so the user can see why
        // the dictation shortcut is temporarily unavailable.
        if hudController == nil {
            setupHUD()
        }
        let readiness = dictationReadiness
        hudController?.setDictationReadiness(readiness)
        guard readiness == .ready else {
            menuBarController?.setHotkeyRegistered(false)
            Log.debug(
                "[AppDelegate] Dictation hotkey waiting for "
                    + readiness.message)
            return
        }

        guard dictationHotkeyMaintenanceIDs.isEmpty else {
            suspendDictationHotkeyAdmission()
            Log.debug(
                "[AppDelegate] Dictation hotkey waiting for microphone maintenance")
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

        let pipelineRef = pipeline
        let hudRef = hudController
        let menuRef = menuBarController
        let driver = HotkeyPipelineDriver(
            pipeline: pipelineRef,
            heldSessionAccepted: { [weak self, weak hudRef] heldSession in
                if let readAloud = await self?.readAloudCoordinator {
                    await readAloud.stop()
                }
                // A coordinator that was never built has nothing to stop.
                await MainActor.run {
                    hudRef?.hotkeySessionAccepted(heldSession)
                }
            },
            sessionEnded: { [weak hudRef] sessionID in
                await MainActor.run {
                    hudRef?.sessionEnded(sessionID)
                }
            })

        let callActivity = callActivity
        do {
            try hotkeyProvider.registerTimestamped { [weak self] event, hostTime in
                // During a call the dictation key belongs to the call:
                // force-send while listening, barge-in while waiting or
                // speaking. The flag is read synchronously so press and
                // release stay ordered for the driver when no call runs.
                if callActivity.isActive {
                    if event == .pressed {
                        Task { @MainActor [weak self] in
                            await self?.conversationCallCoordinator?
                                .dictationKeyPressed()
                        }
                    }
                    return
                }
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
