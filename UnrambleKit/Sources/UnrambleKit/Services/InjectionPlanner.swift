import Foundation

/// Pure planning for splicing injected text into a text field's contents.
/// Given the field's current value, the current selection, and the cursor
/// position — all in the UTF-16 offsets the Accessibility APIs report — it
/// computes the field's new value and the resulting cursor position. Holds no
/// Accessibility or AppKit state, so the splice arithmetic unit-tests in
/// isolation.
struct InjectionPlanner {

    /// The result of planning an insertion: the field's new full value and the
    /// cursor position after the insertion, as a UTF-16 offset.
    struct Result: Equatable {
        let newValue: String
        let newCursorPosition: Int
    }

    /// Plan the insertion of `text` into `currentValue`.
    ///
    /// - When a selection of non-zero length is present, replace it.
    /// - Otherwise, when a cursor position is present, insert at the cursor.
    /// - Otherwise, append to the end.
    ///
    /// - Parameters:
    ///   - text: The text to insert.
    ///   - currentValue: The field's current full contents.
    ///   - selectedRange: The current selection in UTF-16 offsets, or nil.
    ///   - cursorPosition: The current cursor position, a UTF-16 offset, or nil.
    /// - Returns: The field's new value and the resulting cursor position.
    func plan(
        insert text: String,
        into currentValue: String,
        selectedRange: (location: Int, length: Int)?,
        cursorPosition: Int?
    ) -> Result {
        if let range = selectedRange, range.length > 0 {
            // Replace selected text (range is in UTF-16 offsets)
            let start = stringIndexFromUTF16Offset(in: currentValue, utf16Offset: range.location)
            let end = stringIndexFromUTF16Offset(
                in: currentValue, utf16Offset: range.location + range.length)
            var mutable = currentValue
            mutable.replaceSubrange(start..<end, with: text)
            return Result(
                newValue: mutable,
                newCursorPosition: range.location + utf16Count(of: text))
        } else if let pos = cursorPosition {
            // Insert at cursor position (pos is a UTF-16 offset)
            let index = stringIndexFromUTF16Offset(in: currentValue, utf16Offset: pos)
            var mutable = currentValue
            mutable.insert(contentsOf: text, at: index)
            return Result(
                newValue: mutable,
                newCursorPosition: pos + utf16Count(of: text))
        } else {
            // Append to end
            let newValue = currentValue + text
            return Result(newValue: newValue, newCursorPosition: utf16Count(of: newValue))
        }
    }

    /// Convert a UTF-16 offset to a String.Index, clamping to valid bounds.
    ///
    /// Accessibility APIs report positions in UTF-16 code units. This converts
    /// to a Swift String.Index suitable for string mutations. If the offset
    /// lands mid-grapheme, the index is rounded down to the nearest character
    /// boundary.
    private func stringIndexFromUTF16Offset(in string: String, utf16Offset: Int) -> String.Index {
        let utf16 = string.utf16
        let clamped = max(0, min(utf16Offset, utf16.count))
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: clamped)
        // Round down to the nearest Character boundary
        if let exact = String.Index(utf16Index, within: string) {
            return exact
        }
        // If we landed mid-grapheme, scan backward for a valid boundary
        var idx = utf16Index
        while idx > utf16.startIndex {
            utf16.formIndex(before: &idx)
            if let valid = String.Index(idx, within: string) {
                return valid
            }
        }
        return string.startIndex
    }

    /// Return the UTF-16 length of a string.
    ///
    /// Used to compute new cursor positions after string mutations, since
    /// Accessibility APIs expect UTF-16 offsets.
    private func utf16Count(of string: String) -> Int {
        return string.utf16.count
    }
}
