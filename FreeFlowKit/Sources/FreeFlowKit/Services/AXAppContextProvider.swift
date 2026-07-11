import Foundation

#if canImport(AppKit)
    import AppKit
#endif

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Read the active application context using NSWorkspace and AXUIElement.
///
/// Assemble an `AppContext` snapshot within a latency budget. Each field
/// read has its own timeout so slow or unresponsive apps do not block the
/// entire context assembly. When a field times out, it is left nil and the
/// partial context is returned.
public final class AXAppContextProvider: AppContextProviding, @unchecked Sendable {

    /// Terminal apps where the AX text area reports visible buffer
    /// content instead of logical user input.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
    ]

    /// Maximum time in seconds for the entire context assembly.
    private let totalBudget: TimeInterval

    /// Maximum time in seconds for any single AX attribute read.
    private let perFieldTimeout: TimeInterval

    /// Create a context provider with the given latency budget.
    ///
    /// - Parameters:
    ///   - totalBudget: Seconds allowed for the entire context read (default 0.200).
    ///   - perFieldTimeout: Seconds allowed per individual field read (default 0.050).
    public init(totalBudget: TimeInterval = 0.200, perFieldTimeout: TimeInterval = 0.050) {
        self.totalBudget = totalBudget
        self.perFieldTimeout = perFieldTimeout
    }

    // MARK: - AppContextProviding

    public func readContext() async -> AppContext {
        #if canImport(AppKit)
            let result = await withTimeout(seconds: totalBudget) { [self] in
                await self.assembleContext()
            }
            return result ?? .empty
        #else
            return .empty
        #endif
    }

    // MARK: - Context Assembly

    #if canImport(AppKit)
        private func assembleContext() async -> AppContext {
            // Step 1: Read frontmost application (fast, no AX needed).
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return .empty
            }

            let bundleID = frontApp.bundleIdentifier ?? ""
            let appName = frontApp.localizedName ?? ""
            let pid = frontApp.processIdentifier

            // Step 2: Read AX-dependent fields concurrently with per-field timeouts.
            let appElement = AXElementHelper.applicationElement(pid: pid)

            async let windowTitleResult = readWindowTitle(appElement: appElement)
            async let browserURLResult = readBrowserURL(bundleID: bundleID, pid: pid)

            let windowTitle = await windowTitleResult
            let browserURL = await browserURLResult

            let fieldInfo: FocusedFieldInfo
            if Self.terminalBundleIDs.contains(bundleID) {
                Log.debug("[AXContext] Terminal app — skipping field content read")
                fieldInfo = .empty
            } else {
                fieldInfo = await readFocusedFieldInfo()
            }

            return AppContext(
                bundleID: bundleID,
                appName: appName,
                windowTitle: windowTitle ?? "",
                browserURL: browserURL,
                focusedFieldContent: fieldInfo.content,
                selectedText: fieldInfo.selectedText,
                cursorPosition: fieldInfo.cursorPosition
            )
        }
    #endif

    // MARK: - Window Title

    /// Read the title of the frontmost window for the given application element.
    private func readWindowTitle(appElement: AXUIElement) async -> String? {
        let result = await withTimeout(seconds: perFieldTimeout) {
            guard let window = AXElementHelper.focusedWindow(of: appElement) else {
                return nil as String?
            }
            return AXElementHelper.windowTitle(of: window)
        }
        return result ?? nil
    }

    // MARK: - Focused Field

    /// Hold the fields read from a focused text element.
    private struct FocusedFieldInfo: Sendable {
        var content: String?
        var selectedText: String?
        var cursorPosition: Int?

        static let empty = FocusedFieldInfo(
            content: nil, selectedText: nil, cursorPosition: nil)
    }

    /// Read text field information from the system-wide focused element.
    private func readFocusedFieldInfo() async -> FocusedFieldInfo {
        let result = await withTimeout(seconds: perFieldTimeout) {
            guard let focused = AXElementHelper.focusedElement() else {
                return FocusedFieldInfo.empty
            }

            guard AXElementHelper.isTextInput(focused) else {
                return FocusedFieldInfo.empty
            }

            let content = AXElementHelper.textContent(of: focused)
            let selectedText = AXElementHelper.selectedText(of: focused)
            let cursorPosition = AXElementHelper.cursorPosition(of: focused)

            return FocusedFieldInfo(
                content: content,
                selectedText: selectedText,
                cursorPosition: cursorPosition
            )
        }
        return result ?? .empty
    }

    // MARK: - Browser URL

    /// Read the browser URL, delegating to BrowserURLReader.
    private func readBrowserURL(bundleID: String, pid: pid_t) async -> String? {
        guard BrowserURLReader.isBrowser(bundleID: bundleID) else {
            return nil
        }
        let result = await withTimeout(seconds: perFieldTimeout) {
            BrowserURLReader.readURL(bundleID: bundleID, pid: pid)
        }
        return result ?? nil
    }
}
