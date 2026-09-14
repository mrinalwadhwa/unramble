import Foundation

/// Restore page block boundaries without adding words outside the selection.
/// Browsers can flatten AXSelectedText even when their page tree has paragraphs.
enum WebSelectionParagraphs {
    static func segments(
        for selection: String,
        in page: ReadableContent
    ) -> [ReadableContent.Segment]? {
        // Ignore whitespace only when matching. Output always slices the
        // original selection, preserving its wording and inline whitespace.
        let selectedIndices = selection.indices.filter { !selection[$0].isWhitespace }
        let selectedCharacters = selectedIndices.map { selection[$0] }
        let compactSelection = String(selectedCharacters)
        // Joining characters can combine Unicode marks or regional indicators.
        // Reject changed character boundaries rather than map unsafe offsets.
        guard !compactSelection.isEmpty,
            compactSelection.elementsEqual(selectedCharacters)
        else { return nil }

        var compactPage = ""
        var pageCharacters: [Character] = []
        var boundaries: [Int] = []
        var characterCount = 0
        for segment in page.segments {
            guard !Task.isCancelled else { return nil }
            let compact = String(segment.text.filter { !$0.isWhitespace })
            guard !compact.isEmpty else { continue }
            if characterCount > 0 { boundaries.append(characterCount) }
            compactPage += compact
            pageCharacters.append(contentsOf: compact)
            characterCount += compact.count
        }
        guard compactPage.elementsEqual(pageCharacters) else { return nil }

        guard let match = compactPage.range(of: compactSelection, options: .literal) else {
            return nil
        }
        // Repeated passages cannot be placed safely without selection positions.
        // Include overlapping matches in this check.
        let nextStart = compactPage.index(after: match.lowerBound)
        guard compactPage.range(
            of: compactSelection, options: .literal,
            range: nextStart..<compactPage.endIndex) == nil
        else { return nil }

        let start = compactPage.distance(from: compactPage.startIndex, to: match.lowerBound)
        let end = start + selectedIndices.count
        let cuts = boundaries.filter { $0 > start && $0 < end }
            .map { selectedIndices[$0 - start] }

        var segments: [ReadableContent.Segment] = []
        var pieceStart = selection.startIndex
        for pieceEnd in cuts + [selection.endIndex] {
            let piece = String(selection[pieceStart..<pieceEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(.init(kind: .prose, text: piece))
            pieceStart = pieceEnd
        }
        return segments
    }
}
