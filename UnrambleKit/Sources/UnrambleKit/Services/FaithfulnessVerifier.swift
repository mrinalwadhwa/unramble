import Foundation

/// Detect faithfulness candidates that the deterministic content guards cannot
/// resolve: small meaningful drops and meaning-changing substitutions.
///
/// The content guards in `PolishPipeline` reject large or structural breaks
/// (runs of more than three dropped words, fabrication, duplication), but the
/// surface signal for a *small* change is identical whether the polish dropped
/// meaningful content or made a legitimate cleanup — removing a filler, fixing a
/// tense, or rendering a spoken number as digits. Separating the two is a
/// semantic judgment, so this type does only the cheap, deterministic half:
///
/// 1. Diff the raw transcript against the polished output to find deleted and
///    replaced spans.
/// 2. Pre-filter the spans that are decidably safe — commands, fillers,
///    stutters, offered alternatives, and number/tense/plural/compound forms.
///
/// Every span that survives is a narrow, well-posed question for a downstream
/// semantic adjudicator. Most outputs produce zero candidates.
///
/// The diff reproduces the matching-block algorithm of Python's
/// `difflib.SequenceMatcher` (autojunk disabled, no junk predicate) so the
/// candidate set matches the reference implementation the pre-filters were
/// tuned against.
enum FaithfulnessVerifier {

    /// A changed span the pre-filters could not resolve as a legitimate cleanup.
    struct Candidate: Equatable {
        enum Kind: String, Equatable {
            /// Transcript words that are absent from the output.
            case omission
            /// Transcript words the output replaced with different words.
            case substitution
        }

        let kind: Kind
        /// The affected transcript words.
        let span: String
        /// The substituting words; empty for an omission.
        let replacement: String
        /// A window of surrounding transcript words for the adjudicator.
        let context: String
        /// The spoken text to restore on repair (real casing from the transcript).
        let restoration: String
        /// Character offset in the output where the change starts.
        let outputStart: Int
        /// Character offset in the output where the change ends; equal to
        /// `outputStart` for an omission (a zero-width insertion point).
        let outputEnd: Int
    }

    /// Diff `transcript` against `output` and return the unresolved candidates.
    static func candidates(transcript: String, output: String) -> [Candidate] {
        let aChars = Array(transcript)
        let bChars = Array(output)
        let aSpans = tokenSpans(aChars)
        let bSpans = tokenSpans(bChars)
        let a = aSpans.map(\.token)
        let b = bSpans.map(\.token)
        guard !a.isEmpty else { return [] }

        // The transcript text of tokens [i1, i2) with its real casing.
        func spoken(_ i1: Int, _ i2: Int) -> String {
            String(aChars[aSpans[i1].start..<aSpans[i2 - 1].end])
        }

        var result: [Candidate] = []
        for op in SequenceMatcher(a: a, b: b).opcodes() {
            switch op.tag {
            case .delete:
                let span = Array(a[op.i1..<op.i2])
                if isCommandSpan(span) || isNoiseSpan(span, transcript: a, end: op.i2) {
                    continue
                }
                // Re-attach a dropped phrase to the end of the preceding output
                // token, before whatever boundary the polish inserted.
                let insertAt = op.j1 > 0 ? bSpans[op.j1 - 1].end
                    : (bSpans.isEmpty ? 0 : bSpans[0].start)
                result.append(Candidate(
                    kind: .omission,
                    span: span.joined(separator: " "),
                    replacement: "",
                    context: contextWindow(a, op.i1, op.i2),
                    restoration: spoken(op.i1, op.i2),
                    outputStart: insertAt,
                    outputEnd: insertAt))
            case .replace:
                let src = Array(a[op.i1..<op.i2])
                let dst = Array(b[op.j1..<op.j2])
                if isCommandSpan(src)
                    || isFormChange(src: src, dst: dst)
                    || isDisfluencySubstitution(
                        src: src, dst: dst, transcript: a, start: op.i1, end: op.i2) {
                    continue
                }
                result.append(Candidate(
                    kind: .substitution,
                    span: src.joined(separator: " "),
                    replacement: dst.joined(separator: " "),
                    context: contextWindow(a, op.i1, op.i2),
                    restoration: spoken(op.i1, op.i2),
                    outputStart: bSpans[op.j1].start,
                    outputEnd: bSpans[op.j2 - 1].end))
            case .insert, .equal:
                continue
            }
        }
        return result
    }

    /// Revert each flagged span in `output` to what was spoken, keeping the rest
    /// of the polish. Applied right-to-left so earlier offsets stay valid. A
    /// substitution overwrites its output span; an omission re-inserts the
    /// dropped phrase — unless its content already appears elsewhere (the polish
    /// reordered rather than dropped it).
    static func repair(output: String, flagged: [Candidate]) -> String {
        guard !flagged.isEmpty else { return output }
        var chars = Array(output)
        let present = Set(normalizeTokens(output))
        for candidate in flagged.sorted(by: { $0.outputStart > $1.outputStart }) {
            switch candidate.kind {
            case .substitution:
                guard candidate.outputStart <= candidate.outputEnd,
                    candidate.outputEnd <= chars.count else { continue }
                var text = candidate.restoration
                if let first = chars[safe: candidate.outputStart], first.isUppercase {
                    text = text.capitalizedFirstLetter
                }
                chars.replaceSubrange(candidate.outputStart..<candidate.outputEnd, with: Array(text))
            case .omission:
                let content = normalizeTokens(candidate.restoration).filter {
                    !filler.contains($0) && !stop.contains($0) && $0.count >= 2
                }
                if !content.isEmpty && content.allSatisfy(present.contains) { continue }
                guard candidate.outputStart <= chars.count else { continue }
                let text = candidate.outputStart > 0
                    ? " " + candidate.restoration
                    : candidate.restoration + " "
                chars.insert(contentsOf: Array(text), at: candidate.outputStart)
            }
        }
        return String(chars)
    }

    // MARK: - Vocabulary

    /// Spoken break and punctuation commands the pipeline consumes — never
    /// dropped content ("new paragraph", "exclamation point", "question mark").
    static let command: Set<String> = [
        "paragraph", "line", "colon", "period", "comma", "semicolon",
        "exclamation", "question", "mark", "point",
    ]

    /// Fillers and discourse markers that are always safe to remove.
    static let filler: Set<String> = [
        "um", "uh", "erm", "ah", "okay", "ok", "like", "basically", "literally",
        "actually", "really", "just", "yeah", "yep", "hmm", "mean", "know",
        "kinda", "sorta", "well", "so", "right", "anyway", "anyways", "guess",
    ]

    /// Function words that carry no content on their own.
    static let stop: Set<String> = [
        "the", "a", "an", "i", "you", "we", "it", "of", "to", "and", "or",
        "on", "in", "at", "is", "was", "that", "this", "my", "our", "your",
    ]

    /// Auxiliary/helper verbs that carry little content on their own (the ones
    /// not already in `stop`); a lead-in of these before an inflected word is a
    /// disfluency, not content.
    static let auxiliary: Set<String> = [
        "am", "are", "were", "be", "been", "being", "do", "does", "did",
        "have", "has", "had", "will", "would", "could", "should",
    ]

    /// Spoken-number words whose digit rendering is the same meaning.
    static let numberWord: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
        "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "point", "percent",
    ]

    // MARK: - Tokenization

    /// Lowercase and split on any character that is not a letter, digit, or
    /// apostrophe, dropping empty tokens.
    static func normalizeTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if isTokenChar(ch) {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func isTokenChar(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "'"
    }

    /// A normalized token with its character offsets in the source text.
    struct TokenSpan { let token: String; let start: Int; let end: Int }

    /// Tokenize like `normalizeTokens`, but keep each token's character range so
    /// a change can be located back in the original text for repair.
    static func tokenSpans(_ chars: [Character]) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var buffer: [Character] = []
        var start = 0
        for (index, ch) in chars.enumerated() {
            if isTokenCharRaw(ch) {
                if buffer.isEmpty { start = index }
                buffer.append(ch)
            } else if !buffer.isEmpty {
                spans.append(TokenSpan(token: String(buffer).lowercased(), start: start, end: index))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            spans.append(TokenSpan(token: String(buffer).lowercased(), start: start, end: chars.count))
        }
        return spans
    }

    private static func isTokenCharRaw(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
            || (c >= "0" && c <= "9") || c == "'"
    }

    // MARK: - Pre-filters

    /// A span whose content words are all break/punctuation commands (fillers
    /// aside) is a consumed command, not a drop.
    static func isCommandSpan(_ words: [String]) -> Bool {
        let significant = words.filter { !filler.contains($0) }
        return !significant.isEmpty
            && significant.allSatisfy { command.contains($0) || $0 == "new" }
    }

    /// A deleted span is safe-to-remove noise — fillers/stopwords only, an
    /// offered alternative ("heat lamps or …"), or a stutter/self-correction
    /// whose word reappears just before or after the span ("short on short",
    /// "drop by about by").
    static func isNoiseSpan(_ span: [String], transcript a: [String], end i2: Int) -> Bool {
        let content = span.filter { !filler.contains($0) && !stop.contains($0) && $0.count >= 2 }
        if content.isEmpty { return true }
        if span.last == "or" { return true }
        let start = i2 - span.count
        let neighbors = Array(a[max(0, start - 3)..<start]) + Array(a[i2..<min(a.count, i2 + 3)])
        for w in content {
            for f in neighbors where w == f || (w.count >= 3 && editDistanceWithin(w, f, 1)) {
                return true
            }
        }
        return false
    }

    /// A substitution that is deterministically the same meaning: a spoken
    /// number rendered as digits, or a tense/plural/compound-merge of one stem.
    static func isFormChange(src: [String], dst: [String]) -> Bool {
        let joinedDst = dst.joined(separator: " ")
        let dstHasDigit = joinedDst.contains(where: \.isNumber)
        let srcAllNumbers = !src.isEmpty && src.allSatisfy { numberWord.contains($0) }
        if srcAllNumbers && dstHasDigit { return true }
        if dstHasDigit && src.contains(where: { numberWord.contains($0) }) { return true }

        let srcKey = src.joined()
        let dstKey = dst.joined()
        if srcKey.count >= 3 && dstKey.count >= 3 {
            if srcKey.hasPrefix(dstKey) || dstKey.hasPrefix(srcKey) { return true }
            if editDistanceWithin(srcKey, dstKey, 2) { return true }
        }
        return false
    }

    /// A substitution the polish made only to clean a disfluency, not to change
    /// meaning. Two shapes:
    /// 1. a source content word repeats just before or after the span, so the
    ///    polish collapsed a stutter or self-correction ("everyone el
    ///    everyone's" -> "everyone else's");
    /// 2. the source is a run of low-content lead-in words ending in a word the
    ///    target simply inflects ("are we finish" -> "finished").
    static func isDisfluencySubstitution(
        src: [String], dst: [String], transcript a: [String], start i1: Int, end i2: Int
    ) -> Bool {
        let content = src.filter { !filler.contains($0) && !stop.contains($0) && $0.count >= 2 }

        // 1. stutter / self-correction: a content word repeats a neighbor.
        let neighbors = Array(a[max(0, i1 - 3)..<i1]) + Array(a[i2..<min(a.count, i2 + 3)])
        for w in content {
            let ws = stemmed(w)
            for f in neighbors where ws == stemmed(f)
                || (ws.count >= 3 && editDistanceWithin(ws, stemmed(f), 1)) {
                return true
            }
        }

        // 2. low-content lead-in dropped, last word inflected into the target.
        if dst.count == 1, let last = content.last, last.count >= 3,
            let lastIndex = src.lastIndex(of: last) {
            let lead = src[src.startIndex..<lastIndex]
            let leadLowContent = lead.allSatisfy {
                filler.contains($0) || stop.contains($0) || auxiliary.contains($0)
            }
            let target = dst[0]
            if leadLowContent && (target.hasPrefix(last) || last.hasPrefix(target)) {
                return true
            }
        }
        return false
    }

    /// Strip a trailing possessive so "everyone's" and "everyone" compare equal.
    static func stemmed(_ word: String) -> String {
        word.hasSuffix("'s") ? String(word.dropLast(2)) : word
    }

    private static func contextWindow(_ a: [String], _ i1: Int, _ i2: Int) -> String {
        let lo = max(0, i1 - 4)
        let hi = min(a.count, i2 + 4)
        return a[lo..<hi].joined(separator: " ")
    }

    /// True when the Levenshtein distance between `a` and `b` is at most `k`.
    static func editDistanceWithin(_ a: String, _ b: String, _ k: Int) -> Bool {
        let ca = Array(a)
        let cb = Array(b)
        if abs(ca.count - cb.count) > k { return false }
        if ca.isEmpty { return cb.count <= k }
        if cb.isEmpty { return ca.count <= k }
        var prev = Array(0...cb.count)
        for i in 1...ca.count {
            var cur = [i]
            for j in 1...cb.count {
                let cost = ca[i - 1] == cb[j - 1] ? 0 : 1
                cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost))
            }
            if (cur.min() ?? 0) > k { return false }
            prev = cur
        }
        return prev[cb.count] <= k
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    /// Uppercase the first letter, leaving the rest unchanged.
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// The matching-block and opcode computation from Python's
/// `difflib.SequenceMatcher`, restricted to what the detector needs (autojunk
/// disabled, no junk predicate). Kept faithful so the diff matches the
/// reference implementation exactly.
private struct SequenceMatcher {
    let a: [String]
    let b: [String]
    private let b2j: [String: [Int]]

    init(a: [String], b: [String]) {
        self.a = a
        self.b = b
        var map: [String: [Int]] = [:]
        for (j, w) in b.enumerated() { map[w, default: []].append(j) }
        b2j = map
    }

    struct Match { let i: Int; let j: Int; let size: Int }

    func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> Match {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i], default: []] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize {
                    besti = i - k + 1
                    bestj = j - k + 1
                    bestsize = k
                }
            }
            j2len = newj2len
        }
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
            besti -= 1
            bestj -= 1
            bestsize += 1
        }
        while besti + bestsize < ahi && bestj + bestsize < bhi
            && a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return Match(i: besti, j: bestj, size: bestsize)
    }

    func matchingBlocks() -> [Match] {
        let la = a.count
        let lb = b.count
        var queue = [(0, la, 0, lb)]
        var blocks: [Match] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let m = findLongestMatch(alo, ahi, blo, bhi)
            if m.size > 0 {
                blocks.append(m)
                if alo < m.i && blo < m.j { queue.append((alo, m.i, blo, m.j)) }
                if m.i + m.size < ahi && m.j + m.size < bhi {
                    queue.append((m.i + m.size, ahi, m.j + m.size, bhi))
                }
            }
        }
        blocks.sort { ($0.i, $0.j) < ($1.i, $1.j) }

        var merged: [Match] = []
        var i1 = 0, j1 = 0, k1 = 0
        for m in blocks {
            if i1 + k1 == m.i && j1 + k1 == m.j {
                k1 += m.size
            } else {
                if k1 > 0 { merged.append(Match(i: i1, j: j1, size: k1)) }
                i1 = m.i
                j1 = m.j
                k1 = m.size
            }
        }
        if k1 > 0 { merged.append(Match(i: i1, j: j1, size: k1)) }
        merged.append(Match(i: la, j: lb, size: 0))
        return merged
    }

    enum Tag { case replace, delete, insert, equal }
    struct Opcode { let tag: Tag; let i1: Int; let i2: Int; let j1: Int; let j2: Int }

    func opcodes() -> [Opcode] {
        var i = 0, j = 0
        var answer: [Opcode] = []
        for m in matchingBlocks() {
            var tag: Tag?
            if i < m.i && j < m.j {
                tag = .replace
            } else if i < m.i {
                tag = .delete
            } else if j < m.j {
                tag = .insert
            }
            if let tag {
                answer.append(Opcode(tag: tag, i1: i, i2: m.i, j1: j, j2: m.j))
            }
            i = m.i + m.size
            j = m.j + m.size
            if m.size > 0 {
                answer.append(Opcode(tag: .equal, i1: m.i, i2: i, j1: m.j, j2: j))
            }
        }
        return answer
    }
}
