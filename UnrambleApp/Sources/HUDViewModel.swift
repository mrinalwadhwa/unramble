import AppKit
import Combine
import Foundation
import UnrambleKit
import SwiftUI

/// Smoothing factor for audio level metering. Higher values = more responsive,
/// lower values = smoother. Range 0.0 (frozen) to 1.0 (no smoothing).
private let audioLevelSmoothing: Float = 0.6

/// Derive `HUDVisualState` from pipeline state and UI-local signals.
///
/// The view model observes `RecordingCoordinator.sessionStateStream` and
/// combines it with hover, activation mode, and slow-processing timer to
/// produce the current `HUDVisualState`. SwiftUI views observe the published
/// properties.
///
/// Action closures (`onCancel`, `onStop`, `onDismiss`, `onClickToRecord`) are
/// set by the `HUDController` and invoked by SwiftUI button actions. This
/// keeps the view layer free of pipeline references.
@MainActor
final class HUDViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var visualState: HUDVisualState = .minimized
    @Published private(set) var isHovering: Bool = false
    @Published var isIncognitoMode: Bool = false
    @Published private(set) var isDictationRetryAvailable: Bool = false

    /// Current audio input level (0.0 to 1.0) for driving the waveform bars.
    /// Smoothed to avoid jittery animation. Reset to 0 when not recording.
    @Published private(set) var audioLevel: Float = 0

    /// The active microphone name to show in the callout, or nil when hidden.
    @Published private(set) var micCalloutName: String?

    /// An in-app message to display above the pill, or nil when hidden.
    @Published private(set) var inAppMessage: InAppMessage?

    // MARK: - Action closures (set by HUDController)

    /// Called when the user taps ✕ to cancel (listening hands-free or slow processing).
    var onCancel: (() -> Void)?

    /// Called when the user taps ■ to stop recording (listening hands-free).
    var onStop: (() -> Void)?

    /// Called when the user dismisses the no-target state (✕ or Escape).
    var onDismiss: (() -> Void)?

    /// Called when the user clicks the minimized/ready capsule to start hands-free.
    var onClickToRecord: (() -> Void)?

    /// Called when the user taps Retry in the dictation failed state.
    var onRetryDictation: (() -> Void)?

    /// Called when the user taps the in-app message body.
    var onMessageTapped: ((InAppMessage) -> Void)?

    /// Called when the user dismisses the in-app message via X.
    var onMessageDismissed: ((InAppMessage) -> Void)?

    // MARK: - Configuration

    let shortcuts: ShortcutConfiguration

    // MARK: - UI-local tracking

    /// Whether the current or most recent recording was initiated hands-free.
    private(set) var isHandsFree: Bool = false

    /// Whether this is the first recording since app launch (for mic callout).
    private(set) var isFirstRecording: Bool = true

    /// Whether the mic callout should show on the next recording transition.
    /// Set to true after a mic switch via the menu, reset after showing.
    private(set) var showMicCalloutOnNextRecording: Bool = false

    // MARK: - In-app message

    private var messageService: InAppMessageService?
    private var hasShownMessageToday: Bool = false

    /// Set the message service for fetching in-app announcements.
    func setMessageService(_ service: InAppMessageService?) {
        self.messageService = service
    }

    // MARK: - Pipeline references

    private var pipelineState: RecordingState = .idle
    private(set) var pipelineSessionID: DictationSessionID?

    // MARK: - Audio level

    /// The audio provider whose `audioLevelStream` we observe while recording.
    private var audioProvider: AudioProviding?
    private var audioLevelTask: Task<Void, Never>?

    // MARK: - Timers

    /// Duration the mic callout stays visible before auto-dismissing.
    private let micCalloutDuration: TimeInterval

    private var breathingTask: Task<Void, Never>?
    private var breathingFired = false

    private var slowProcessingTask: Task<Void, Never>?
    private var slowProcessingFired = false

    private var hoverGraceTask: Task<Void, Never>?
    private var micCalloutTask: Task<Void, Never>?

    // MARK: - Observation

    private var observationTask: Task<Void, Never>?

    /// Set the audio provider so we can observe its level stream during recording.
    func setAudioProvider(_ provider: AudioProviding?) {
        self.audioProvider = provider
    }

    // MARK: - Init

    init(
        shortcuts: ShortcutConfiguration = .default,
        micCalloutDuration: TimeInterval = 3.0
    ) {
        self.shortcuts = shortcuts
        self.micCalloutDuration = micCalloutDuration
    }

    // MARK: - Observation lifecycle

    /// Begin observing a coordinator's state stream to drive visual state.
    func observe(coordinator: RecordingCoordinator) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await update in await coordinator.sessionStateStream {
                guard !Task.isCancelled else { break }
                self?.handlePipelineState(update)
            }
        }
    }

    /// Stop observing and reset to minimized.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        breathingTask?.cancel()
        breathingTask = nil
        slowProcessingTask?.cancel()
        slowProcessingTask = nil
        hoverGraceTask?.cancel()
        hoverGraceTask = nil
        micCalloutTask?.cancel()
        micCalloutTask = nil
        stopAudioLevelObservation()
        pipelineState = .idle
        pipelineSessionID = nil
        breathingFired = false
        slowProcessingFired = false
        inAppMessage = nil
        micCalloutName = nil
        visualState = .minimized
    }

    // MARK: - UI-local inputs

    /// Called when the mouse enters the HUD area.
    /// A short delay prevents the tooltip from flashing on casual mouse movement.
    func mouseEntered() {
        hoverGraceTask?.cancel()
        hoverGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)  // 0.6s
            guard !Task.isCancelled else { return }
            self?.isHovering = true
            self?.recalculate()
        }
    }

    /// Called when the mouse exits the HUD area.
    func mouseExited() {
        hoverGraceTask?.cancel()
        // Short grace period so the HUD does not flicker on casual mouse movement.
        hoverGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
            guard !Task.isCancelled else { return }
            self?.isHovering = false
            self?.recalculate()
        }
    }

    /// Called when the user clicks the minimized HUD to start hands-free dictation.
    func clickedToStartHandsFree() {
        isHandsFree = true
        recalculate()
    }

    /// Called when push-to-talk recording begins (hotkey held).
    func hotkeyHeld() {
        isHandsFree = false
        recalculate()
    }

    func setDictationRetryAvailable(_ isAvailable: Bool) {
        isDictationRetryAvailable = isAvailable
    }

    // MARK: - Pipeline state handling

    private func handlePipelineState(_ update: RecordingStateUpdate) {
        let state = update.state
        let previous = pipelineState
        pipelineState = state
        pipelineSessionID = state == .idle ? nil : update.sessionID
        let t = CFAbsoluteTimeGetCurrent()
        Log.debug("[HUD] State changed: \(previous) → \(state) at \(t)")

        // Cancel processing timers when leaving processing.
        if state != .processing {
            breathingTask?.cancel()
            breathingTask = nil
            breathingFired = false
            slowProcessingTask?.cancel()
            slowProcessingTask = nil
            slowProcessingFired = false
            processingCollapsing = false
        }

        switch state {
        case .idle:
            // Successful injection or cancellation — collapse to minimized.
            stopAudioLevelObservation()
            visualState = .minimized

        case .recording:
            if previous == .idle {
                // Show mic callout on first recording or after a mic switch.
                if isFirstRecording || showMicCalloutOnNextRecording {
                    showMicCallout()
                }
                startAudioLevelObservation()
            }
            recalculate()
            Log.debug("[HUD] Visual state now: \(visualState)")

        case .processing:
            stopAudioLevelObservation()
            processingCollapsing = true
            startBreathingTimer()
            recalculate()

        case .injecting:
            // Injection is committed — the text will appear momentarily.
            // Collapse the pill now rather than waiting for the clipboard
            // restore delay (~200ms) and the idle transition. This makes
            // the pill disappear in sync with the text appearing instead
            // of lingering in the processing state.
            stopAudioLevelObservation()
            visualState = .minimized
            showInAppMessageIfNeeded()

        case .injectionFailed:
            recalculate()

        case .sessionExpired:
            stopAudioLevelObservation()
            recalculate()

        case .dictationFailed:
            stopAudioLevelObservation()
            recalculate()
        }
    }

    // MARK: - Processing timers

    /// Whether the pill is in the optimistic collapsing phase.
    /// Set to `true` on `.processing` entry, cleared when the breathing
    /// timer fires (~0.6s).
    private var processingCollapsing = false

    /// Start the breathing timer. After ~0.6s the pill finishes collapsing
    /// and enters the breathing pulse phase. After another ~5s without a
    /// result, transition to the slow-processing expanded pill.
    private func startBreathingTimer() {
        breathingTask?.cancel()
        breathingFired = false
        slowProcessingTask?.cancel()
        slowProcessingFired = false

        breathingTask = Task { [weak self] in
            // 0.6s — collapsing animation finishes, enter breathing.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.processingCollapsing = false
            self?.breathingFired = true
            self?.recalculate()

            // 8s — if still processing, show "Still working…".
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.slowProcessingFired = true
            self?.recalculate()
        }
    }

    // MARK: - State derivation

    /// Recompute `visualState` from all inputs.
    private func recalculate() {
        visualState = deriveVisualState()
    }

    private func deriveVisualState() -> HUDVisualState {
        switch pipelineState {
        case .idle:
            if isHovering {
                return .ready
            }
            return .minimized

        case .recording:
            if isHandsFree {
                return .listeningHandsFree
            }
            return .listeningHeld

        case .processing, .injecting:
            if processingCollapsing {
                return .processingCollapsing
            }
            if slowProcessingFired {
                return .processingSlow
            }
            if breathingFired {
                return .processingBreathing
            }
            // Between collapsing clearing and breathingFired setting,
            // or before any timer fires — treat as breathing.
            return .processingBreathing

        case .injectionFailed:
            return .noTarget

        case .sessionExpired:
            return .sessionExpired

        case .dictationFailed:
            return .dictationFailed
        }
    }

    // MARK: - In-app message display

    /// Show an in-app message after the first successful dictation of the day.
    /// In test mode, shows on every dictation. The message stays visible
    /// until the user taps the action or dismiss.
    private func showInAppMessageIfNeeded() {
        let testMode = messageService?.isTestMode ?? false
        guard testMode || !hasShownMessageToday else { return }
        guard let message = messageService?.messageToShow() else { return }

        hasShownMessageToday = true
        messageService?.markShownToday()
        inAppMessage = message
    }

    /// Dismiss the in-app message when the user taps the action.
    func tapInAppMessage() {
        guard let message = inAppMessage else { return }
        inAppMessage = nil
        onMessageTapped?(message)
    }

    /// Dismiss the in-app message permanently when the user taps Dismiss.
    func dismissInAppMessage() {
        guard let message = inAppMessage else { return }
        inAppMessage = nil
        onMessageDismissed?(message)
    }

    // MARK: - Mic callout

    /// The name of the active microphone. Set by the controller when a
    /// device provider is available.
    var activeMicName: String?

    /// Mark that the user switched microphones, so the callout shows on the
    /// next recording.
    func requestMicCallout() {
        showMicCalloutOnNextRecording = true
    }

    /// Show the mic callout tooltip and schedule auto-dismiss.
    private func showMicCallout() {
        guard let name = activeMicName, !name.isEmpty else { return }

        isFirstRecording = false
        showMicCalloutOnNextRecording = false
        micCalloutName = name

        micCalloutTask?.cancel()
        micCalloutTask = Task { [weak self, micCalloutDuration] in
            try? await Task.sleep(
                nanoseconds: UInt64(micCalloutDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.micCalloutName = nil
        }
    }

    /// Dismiss the mic callout immediately (e.g. when the user taps it).
    func dismissMicCallout() {
        micCalloutTask?.cancel()
        micCalloutTask = nil
        micCalloutName = nil
    }

    // MARK: - Audio level observation

    private func startAudioLevelObservation() {
        audioLevelTask?.cancel()
        audioLevel = 0
        let provider = audioProvider
        guard let sessionID = pipelineSessionID else { return }
        let owner = AudioCaptureOwner.dictation(sessionID)
        audioLevelTask = Task { [weak self] in
            // The audio level stream is created inside
            // audioProvider.startRecording(), which runs in a detached
            // task after the coordinator emits .recording. Wait for this
            // exact session's stream; a preview stream must never drive HUD.
            var stream: AsyncStream<Float>?
            while !Task.isCancelled {
                stream = provider?.audioLevelStream(owner: owner)
                if stream != nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled, let stream else { return }

            for await level in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard self.pipelineSessionID == sessionID else { break }
                // Exponential smoothing to avoid jitter.
                let smoothed =
                    audioLevelSmoothing * level
                    + (1.0 - audioLevelSmoothing) * self.audioLevel
                self.audioLevel = smoothed
            }
        }
    }

    private func stopAudioLevelObservation() {
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevel = 0
    }

    deinit {
        observationTask?.cancel()
        breathingTask?.cancel()
        slowProcessingTask?.cancel()
        hoverGraceTask?.cancel()
        micCalloutTask?.cancel()
        audioLevelTask?.cancel()
    }
}
