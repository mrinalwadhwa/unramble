import Foundation

/// Pure policy for prepending a leading space before injected text, based on the
/// character before the cursor. Holds no Accessibility or AppKit state — the
/// caller supplies the field content and cursor position — so the spacing rules
/// unit-test in isolation.
struct InjectionSpacing {

    /// Return the text, prepending a leading space unless the character before
    /// the cursor already separates words (whitespace, an opening bracket or
    /// quote, a path separator) or the text itself starts with a space, a
    /// newline, or punctuation.
    ///
    /// - Parameters:
    ///   - text: The text to inject.
    ///   - fieldContent: The current content of the focused field.
    ///   - cursorPosition: The current cursor position in the field.
    /// - Returns: The text, potentially with a leading space prepended.
    func leadingSpaced(
        text: String,
        fieldContent: String?,
        cursorPosition: Int?
    ) -> String {
        guard let content = fieldContent, let pos = cursorPosition else {
            return text
        }

        // If cursor is at the start, no space needed
        guard pos > 0 else { return text }

        // Accessibility cursor positions are reported in UTF-16 code units,
        // not Swift Character offsets. Convert via the UTF-16 view so emoji
        // and other multi-scalar graphemes do not trap String indexing.
        guard let charBefore = characterBeforeUTF16Offset(in: content, utf16Offset: pos) else {
            return text
        }

        // If the text already starts with a space or newline, don't add another
        if text.hasPrefix(" ") || text.hasPrefix("\n") { return text }

        // If the text starts with punctuation, don't add a space before it
        if let first = text.first, first.isPunctuation { return text }

        // Characters that don't need a space after them
        let noSpaceAfter: Set<Character> = [
            " ", "\t", "\n", "\r",  // whitespace
            "(", "[", "{", "<",  // opening brackets
            "\"", "'", "`",  // opening quotes
            "/", "\\",  // path separators
        ]

        if noSpaceAfter.contains(charBefore) {
            return text
        }

        return " " + text
    }

    private func characterBeforeUTF16Offset(in content: String, utf16Offset: Int) -> Character? {
        guard utf16Offset > 0 else { return nil }

        let utf16 = content.utf16
        guard utf16Offset <= utf16.count else { return nil }

        let utf16Index = utf16.index(utf16.startIndex, offsetBy: utf16Offset)
        guard let stringIndex = String.Index(utf16Index, within: content),
            stringIndex > content.startIndex
        else {
            return nil
        }

        return content[content.index(before: stringIndex)]
    }
}
