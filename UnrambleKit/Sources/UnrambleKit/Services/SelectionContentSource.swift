import Foundation

/// Reads the user's current text selection as content to speak.
///
/// Prefers the selection captured in the snapshot at the hotkey press;
/// falls back to a live read that covers elements the snapshot skips,
/// such as selections in web pages and document viewers. For browser
/// selections, the page tree can restore paragraph boundaries lost by AX.
public struct SelectionContentSource: ContentSourceProviding {

    private let selectionReader: any SelectionReading
    private let webReader: (any WebContentReading)?
    private let paragraphLookupTimeout: TimeInterval

    public init(
        selectionReader: any SelectionReading,
        webReader: (any WebContentReading)? = nil,
        paragraphLookupTimeout: TimeInterval = 0.8
    ) {
        self.selectionReader = selectionReader
        self.webReader = webReader
        self.paragraphLookupTimeout = paragraphLookupTimeout
    }

    public func readContent(for context: AppContext) async throws
        -> ReadableContent?
    {
        let paragraphDeadline = ProcessInfo.processInfo.systemUptime + paragraphLookupTimeout
        let selection: String?
        let origin: String
        if let snapshotSelection = context.selectedText,
            !snapshotSelection.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        {
            selection = snapshotSelection
            origin = "snapshot"
        } else {
            selection = await selectionReader.readSelectedText()
            origin = "accessibility"
        }
        try Task.checkCancellation()

        guard let selection,
            !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        Log.debug(
            "[ReadAloudSelection] app=\(context.bundleID) origin=\(origin) "
                + SpeechDiagnostics.textStructure(selection))
        if let webReader, BrowserURLReader.isBrowser(bundleID: context.bundleID),
            let pid = context.processIdentifier
        {
            // Budget optional enrichment from the start of selection acquisition.
            // A slow selection read must not gain another full lookup timeout.
            let remaining = paragraphDeadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                Log.debug("[ReadAloudSelection] paragraphMatch=budgetExhausted keepingOriginal=true")
                try Task.checkCancellation()
                return ReadableContent(segments: [.init(kind: .prose, text: selection)])
            }
            let lookup = DetachedOperation<[ReadableContent.Segment]?> {
                guard let page = await webReader.readMainContent(processIdentifier: pid),
                    !Task.isCancelled
                else { return nil }
                return WebSelectionParagraphs.segments(for: selection, in: page)
            }
            switch await lookup.outcome(timeout: remaining) {
            case let .completed(segments):
                try Task.checkCancellation()
                if let segments {
                    Log.debug(
                        "[ReadAloudSelection] app=\(context.bundleID) "
                            + "paragraphMatch=unique paragraphs=\(segments.count)")
                    return ReadableContent(segments: segments)
                }
                Log.debug("[ReadAloudSelection] paragraphMatch=unavailable keepingOriginal=true")
            case .deadline:
                lookup.task.cancel()
                Log.debug("[ReadAloudSelection] paragraphMatch=timeout keepingOriginal=true")
            case .cancelled:
                lookup.task.cancel()
                throw CancellationError()
            }
        }
        try Task.checkCancellation()
        return ReadableContent(
            segments: [.init(kind: .prose, text: selection)])
    }
}
