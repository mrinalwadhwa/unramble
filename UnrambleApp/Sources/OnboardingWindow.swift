import AppKit
import UnrambleKit
import WebKit

/// A window that hosts a WKWebView for onboarding. The web view loads
/// a bundled HTML page from the app resources and communicates with
/// native code via the OnboardingBridge message handler.
final class OnboardingWindow: NSWindow, WKNavigationDelegate {

    /// Called when the web view finishes loading the onboarding page.
    var onDidFinishNavigation: (() -> Void)?

    /// Called before a title-bar close hides the window. The controller uses
    /// this to release native resources that JavaScript cannot clean up once
    /// its bridge handler is removed.
    var onClose: (() -> Void)?

    private static func log(_ msg: String) {
        #if DEBUG
            Log.debug("[OnboardingWindow] \(msg)")
        #endif
    }

    /// The web view that displays bundled local pages.
    let webView: WKWebView

    /// The web view configuration, retained so the bridge message
    /// handler can be added before the first page load.
    private let webConfig: WKWebViewConfiguration

    /// Name of the WKScriptMessageHandler channel. JavaScript calls
    /// `window.webkit.messageHandlers.unramble.postMessage(...)` to send
    /// messages to native code.
    static let bridgeHandlerName = "unramble"

    /// Default window size for onboarding (matches the zone's
    /// onboarding page design at 480px width).
    private static let defaultSize = NSSize(width: 520, height: 800)

    /// Height of the transparent drag handle at the top of the window.
    private static let dragHandleHeight: CGFloat = 76

    // MARK: - Initialization

    /// Create a new onboarding window.
    ///
    /// The window is centered on screen, non-resizable, and has a
    /// title bar with close button but no minimize or zoom. It becomes
    /// the key window when shown.
    ///
    /// - Parameter bridge: The script message handler that receives
    ///   bridge messages from JavaScript. Pass an `OnboardingBridge`
    ///   instance. If nil, no bridge is registered (useful for testing).
    init(bridge: WKScriptMessageHandler? = nil) {
        let config = WKWebViewConfiguration()

        // Allow communication between the web page and native code.
        if let bridge {
            config.userContentController.add(bridge, name: Self.bridgeHandlerName)
        }

        self.webConfig = config
        self.webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let contentRect = NSRect(
            origin: .zero,
            size: Self.defaultSize
        )

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        backgroundColor = NSColor(
            red: 0xEE / 255.0, green: 0xEC / 255.0, blue: 0xEB / 255.0, alpha: 1.0)

        // Use a container view so we can layer the drag handle on top
        // of the web view. The drag handle is a transparent view that
        // covers the top of the window, providing a generous drag
        // target beyond the tiny hidden title bar.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        container.autoresizingMask = [.width, .height]

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let dragHandle = WindowDragHandleView(
            frame: NSRect(
                x: 0,
                y: Self.defaultSize.height - Self.dragHandleHeight,
                width: Self.defaultSize.width,
                height: Self.dragHandleHeight
            )
        )
        dragHandle.autoresizingMask = [.width, .minYMargin]
        container.addSubview(dragHandle)

        contentView = container
        positionRight()

        webView.navigationDelegate = self
    }

    /// Position the window on the right side of the screen, vertically
    /// centered, with a comfortable margin from the edge.
    private func positionRight() {
        guard let screen = NSScreen.main else {
            center()
            return
        }
        let visible = screen.visibleFrame
        let margin: CGFloat = 96
        let x = visible.maxX - frame.width - margin
        let y = visible.maxY - frame.height - margin
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Close override

    /// Override close to hide and clean up the web view. The close
    /// button (×) sends `close()`, which would deallocate the window
    /// while `OnboardingController` still holds a reference. Using
    /// `dismiss()` removes the bridge handler (freeing the WKWebView
    /// process) and hides the window so it can be re-presented via the
    /// menu bar "Open Setup…" item.
    override func close() {
        onClose?()
        if isVisible {
            dismiss()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Self.log("didStartProvisionalNavigation: \(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.log("didFinish: \(webView.url?.absoluteString ?? "nil")")
        onDidFinishNavigation?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log("didFail: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Allow bundled file:// resources. Open anything else in the
        // default browser so external URLs cannot access the bridge.
        if url.isFileURL {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
        }
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Self.log(
            "didFailProvisionalNavigation: \(error.localizedDescription) url=\(webView.url?.absoluteString ?? "nil")"
        )
    }

    // MARK: - Bundled pages

    /// Load the bundled onboarding HTML page from the app bundle.
    /// - Parameter query: Optional query string appended to the URL
    ///   (e.g. "mode=api-key-only").
    func loadBundledOnboarding(query: String? = nil) {
        guard
            let htmlURL = Bundle.main.url(
                forResource: "onboarding",
                withExtension: "html"
            )
        else {
            Self.log("onboarding.html not found in bundle")
            return
        }

        var loadURL = htmlURL
        if let query {
            var components = URLComponents(url: htmlURL, resolvingAgainstBaseURL: false)
            components?.query = query
            if let withQuery = components?.url {
                loadURL = withQuery
            }
        }

        Self.log("loadBundledOnboarding: \(loadURL.absoluteString)")
        webView.loadFileURL(
            loadURL,
            allowingReadAccessTo: htmlURL.deletingLastPathComponent()
        )
    }

    // MARK: - Presentation

    /// Show the window, make it key, and bring it to the front.
    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide the window and remove the bridge handler to break any
    /// reference cycles.
    ///
    /// Uses `orderOut` instead of `close` so SwiftUI's lifecycle does
    /// not see "last window closed" and terminate the app. The window
    /// is deallocated when the OnboardingController sets its reference
    /// to nil.
    func dismiss() {
        webConfig.userContentController.removeScriptMessageHandler(
            forName: Self.bridgeHandlerName
        )
        orderOut(nil)
    }
}

// MARK: - Drag Handle

/// A transparent view that enables window dragging from the top area.
///
/// Placed over the web view at the top of the window. Passes through
/// clicks to the web view for any interactive elements underneath, but
/// enables window dragging on the empty background area.
private final class WindowDragHandleView: NSView {

    /// Inset from the left edge to avoid covering the close button.
    private static let closeButtonInset: CGFloat = 68

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim hits in our frame — let everything else fall
        // through to the web view below.
        guard frame.contains(point) else { return nil }

        // Let the close button (top-left corner) receive clicks and
        // show the default arrow cursor instead of the drag hand.
        let localPoint = convert(point, from: superview)
        if localPoint.x < Self.closeButtonInset { return nil }

        return self
    }

    override func resetCursorRects() {
        // Cursor rect excludes the close button area on the left.
        let dragRect = NSRect(
            x: Self.closeButtonInset,
            y: 0,
            width: bounds.width - Self.closeButtonInset,
            height: bounds.height
        )
        addCursorRect(dragRect, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
