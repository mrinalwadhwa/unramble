import Foundation

/// Visual states for the HUD overlay.
///
/// Derived from `RecordingState` (pipeline) combined with UI-local signals:
/// hover, activation mode (held vs hands-free), slow-processing timer, and
/// injection failure. The HUD controller owns this derivation; UnrambleKit
/// knows nothing about these states.
enum HUDVisualState: Equatable {

    /// Tiny capsule outline. The app is alive and idle. Accepts hover and click.
    case minimized

    /// Expanded pill with hotkey hint. Shown when hovering the minimized capsule.
    case ready

    /// Push-to-talk listening. Waveform dots, no buttons. Keyboard owns this state.
    case listeningHeld

    /// Hands-free listening. Waveform dots with ✕ (cancel) and ■ (stop) buttons.
    case listeningHandsFree

    /// STT in flight, fast path. The pill optimistically collapses toward
    /// minimized dimensions over ~0.6s, anticipating a quick result. No
    /// content inside the pill; the shrinking itself is the visual signal.
    /// If the result arrives during the collapse, the snap to minimized is
    /// nearly imperceptible. If ~0.6s passes without a result, transitions
    /// to `.processingBreathing`.
    case processingCollapsing

    /// STT in flight, breathing phase. The pill stays at minimized dimensions
    /// but shows a gentle breathing pulse (opacity/scale) for ~5 seconds.
    /// Signals that work is happening without being intrusive. If the result
    /// arrives during this phase, the transition to minimized is smooth.
    /// If ~5s passes without a result, transitions to `.processingSlow`.
    case processingBreathing

    /// STT in flight, slow path (threshold exceeded). Shows reassurance message
    /// and ✕ cancel affordance.
    case processingSlow

    /// Injection failed — no focused text field. Shows paste-shortcut hint and ✕ dismiss.
    case noTarget

    /// Session token expired or rejected. Shows "Session expired" message briefly
    /// before the app enters the recovery flow (sign-in or onboarding).
    case sessionExpired

    /// Dictation failed after all transcription paths were exhausted.
    /// Shows "Lost connection" message with Retry and Dismiss buttons.
    case dictationFailed

    /// Whether the HUD should accept mouse events in this state.
    ///
    /// States that rely on the keyboard as the control surface disable mouse
    /// events so clicks pass through to the app underneath.
    var acceptsMouseEvents: Bool {
        switch self {
        case .minimized, .ready, .listeningHandsFree, .processingSlow, .noTarget,
            .sessionExpired, .dictationFailed:
            return true
        case .listeningHeld, .processingCollapsing, .processingBreathing:
            return false
        }
    }

    /// Whether the pill should show at its expanded width.
    ///
    /// Minimized and ready use the compact capsule (ready adds a tooltip
    /// above it). All other states expand the pill to show content
    /// (waveform, buttons, or messages).
    var isExpanded: Bool {
        switch self {
        case .minimized, .ready, .processingCollapsing, .processingBreathing:
            return false
        case .listeningHeld, .listeningHandsFree, .processingSlow, .noTarget,
            .sessionExpired, .dictationFailed:
            return true
        }
    }
}
