import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Read the current URL from browser applications.
///
/// Each supported browser requires a different approach to extract the URL:
/// - Safari, Chrome, Arc, Edge, Brave: AXUIElement traversal to find the address bar
/// - Firefox: AXUIElement with a different element hierarchy
///
/// Bundle IDs are mapped to extraction strategies so the context provider
/// can request the URL without knowing browser-specific details.
public enum BrowserURLReader {

    // MARK: - Supported Browsers

    /// Bundle IDs of browsers that support URL extraction.
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",  // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "app.zen-browser.zen",  // Zen Browser
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
    ]

    /// Check whether the given bundle ID belongs to a supported browser.
    public static func isBrowser(bundleID: String) -> Bool {
        return browserBundleIDs.contains(bundleID)
    }

    // MARK: - URL Reading

    /// Read the current URL from the browser with the given bundle ID and PID.
    ///
    /// - Parameters:
    ///   - bundleID: The browser's bundle identifier.
    ///   - pid: The browser's process ID.
    /// - Returns: The current URL string, or nil if it cannot be read.
    public static func readURL(bundleID: String, pid: pid_t) -> String? {
        guard isBrowser(bundleID: bundleID) else { return nil }

        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return readSafariURL(pid: pid)
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition":
            return readFirefoxURL(pid: pid)
        default:
            // Chrome, Edge, Brave, Arc all use Chromium's AX structure
            return readChromiumURL(pid: pid)
        }
    }

    // MARK: - Safari

    /// Read the URL from Safari's address bar via AXUIElement traversal.
    ///
    /// Safari exposes the URL in the focused window's toolbar. The element
    /// hierarchy is: AXWindow > AXToolbar > AXTextField (with AXDescription
    /// containing "address" or subrole AXSearchField).
    private static func readSafariURL(pid: pid_t) -> String? {
        let app = AXElementHelper.applicationElement(pid: pid)
        guard let window = AXElementHelper.focusedWindow(of: app) else { return nil }

        // Look for the toolbar first
        if let toolbar = findToolbar(in: window) {
            if let url = findURLFieldValue(in: toolbar) {
                return url
            }
        }

        // Fallback: search the entire window
        return findURLFieldValue(in: window)
    }

    // MARK: - Chromium-Based Browsers

    /// Read the URL from Chromium-based browsers (Chrome, Edge, Brave, Arc).
    ///
    /// Chromium browsers expose the URL in a text field within the toolbar.
    /// The element has role AXTextField and a description or title referencing
    /// "address" or "URL".
    private static func readChromiumURL(pid: pid_t) -> String? {
        let app = AXElementHelper.applicationElement(pid: pid)
        guard let window = AXElementHelper.focusedWindow(of: app) else { return nil }

        // Chromium puts the address bar in a toolbar or group
        if let toolbar = findToolbar(in: window) {
            if let url = findURLFieldValue(in: toolbar) {
                return url
            }
        }

        // Some Chromium variants nest differently; try the full window
        if let url = findURLFieldValue(in: window) {
            return url
        }

        // Arc has a unique structure; try finding any text field with a URL-like value
        return findURLLikeValue(in: window)
    }

    // MARK: - Firefox

    /// Read the URL from Firefox via AXUIElement traversal.
    ///
    /// Firefox uses a different AX tree structure. The URL bar is typically
    /// an AXTextField or AXComboBox within the toolbar area.
    private static func readFirefoxURL(pid: pid_t) -> String? {
        let app = AXElementHelper.applicationElement(pid: pid)
        guard let window = AXElementHelper.focusedWindow(of: app) else { return nil }

        // Firefox exposes the URL in a combo box or text field in the toolbar
        if let toolbar = findToolbar(in: window) {
            if let url = findFirefoxURLField(in: toolbar) {
                return url
            }
        }

        // Fallback: search the full window at limited depth
        return findFirefoxURLField(in: window)
    }

    // MARK: - Element Search Helpers

    /// Find the toolbar element within a window.
    private static func findToolbar(in window: AXUIElement) -> AXUIElement? {
        guard let children = AXElementHelper.children(of: window) else { return nil }
        for child in children {
            if AXElementHelper.role(of: child) == kAXToolbarRole {
                return child
            }
            // Some browsers wrap the toolbar in a group
            if AXElementHelper.role(of: child) == kAXGroupRole {
                if let grandchildren = AXElementHelper.children(of: child) {
                    for grandchild in grandchildren {
                        if AXElementHelper.role(of: grandchild) == kAXToolbarRole {
                            return grandchild
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Search for a URL text field in the given element tree.
    ///
    /// Look for text fields whose description contains "address", "URL",
    /// "location", or similar keywords.
    private static func findURLFieldValue(in root: AXUIElement) -> String? {
        let urlField = AXElementHelper.findElement(in: root, maxDepth: 6) { element in
            guard let role = AXElementHelper.role(of: element) else { return false }
            guard
                role == kAXTextFieldRole || role == kAXComboBoxRole
                    || role == "AXSearchField"
            else {
                return false
            }
            return isAddressField(element)
        }

        guard let field = urlField else { return nil }
        return AXElementHelper.stringValue(of: kAXValueAttribute, from: field)
    }

    /// Search for a URL field specific to Firefox's AX tree.
    private static func findFirefoxURLField(in root: AXUIElement) -> String? {
        let urlField = AXElementHelper.findElement(in: root, maxDepth: 6) { element in
            guard let role = AXElementHelper.role(of: element) else { return false }

            // Firefox uses AXComboBox or AXTextField for the URL bar
            guard role == kAXComboBoxRole || role == kAXTextFieldRole else {
                return false
            }

            // Check description for URL-related keywords
            if isAddressField(element) {
                return true
            }

            // Firefox sometimes labels it with a specific identifier
            if let identifier = AXElementHelper.stringValue(
                of: "AXIdentifier", from: element)
            {
                let lower = identifier.lowercased()
                if lower.contains("url") || lower.contains("address")
                    || lower.contains("location")
                {
                    return true
                }
            }

            return false
        }

        guard let field = urlField else { return nil }

        // For combo boxes, the value might be in a child text field
        if AXElementHelper.role(of: field) == kAXComboBoxRole {
            if let children = AXElementHelper.children(of: field) {
                for child in children {
                    if let value = AXElementHelper.stringValue(
                        of: kAXValueAttribute, from: child)
                    {
                        if looksLikeURL(value) {
                            return value
                        }
                    }
                }
            }
        }

        return AXElementHelper.stringValue(of: kAXValueAttribute, from: field)
    }

    /// Check whether an element's description, title, or subrole suggests it is an address bar.
    private static func isAddressField(_ element: AXUIElement) -> Bool {
        // Subrole check is language-independent — Chromium browsers mark
        // the address bar as AXSearchField.
        if let subrole = AXElementHelper.subrole(of: element),
            subrole == "AXSearchField"
        {
            return true
        }

        // Keywords in English plus common macOS localizations.
        let keywords = [
            // English
            "address", "url", "location", "search or enter", "search or type",
            // German
            "adresse", "suchen oder adresse",
            // French
            "adresse", "rechercher ou saisir",
            // Spanish
            "dirección", "buscar o escribir",
            // Portuguese
            "endereço", "pesquisar ou digitar",
            // Italian
            "indirizzo", "cerca o digita",
            // Dutch
            "adres", "zoeken of typen",
            // Swedish/Norwegian/Danish
            "adress", "sök eller skriv",
            // Japanese (partial — AX descriptions vary)
            "アドレス",
            // Chinese
            "地址", "搜索或输入",
            // Korean
            "주소", "검색 또는 입력",
        ]

        if let description = AXElementHelper.stringValue(
            of: kAXDescriptionAttribute, from: element)
        {
            let lower = description.lowercased()
            for keyword in keywords {
                if lower.contains(keyword) {
                    return true
                }
            }
        }

        if let title = AXElementHelper.stringValue(of: kAXTitleAttribute, from: element) {
            let lower = title.lowercased()
            for keyword in keywords {
                if lower.contains(keyword) {
                    return true
                }
            }
        }

        if let help = AXElementHelper.stringValue(of: kAXHelpAttribute, from: element) {
            let lower = help.lowercased()
            for keyword in keywords {
                if lower.contains(keyword) {
                    return true
                }
            }
        }

        return false
    }

    /// Search for any text field whose value looks like a URL.
    ///
    /// Fallback for browsers (e.g. Arc) with non-standard AX tree structures.
    private static func findURLLikeValue(in root: AXUIElement) -> String? {
        let field = AXElementHelper.findElement(in: root, maxDepth: 8) { element in
            guard let role = AXElementHelper.role(of: element) else { return false }
            guard
                role == kAXTextFieldRole || role == kAXStaticTextRole
                    || role == kAXComboBoxRole
            else {
                return false
            }
            guard
                let value = AXElementHelper.stringValue(
                    of: kAXValueAttribute, from: element)
            else {
                return false
            }
            return looksLikeURL(value)
        }

        guard let found = field else { return nil }
        return AXElementHelper.stringValue(of: kAXValueAttribute, from: found)
    }

    /// Heuristic check for whether a string looks like a URL.
    private static func looksLikeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return true
        }
        if trimmed.hasPrefix("file://") || trimmed.hasPrefix("ftp://") {
            return true
        }
        // Bare domains like "example.com/path"
        let domainPattern = #"^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(/|$)"#
        if trimmed.range(of: domainPattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
