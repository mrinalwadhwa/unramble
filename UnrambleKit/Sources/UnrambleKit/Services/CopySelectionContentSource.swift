import Foundation

/// Reads text through a temporary Copy command for explicitly supported
/// applications that do not expose selections through Accessibility.
///
/// The returned scope follows the application's Copy semantics. Zed returns the
/// selection when present and the current line when there is no selection.
public struct CopySelectionContentSource: ContentSourceProviding {

    private let supportedBundleIDs: Set<String>
    private let selectionReader: any CopySelectionReading

    public init(
        supportedBundleIDs: Set<String>,
        selectionReader: any CopySelectionReading
    ) {
        self.supportedBundleIDs = supportedBundleIDs
        self.selectionReader = selectionReader
    }

    public func readContent(for context: AppContext) async throws
        -> ReadableContent?
    {
        guard supportedBundleIDs.contains(context.bundleID) else { return nil }
        guard let selection = await selectionReader.copySelectedText(),
            !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        Log.debug(
            "[ReadAloudSelection] app=\(context.bundleID) origin=copy "
                + SpeechDiagnostics.textStructure(selection))
        return ReadableContent(
            segments: [.init(kind: .prose, text: selection)])
    }
}
