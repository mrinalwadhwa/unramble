import Foundation

/// Track the committed (stable) prefix of a growing streaming transcript.
///
/// Streaming ASR revises text near the live edge as more audio arrives
/// but leaves older text stable. Feed each cycle's full transcript; the
/// tracker returns the sentences that have newly become safe to commit.
///
/// A sentence is safe to commit only when it is BOTH:
///   - **stable** — identical (normalized) to the same sentence in the
///     previous cycle, so the recognizer has stopped revising it, and
///   - **complete** — followed by at least one more sentence in the
///     current transcript, which proves the sentence actually ended.
///     This guards against a false terminator that a later cycle
///     extends, e.g. "…before our sync." becoming
///     "…before our sync tomorrow.".
///
/// Text without sentence terminators — such as a list dictated with
/// "new line" between items — never gains a following sentence, so it
/// stays uncommitted until the list closes with a real sentence. That
/// keeps holistic formatting (lists) polished as a single unit.
///
/// The tracker is forward-only: `committed` never decreases, so once a
/// sentence is committed (and, in the streaming provider, injected) it
/// is never revised.
public struct CommitTracker: Sendable {

    private var previous: [String] = []
    private var committedCount = 0

    public init() {}

    /// Number of sentences committed so far.
    public var committed: Int { committedCount }

    /// Ingest a new full transcript from a background cycle. Return the
    /// sentences that have newly become safe to commit (empty when
    /// nothing new is stable yet).
    public mutating func ingest(_ transcript: String) -> [String] {
        let current = Self.splitIntoSentences(transcript)
        var i = committedCount
        while i < previous.count,
            i < current.count - 1,
            Self.normalize(current[i]) == Self.normalize(previous[i])
        {
            i += 1
        }
        let newly = i > committedCount
            ? Array(current[committedCount..<i]) : []
        committedCount = i
        previous = current
        return newly
    }

    /// Commit every sentence not yet committed. Called at finish, once
    /// recording has stopped and the transcript will not grow further.
    /// Return the remaining (volatile tail) sentences.
    public mutating func commitRemaining(_ transcript: String) -> [String] {
        let current = Self.splitIntoSentences(transcript)
        guard committedCount < current.count else {
            committedCount = current.count
            previous = current
            return []
        }
        let remaining = Array(current[committedCount...])
        committedCount = current.count
        previous = current
        return remaining
    }

    // MARK: - Helpers

    /// Words that end with a period without ending a sentence.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
        "eg", "ie", "no", "vol", "fig", "al", "inc", "ltd", "co", "corp",
        "dept", "approx", "apt", "gov", "sen", "rep", "gen", "capt",
    ]

    /// Split text into sentences. `!` and `?` always end a sentence. A
    /// `.` ends one only when it is followed by end-of-text or by
    /// whitespace and an uppercase letter, and is not part of an
    /// abbreviation ("p.m.", "e.g."), an initial ("U.S."), or a decimal
    /// ("3.5"). This keeps such tokens intact so a committed or tail
    /// chunk is never cut mid-abbreviation.
    static func splitIntoSentences(_ text: String) -> [String] {
        let chars = Array(text)
        var sentences: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if (c == "." || c == "!" || c == "?")
                && isBoundary(chars, at: i)
            {
                let piece = String(chars[start...i])
                    .trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { sentences.append(piece) }
                start = i + 1
            }
            i += 1
        }
        if start < chars.count {
            let tail = String(chars[start...])
                .trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { sentences.append(tail) }
        }
        return sentences
    }

    /// Decide whether the terminator at `i` ends a sentence.
    private static func isBoundary(_ chars: [Character], at i: Int) -> Bool {
        if chars[i] == "!" || chars[i] == "?" { return true }

        // Find the next non-whitespace character after the period.
        var j = i + 1
        var sawSpace = false
        while j < chars.count, chars[j].isWhitespace {
            sawSpace = true
            j += 1
        }
        if j >= chars.count { return true }  // end of text

        // A period glued to the next token (no space) is a decimal,
        // URL, or abbreviation continuing — not a boundary.
        if !sawSpace { return false }
        if !chars[j].isUppercase { return false }

        // Preceding token: letters/digits immediately before the period.
        var k = i - 1
        while k >= 0, chars[k].isLetter || chars[k].isNumber {
            k -= 1
        }
        let word = String(chars[(k + 1)..<i])
        if word.count == 1 { return false }  // initial, e.g. "U."
        if abbreviations.contains(word.lowercased()) { return false }
        return true
    }

    /// Lowercase, strip punctuation, and collapse whitespace so a
    /// sentence compares equal across cycles despite minor recognizer
    /// revisions to casing or punctuation.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .filter {
                CharacterSet.alphanumerics.contains($0)
                    || CharacterSet.whitespaces.contains($0)
            }
            .map(String.init)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
