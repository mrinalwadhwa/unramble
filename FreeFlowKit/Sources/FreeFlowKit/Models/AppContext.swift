import Foundation

/// Captures the state of the active application at the moment dictation is triggered.
///
/// Populated by `AppContextProviding` and passed alongside audio data through the pipeline.
/// Fields are optional where the information may not be available (e.g. browser URL is only
/// present for browser apps, field content is only present when a text field is focused).
public struct AppContext: Sendable, Equatable {

    /// Bundle identifier of the frontmost application (e.g. "com.apple.Safari").
    public let bundleID: String

    /// Localized display name of the frontmost application (e.g. "Safari").
    public let appName: String

    /// Title of the frontmost window.
    public let windowTitle: String

    /// Current URL if the frontmost app is a browser.
    public let browserURL: String?

    /// Full text content of the focused text field, if one is focused.
    public let focusedFieldContent: String?

    /// Currently selected text within the focused field, if any.
    public let selectedText: String?

    /// Cursor (insertion point) position within the focused field.
    public let cursorPosition: Int?

    public init(
        bundleID: String,
        appName: String,
        windowTitle: String,
        browserURL: String? = nil,
        focusedFieldContent: String? = nil,
        selectedText: String? = nil,
        cursorPosition: Int? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.focusedFieldContent = focusedFieldContent
        self.selectedText = selectedText
        self.cursorPosition = cursorPosition
    }

    /// An empty context used as a placeholder when context reading is unavailable.
    public static let empty = AppContext(
        bundleID: "",
        appName: "",
        windowTitle: ""
    )

    /// Terminal apps where the AX text area reports visible buffer
    /// content instead of logical user input.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
    ]

    public var isTerminal: Bool {
        Self.terminalBundleIDs.contains(bundleID)
    }
}
