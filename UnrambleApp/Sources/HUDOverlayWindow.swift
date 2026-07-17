import AppKit
import UnrambleKit
import SwiftUI

/// A floating borderless panel that displays the always-visible HUD overlay.
///
/// The HUD is a pill-shaped overlay anchored at the bottom center of the
/// active screen. The window always uses the expanded size so that the
/// NSPanel frame never moves or resizes during state transitions. All
/// visual size changes (minimized capsule vs expanded pill) are handled
/// entirely by SwiftUI within the fixed frame. This eliminates the
/// AppKit/SwiftUI animation conflict that caused content to "fly" during
/// state transitions.
///
/// Hover detection is handled externally by `HUDController` via global
/// mouse position polling and the `isMouseOverVisibleContent(_:)` method.
/// This is more reliable than NSTrackingArea on transparent non-activating
/// panels with large invisible regions.
final class HUDOverlayWindow: NSPanel {

    private let viewModel: HUDViewModel
    private var hostingView: NSHostingView<HUDContentView>?

    /// The window always uses the expanded dimensions so the frame never
    /// The window is sized large enough to contain the pill at any state
    /// plus overlays (tooltip, mic callout) above it without clipping.
    private static let fixedWidth: CGFloat = 400
    private static let fixedHeight: CGFloat = 240

    /// Dimensions of the minimized capsule rendered by SwiftUI.
    private static let minimizedCapsuleWidth: CGFloat = 46
    private static let minimizedCapsuleHeight: CGFloat = 8

    /// Extra height added when the mic callout tooltip is visible above the pill.
    private static let micCalloutExtraHeight: CGFloat = 30

    /// Extra height added when the in-app message tooltip is visible above the pill.
    private static let messageExtraHeight: CGFloat = 0

    /// Distance from the bottom of the visible screen frame to the bottom
    /// of the window. The minimized capsule sits at the bottom of the
    /// window (bottom-aligned VStack), so this controls how far above the
    /// screen edge it appears.
    private static let capsuleBottomInset: CGFloat = 14

    init(viewModel: HUDViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.fixedWidth,
                height: Self.fixedHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none

        let hosting = NSHostingView(rootView: HUDContentView(viewModel: viewModel))
        hosting.frame = contentRect(forFrameRect: frame)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        hostingView = hosting

        positionOnCurrentScreen()
        orderFrontRegardless()
    }

    // MARK: - Positioning

    /// Position the HUD at the bottom center of the screen containing the
    /// mouse cursor. The window size is always fixed; only the origin changes.
    func positionOnCurrentScreen() {
        guard let screen = activeScreen() else { return }
        let screenFrame = screen.visibleFrame
        let size = currentSize()
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.origin.y + Self.capsuleBottomInset
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// Update state-dependent properties (mouse event pass-through) and
    /// reposition the window if the mic callout changes the required height.
    /// No frame animation is performed — the window frame only changes when
    /// the mic callout appears/disappears (a height bump) or on screen change.
    func animateToCurrentState() {
        let state = viewModel.visualState

        // When minimized, ready, or noTarget, the window ignores mouse
        // events so clicks pass through to apps behind. Hover and
        // click interactions are handled by the controller's polling
        // loop and global click monitor. In active expanded states
        // with buttons (listening, processing), the window accepts
        // mouse events directly.
        let hasMessage = viewModel.inAppMessage != nil
        if hasMessage {
            // Accept mouse events when the message tooltip is visible
            // so the dismiss button and tap gesture receive clicks.
            ignoresMouseEvents = false
        } else if state == .minimized || state == .ready || state == .noTarget
            || state == .processingCollapsing
        {
            ignoresMouseEvents = true
        } else {
            ignoresMouseEvents = !state.acceptsMouseEvents
        }

        // Resize only if the mic callout toggled (height change).
        let needed = currentSize()
        if abs(frame.size.height - needed.height) > 1
            || abs(frame.size.width - needed.width) > 1
        {
            guard let screen = activeScreen() else { return }
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - needed.width / 2
            let y = screenFrame.origin.y + Self.capsuleBottomInset
            setFrame(
                NSRect(x: x, y: y, width: needed.width, height: needed.height),
                display: true
            )
        }
    }

    /// Jump the pill to the correct screen instantly without animation.
    /// Used when the mouse moves between monitors.
    func repositionToCurrentScreen() {
        positionOnCurrentScreen()
    }

    // MARK: - Hover hit testing

    /// Check whether a screen-coordinate point falls within the visible
    /// content area of the HUD.
    ///
    /// When minimized, only the small capsule region at the bottom center
    /// of the window counts as a hit (with generous padding so the user
    /// does not have to pixel-hunt). When expanded, the full pill area
    /// is considered a hit.
    ///
    /// - Parameter screenPoint: A point in screen (global) coordinates,
    ///   e.g. from `NSEvent.mouseLocation`.
    /// - Returns: `true` if the point is over visible content.
    func isMouseOverVisibleContent(_ screenPoint: NSPoint) -> Bool {
        // Convert screen point to window coordinates.
        let windowPoint = convertPoint(fromScreen: screenPoint)
        let state = viewModel.visualState

        // Determine the visible pill dimensions based on state.
        let pillWidth: CGFloat
        let pillHeight: CGFloat
        let padding: CGFloat

        switch state {
        case .minimized:
            pillWidth = Self.minimizedCapsuleWidth
            pillHeight = Self.minimizedCapsuleHeight
            padding = 10
        case .ready:
            // Use the same small capsule hit rect as minimized so clicks
            // only register on the actual capsule, not the wider hover area.
            pillWidth = Self.minimizedCapsuleWidth
            pillHeight = Self.minimizedCapsuleHeight
            padding = 10
        case .processingCollapsing, .processingBreathing:
            pillWidth = Self.minimizedCapsuleWidth
            pillHeight = Self.minimizedCapsuleHeight
            padding = 10
        case .listeningHeld:
            pillWidth = 80
            pillHeight = 32
            padding = 4
        case .listeningHandsFree:
            pillWidth = 140
            pillHeight = 32
            padding = 4
        case .processingSlow:
            pillWidth = 180
            pillHeight = 32
            padding = 4
        case .noTarget:
            pillWidth = 260
            pillHeight = 32
            padding = 4
        case .sessionExpired:
            pillWidth = 200
            pillHeight = 32
            padding = 4
        case .dictationFailed:
            pillWidth = 220
            pillHeight = 32
            padding = 4
        }

        // The pill is centered horizontally and bottom-aligned in the window.
        let pillX = (Self.fixedWidth - pillWidth) / 2
        let pillY: CGFloat = 0
        let hitRect = NSRect(
            x: pillX - padding,
            y: pillY - padding,
            width: pillWidth + padding * 2,
            height: pillHeight + padding * 2
        )
        return hitRect.contains(windowPoint)
    }

    // MARK: - Mouse events for expanded interactive states

    override func mouseDown(with event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        guard isMouseOverVisibleContent(screenPoint) else { return }
        if viewModel.visualState == .ready {
            viewModel.onClickToRecord?()
            return
        }
        // Forward to SwiftUI so buttons (cancel, stop, dismiss) receive clicks.
        super.mouseDown(with: event)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Helpers

    private func currentSize() -> NSSize {
        let calloutExtra: CGFloat =
            viewModel.micCalloutName != nil
            ? Self.micCalloutExtraHeight : 0

        let messageExtra: CGFloat =
            viewModel.inAppMessage != nil
            ? Self.messageExtraHeight : 0

        return NSSize(
            width: Self.fixedWidth,
            height: Self.fixedHeight + calloutExtra + messageExtra
        )
    }

    private func activeScreen() -> NSScreen? {
        // Follow the mouse cursor to match the screen the user is working on.
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
