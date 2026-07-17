import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// Collects system information and bounded mic diagnostics into a pre-filled
/// GitHub issue URL for one-click error reporting.
///
/// Used by the "Report an Issue..." menu item and the "Report this issue"
/// link on error screens. Follows the same pattern as "Contribute Mic Data"
/// but captures general diagnostics instead of mic-specific data.
public enum IssueDiagnostics {

    /// The GitHub repo where issues are filed.
    private static let repoURL = "https://github.com/mrinalwadhwa/unramble/issues/new"

    /// Build a GitHub issue URL pre-filled with diagnostics.
    ///
    /// - Parameters:
    ///   - title: A short summary for the issue title. Defaults to empty
    ///     so the user fills it in.
    ///   - micDiagnostics: Formatted mic diagnostic string from
    ///     `MicDiagnosticStore.formattedDiagnostics()`. Pass nil to omit.
    /// Result of building an issue URL with diagnostics.
    public struct IssueReport {
        /// The GitHub new-issue URL with pre-filled title and body.
        public let url: URL
        /// Full diagnostics string for the user to paste into the issue.
        public let diagnostics: String
    }

    /// - Returns: An `IssueReport` containing the GitHub URL and a
    ///   diagnostics string, or nil if URL construction fails. The
    ///   caller is responsible for copying diagnostics to the clipboard
    ///   and informing the user.
    public static func issueURL(
        title: String = "",
        micDiagnostics: String? = nil
    ) -> IssueReport? {
        let fullDiagnostics = buildFullDiagnostics(micDiagnostics: micDiagnostics)

        let body = buildURLBody()

        guard var components = URLComponents(string: repoURL) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "bug"),
        ]
        guard let url = components.url else { return nil }
        return IssueReport(url: url, diagnostics: fullDiagnostics)
    }

    // MARK: - Body

    /// Build a short body for the URL (stays under GitHub's URL length limit).
    private static func buildURLBody() -> String {
        var sections: [String] = []

        // What happened (user fills in).
        sections.append(
            """
            **What happened:**
            <!-- Describe what you were doing and what went wrong. -->

            """)

        // System info (compact, always fits).
        sections.append(
            """
            **System info:**
            ```
            \(systemInfo())
            ```
            """)

        // Prompt to paste full diagnostics from clipboard.
        sections.append(
            """
            **Diagnostics:**
            <!-- Diagnostics have been copied to your clipboard. Paste (⌘V) below this line and review before posting. -->

            """)

        return sections.joined(separator: "\n\n")
    }

    /// Build the full diagnostics string for the clipboard.
    private static func buildFullDiagnostics(
        micDiagnostics: String?
    ) -> String {
        var sections: [String] = []

        sections.append("**System info:**")
        sections.append("```\n\(systemInfo())\n```")

        // Mic diagnostics (if available).
        if let micDiagnostics, micDiagnostics != "No dictation sessions recorded yet." {
            sections.append(
                """
                <details>
                <summary>Mic diagnostics</summary>

                ```
                \(micDiagnostics)
                ```
                </details>
                """)
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - System Info

    /// Collect system information as a compact multi-line string.
    public static func systemInfo() -> String {
        let appVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
        let buildNumber =
            Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "unknown"
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let model = macModelIdentifier()
        let memory = ProcessInfo.processInfo.physicalMemory
        let memoryGB = String(format: "%.0f", Double(memory) / 1_073_741_824)
        let uptime = formatUptime(ProcessInfo.processInfo.systemUptime)

        return [
            "Unramble: \(appVersion) (\(buildNumber))",
            "macOS: \(macOS)",
            "Mac: \(model)",
            "Memory: \(memoryGB) GB",
            "Uptime: \(uptime)",
        ].joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private static func macModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private static func formatUptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
