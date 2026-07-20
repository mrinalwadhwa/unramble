import Foundation

/// Three-stage text polishing pipeline for dictation transcripts.
///
/// Refine raw speech-to-text output into polished written text:
///
/// 1. **Dictated punctuation substitution** — deterministic regex
///    replacements for spoken formatting commands ("period", "comma",
///    "new paragraph"). Protected symbols wrapped in `<keep>` tags.
///
/// 2. **Clean transcript skip** — heuristic that bypasses the LLM
///    when the transcript is already well-formed.
///
/// 3. **LLM refinement** — send to a small model that removes fillers,
///    fixes repetitions, formats lists/numbers, and adjusts tone.
public enum PolishPipeline {

    // MARK: - Configuration

    public static let polishModel = "gpt-5.4-nano"

    // MARK: - Stage 1: Dictated Punctuation Substitution

    /// A substitution rule: regex pattern, replacement string, and
    /// whether to wrap the replacement in `<keep>` tags.
    private struct PunctuationRule {
        let pattern: NSRegularExpression
        let replacement: String
        let protect: Bool
        /// Skip the replacement when the command word is preceded by an article
        /// or determiner ("a new paragraph", "the comma") — it is being talked
        /// about, not commanded. Set for command words that are also ordinary
        /// English words; real commands are never article-preceded.
        let guarded: Bool

        init(
            _ pattern: String, _ replacement: String,
            protect: Bool = false, guarded: Bool = false
        ) {
            // swiftlint:disable:next force_try
            self.pattern = try! NSRegularExpression(
                pattern: pattern, options: .caseInsensitive)
            self.replacement = replacement
            self.protect = protect
            self.guarded = guarded
        }
    }

    // Order matters: "new paragraph" must come before "period" to avoid
    // partial matches.
    private static let punctuationRules: [PunctuationRule] = [
        // Paragraph and line breaks.
        PunctuationRule(#"\bnew paragraph\b"#, "[PAR]", protect: true, guarded: true),
        PunctuationRule(#"\bnew line\b"#, "[NL]", protect: true, guarded: true),
        PunctuationRule(#"\bnewline\b"#, "[NL]", protect: true, guarded: true),
        // "period" and "full stop" are handled by the model, not
        // deterministically — they collide with nouns ("billing period",
        // "came to a full stop").
        PunctuationRule(#"\bquestion mark\b"#, "?", guarded: true),
        PunctuationRule(#"\bexclamation point\b"#, "!", guarded: true),
        PunctuationRule(#"\bexclamation mark\b"#, "!", guarded: true),
        // Inline punctuation.
        PunctuationRule(#"\bcomma\b"#, ",", guarded: true),
        PunctuationRule(#"\bcolon\b"#, ":", guarded: true),
        PunctuationRule(#"\bsemicolon\b"#, ";", guarded: true),
        // Dashes.
        PunctuationRule(#"\bem dash\b"#, "\u{2014}", protect: true),
        PunctuationRule(#"\ben dash\b"#, "\u{2013}", protect: true),
        PunctuationRule(#"\bhyphen\b"#, "-", protect: true),
        PunctuationRule(#"\bminus\s+(?:sign|symbol)\b"#, "-", protect: true),
        // Brackets, quotes, and parens. "parent" is a common STT
        // misrecognition for "paren" because "paren" isn't a standalone
        // English word, so we accept it as an alias.
        PunctuationRule(#"\bopen paren(?:t|thesis)?\b"#, "("),
        PunctuationRule(#"\bclose paren(?:t|thesis)?\b"#, ")"),
        PunctuationRule(#"\bopen quote\b"#, "\u{201c}"),
        PunctuationRule(#"\b(?:close|end) quote\b"#, "\u{201d}"),
        PunctuationRule(#"\bunquote\b"#, "\u{201d}"),
        PunctuationRule(#"\b(?:apostrophe|single quote)\b"#, "'"),
        PunctuationRule(#"\bopen bracket\b"#, "["),
        PunctuationRule(#"\bclose bracket\b"#, "]"),
        PunctuationRule(#"\b(?:open )?angle bracket\b"#, "<", protect: true),
        PunctuationRule(#"\bless[- ]than sign\b"#, "<", protect: true),
        PunctuationRule(#"\bclose angle bracket\b"#, ">", protect: true),
        PunctuationRule(#"\bgreater[- ]than sign\b"#, ">", protect: true),
        // Symbols (protected — the LLM might reinterpret these).
        PunctuationRule(#"\bdot dot dot\b"#, "\u{2026}", protect: true),
        PunctuationRule(#"\bellipsis\b"#, "\u{2026}", protect: true),
        PunctuationRule(#"\b(?:ampersand|and sign|and symbol)\b"#, "&", protect: true),
        PunctuationRule(#"\b(?:at sign|at symbol)\b"#, "@", protect: true),
        PunctuationRule(#"\bhashtag\b"#, "#", protect: true),
        PunctuationRule(#"\b(?:back ?slash|slash en)\b"#, "\\", protect: true),
        PunctuationRule(#"\bforward slash\b"#, "/", protect: true),
        PunctuationRule(#"\b(?:asterisk|asterisk sign)\b"#, "*", protect: true),
        PunctuationRule(#"\bunderscore\b"#, "_", protect: true),
        PunctuationRule(#"\b(?:percent sign|per cent|percentage symbol)\b"#, "%", protect: true),
        PunctuationRule(#"\bdollar sign\b"#, "$", protect: true),
        PunctuationRule(#"\b(?:equals sign|equals symbol)\b"#, "=", protect: true),
        PunctuationRule(#"\b(?:plus sign|plus symbol)\b"#, "+", protect: true),
        // Special symbols.
        PunctuationRule(#"\btrademark sign\b"#, "\u{2122}", protect: true),
        PunctuationRule(#"\btm\b"#, "\u{2122}", protect: true),
        PunctuationRule(#"\bcopyright sign\b"#, "\u{00a9}", protect: true),
        PunctuationRule(#"\bcopyright symbol\b"#, "\u{00a9}", protect: true),
        PunctuationRule(#"\bdegrees?\s+fahrenheit\b"#, "\u{00b0}F", protect: true),
        PunctuationRule(#"\bdegrees?\s+f\b"#, "\u{00b0}F", protect: true),
        PunctuationRule(#"\bdegrees?\s+celsius\b"#, "\u{00b0}C", protect: true),
        PunctuationRule(#"\bdegrees?\s+centigrade\b"#, "\u{00b0}C", protect: true),
        PunctuationRule(#"\b(?:degree sign|degree symbol)\b"#, "\u{00b0}", protect: true),
    ]

    /// Articles and determiners that mark a following guarded command word as
    /// content ("a new paragraph", "the comma") rather than a command.
    private static let articleDeterminers: Set<String> = [
        "a", "an", "the", "another", "any", "this", "that",
    ]

    /// True when `text` ends with an article or determiner, ignoring trailing
    /// whitespace, so a command word immediately after it is being talked about.
    private static func endsWithArticle(_ text: Substring) -> Bool {
        var word = ""
        var seenLetter = false
        for character in text.reversed() {
            if character.isLetter {
                word.append(character)
                seenLetter = true
            } else if !seenLetter, character == " " || character == "\t" {
                continue
            } else {
                break
            }
        }
        return articleDeterminers.contains(
            String(word.reversed()).lowercased())
    }

    /// Replace spoken punctuation commands with actual symbols.
    ///
    /// Protected symbols are wrapped in `<keep>` tags so the LLM
    /// preserves them verbatim.
    public static func substituteDictatedPunctuation(
        _ text: String, casual: Bool = false, precedingText: String? = nil
    ) -> String {
        var result = text

        for rule in punctuationRules {
            let replacement: String
            if rule.protect {
                replacement = "<keep>\(rule.replacement)</keep>"
            } else {
                replacement = rule.replacement
            }

            // Use a block-based replacement to avoid NSRegularExpression
            // interpreting backslashes in the replacement string.
            var output = ""
            var lastEnd = result.startIndex
            let matches = rule.pattern.matches(
                in: result,
                range: NSRange(result.startIndex..., in: result))

            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                output += result[lastEnd..<range.lowerBound]
                // A guarded command word preceded by an article/determiner is
                // being talked about, not commanded — keep it verbatim.
                if rule.guarded,
                    endsWithArticle(result[..<range.lowerBound])
                {
                    output += result[range]
                } else {
                    output += replacement
                }
                lastEnd = range.upperBound
            }
            output += result[lastEnd...]
            result = output
        }

        // Convert literal "..." to Unicode ellipsis.
        result = result.replacingOccurrences(
            of: "...", with: "<keep>\u{2026}</keep>")

        // Clean up whitespace around punctuation introduced by substitution.
        // Remove spaces before punctuation that attaches to preceding word.
        // Non-raw strings so \u{...} is interpreted as Unicode.
        result = result.replacingOccurrences(
            of: " +([.,;:?!)\\]\u{201d}])",
            with: "$1",
            options: .regularExpression)

        // Remove spaces after opening brackets/quotes.
        result = result.replacingOccurrences(
            of: "([(\\[\u{201c}]) +",
            with: "$1",
            options: .regularExpression)

        // Collapse multiple spaces.
        result = result.replacingOccurrences(
            of: " {2,}",
            with: " ",
            options: .regularExpression)

        // Collapse runs of adjacent punctuation down to the strongest
        // single mark. The Realtime STT already inserts commas and
        // periods from pauses and prosody, so when the user also
        // dictates "comma" or "period" the substitution above emits
        // duplicates. "Hey team,,," becomes "Hey team,". "breaks,."
        // becomes "breaks.".
        result = collapseAdjacentPunctuation(result)

        // Ensure sentence-ending punctuation before paragraph/line
        // break tags. Replace weak punctuation (comma, semicolon)
        // with a period; insert a period if none present.
        result = result.replacingOccurrences(
            of: #"[,;]\s*(<keep>\[(?:PAR|NL)\]</keep>)"#,
            with: ".$1",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"([^.!?\s])\s*(<keep>\[(?:PAR|NL)\]</keep>)"#,
            with: "$1.$2",
            options: .regularExpression)

        // Trim whitespace around line breaks.
        result = result.replacingOccurrences(
            of: " *\n *",
            with: "\n",
            options: .regularExpression)

        if casual {
            // Casual: lowercase the first character unless the first
            // word is an abbreviation (all-uppercase like "API", "AWS")
            // or the pronoun "I".
            if let first = result.first, first.isLetter, first.isUppercase {
                let firstWord = result.prefix(while: { $0.isLetter })
                let isAbbreviation = firstWord.count > 1
                    && firstWord.allSatisfy({ $0.isUppercase })
                let isPronounI = firstWord == "I"
                if !isAbbreviation && !isPronounI {
                    result = first.lowercased() + result.dropFirst()
                }
            }
        } else {
            // Normalize a.m./p.m. to AM/PM before split-word rejoin,
            // so the trailing period in "p.m." isn't eaten by the
            // split-word regex matching "\.\s+([a-z])".
            // Day/month names first — no sentence boundary period.
            result = result.replacingOccurrences(
                of: #"\ba\.m\.(?= (?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day)"#,
                with: "AM", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\bp\.m\.(?= (?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day)"#,
                with: "PM", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\ba\.m\.(?= (?:January|February|March|April|May|June|July|August|September|October|November|December))"#,
                with: "AM", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\bp\.m\.(?= (?:January|February|March|April|May|June|July|August|September|October|November|December))"#,
                with: "PM", options: .regularExpression)
            // General uppercase — sentence boundary, preserve period.
            result = result.replacingOccurrences(
                of: #"\ba\.m\.(?= [A-Z])"#, with: "AM.", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\bp\.m\.(?= [A-Z])"#, with: "PM.", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\ba\.m\.(?= )"#, with: "AM", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\bp\.m\.(?= )"#, with: "PM", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\ba\.m\.(?=[,;])"#, with: "AM", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\bp\.m\.(?=[,;])"#, with: "PM", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\ba\.m\.(?=$|\n)"#, with: "AM.", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"\bp\.m\.(?=$|\n)"#, with: "PM.", options: .regularExpression)

            // Capitalize first letter after sentence-ending punctuation + space.
            result = capitalizeAfterPattern(result, pattern: "([.!?]\\s+)(\\w)")

            // Capitalize very first character — unless we're continuing
            // mid-sentence from preceding text.
            let midSentence = precedingText.map {
                !$0.isEmpty && !endsAtSentenceBoundary($0)
            } ?? false
            if midSentence, let first = result.first, first.isUppercase {
                result = first.lowercased() + result.dropFirst()
            } else if !midSentence, let first = result.first, first.isLetter {
                result = first.uppercased() + result.dropFirst()
            }
        }

        // Strip multi-word noise phrases (uh huh, mm hmm) as units
        // before single filler sounds, so they aren't split by L1.
        result = stripNoisePhrases(result)

        // Strip pure filler sounds (um, uh, ah, hmm, etc.).
        result = stripFillerSounds(result)

        // Convert spoken clock times ("at three thirty" → "at 3:30") before the
        // model, which otherwise misconverts them (e.g. to "3:00"). Runs before
        // number-word conversion so the minute words are still spelled.
        result = convertSpokenTime(result)

        // Convert "X point Y million/billion/thousand" to decimal form
        // before the model sees it. Prevents hallucinated conversions
        // like "one point two million" → "200,000".
        result = convertDecimalScale(result)

        // Convert unambiguous number words to digits.
        result = convertNumberWords(result)

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Strength ordering used by `collapseAdjacentPunctuation`: stronger
    /// punctuation wins when multiple marks sit adjacent to each other.
    /// Values are arbitrary but ordered `, < : < ; < . < ? < !`.
    private static let punctuationStrength: [Character: Int] = [
        ",": 1,
        ":": 2,
        ";": 3,
        ".": 4,
        "?": 5,
        "!": 6,
    ]

    private static let adjacentPunctuationPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"([.,;:?!])(?:\s*[.,;:?!])+"#,
            options: [])
    }()

    /// Collapse runs of adjacent punctuation marks (possibly separated by
    /// whitespace) down to the single strongest one in the run. Used to
    /// clean up duplicates produced when the STT auto-inserts punctuation
    /// from pauses *and* the user dictates a punctuation command in the
    /// same spot.
    static func collapseAdjacentPunctuation(_ text: String) -> String {
        let matches = adjacentPunctuationPattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[lastEnd..<range.lowerBound]
            let run = text[range]
            let strongest = run.compactMap { punctuationStrength[$0] != nil ? $0 : nil }
                .max(by: { punctuationStrength[$0]! < punctuationStrength[$1]! })
            if let strongest {
                result.append(strongest)
            }
            lastEnd = range.upperBound
        }
        result += text[lastEnd...]
        return result
    }

    // MARK: - Filler Phrase Stripping

    /// Multi-word noise sounds — acknowledgment noises that are never
    /// content. Matched as units before single filler sounds run.
    private static let noisePhrasesPattern: NSRegularExpression = {
        let phrases = ["uh huh", "uh-huh", "mm hmm", "mm-hmm"]
        let joined = phrases.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: "(?i)\\b(\(joined))\\b[,.]?\\s*",
            options: [])
    }()

    /// Strip multi-word noise phrases ("uh huh", "mm hmm") that are
    /// never content words. Run before single filler sound stripping
    /// so multi-word noise sounds are removed as units.
    public static func stripNoisePhrases(_ text: String) -> String {
        var result = noisePhrasesPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "")

        // Collapse multiple spaces and trim.
        result = result.replacingOccurrences(
            of: " {2,}", with: " ", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Filler Sound Stripping

    private static let fillerSoundPattern: NSRegularExpression = {
        // Pure vocalized pauses — never content words in English.
        // Shuffled to avoid order-dependent prompt overfitting.
        let fillers = [
            "um", "eh", "mmm", "uhh", "hm", "umm", "mm",
            "uh", "uhhh", "uhm", "ah", "hmm", "mh", "ehh",
        ]
        let joined = fillers.joined(separator: "|")
        // Word boundary + optional trailing comma/period + whitespace.
        // "uhm, I was thinking" → "I was thinking"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: "(?i)\\b(\(joined))\\b[,.]?\\s*",
            options: [])
    }()

    /// Strip pure filler sounds (um, uh, ah, hmm, etc.).
    ///
    /// These are vocalized pauses that the speaker did not intend as
    /// words. Trailing punctuation attached to the filler is removed
    /// with it. Applied pre-LLM so models receive cleaner input.
    public static func stripFillerSounds(_ text: String) -> String {
        var result = fillerSoundPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "")

        // Collapse multiple spaces left behind.
        result = result.replacingOccurrences(
            of: " {2,}", with: " ", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Decimal Scale Number Conversion

    /// Map single-digit number words to their digit form.
    private static let digitWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    /// Convert spoken decimal scale numbers to numeric form.
    ///
    /// "one point two million" → "1.2 million"
    /// "3 point 5 billion" → "3.5 billion"
    ///
    /// Handles both word and digit forms. Only matches single-digit
    /// values on each side of "point" to avoid false positives.
    static func convertDecimalScale(_ text: String) -> String {
        var result = text

        // Word form: "one point two million"
        let wordPattern = #"(?i)\b(zero|one|two|three|four|five|six|seven|eight|nine)\s+point\s+(zero|one|two|three|four|five|six|seven|eight|nine)\s+(million|billion|thousand|trillion)\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            let matches = regex.matches(
                in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let r1 = Range(match.range(at: 1), in: result),
                      let r2 = Range(match.range(at: 2), in: result),
                      let r3 = Range(match.range(at: 3), in: result),
                      let d1 = digitWords[result[r1].lowercased()],
                      let d2 = digitWords[result[r2].lowercased()]
                else { continue }
                let scale = result[r3].lowercased()
                result.replaceSubrange(fullRange, with: "\(d1).\(d2) \(scale)")
            }
        }

        // Digit form: "3 point 5 million"
        let digitPattern = #"\b(\d+)\s+point\s+(\d+)\s+(million|billion|thousand|trillion)\b"#
        if let regex = try? NSRegularExpression(
            pattern: digitPattern, options: .caseInsensitive) {
            let matches = regex.matches(
                in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let r1 = Range(match.range(at: 1), in: result),
                      let r2 = Range(match.range(at: 2), in: result),
                      let r3 = Range(match.range(at: 3), in: result)
                else { continue }
                let replacement = "\(result[r1]).\(result[r2]) \(result[r3].lowercased())"
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        // Bare word form without a scale word: "version two point one" -> "2.1",
        // "three point zero" -> "3.0". Requiring a number word on BOTH sides of
        // "point" keeps the noun sense out ("make one point clear", "a three
        // point turn"), and the negative lookahead leaves the scaled cases above
        // untouched.
        let bareWordPattern = #"(?i)\b(zero|one|two|three|four|five|six|seven|eight|nine)\s+point\s+(zero|one|two|three|four|five|six|seven|eight|nine)\b(?!\s+(?:million|billion|thousand|trillion))"#
        if let regex = try? NSRegularExpression(pattern: bareWordPattern) {
            let matches = regex.matches(
                in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let r1 = Range(match.range(at: 1), in: result),
                      let r2 = Range(match.range(at: 2), in: result),
                      let d1 = digitWords[result[r1].lowercased()],
                      let d2 = digitWords[result[r2].lowercased()]
                else { continue }
                result.replaceSubrange(fullRange, with: "\(d1).\(d2)")
            }
        }

        // Bare digit form without a scale word: "3 point 5" -> "3.5".
        let bareDigitPattern = #"\b(\d+)\s+point\s+(\d+)\b(?!\s+(?:million|billion|thousand|trillion))"#
        if let regex = try? NSRegularExpression(
            pattern: bareDigitPattern, options: .caseInsensitive) {
            let matches = regex.matches(
                in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let r1 = Range(match.range(at: 1), in: result),
                      let r2 = Range(match.range(at: 2), in: result)
                else { continue }
                result.replaceSubrange(
                    fullRange, with: "\(result[r1]).\(result[r2])")
            }
        }

        return result
    }

    // MARK: - Number Word Conversion

    private static let tens: [(String, Int)] = [
        ("twenty", 20), ("thirty", 30), ("forty", 40),
        ("fifty", 50), ("sixty", 60), ("seventy", 70),
        ("eighty", 80), ("ninety", 90),
    ]

    /// Spelled hours ("one".."twelve") for spoken-time conversion.
    private static let hourWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    /// Minute words 10-19 (plus ten/eleven/twelve).
    private static let minuteTeens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]

    /// Minute tens words (20-50); 60+ is not a valid minute.
    private static let minuteTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    ]

    private static func parseHour(_ token: String) -> Int? {
        let t = token.lowercased()
        if let v = hourWords[t] { return v }
        if let v = Int(t), (0...23).contains(v) { return v }
        return nil
    }

    /// Parse a spoken minute phrase (lowercased words) to 0-59, or nil.
    private static func parseMinute(_ words: [String]) -> Int? {
        guard let first = words.first else { return nil }
        if first == "o'clock" || first == "oclock" {
            return words.count == 1 ? 0 : nil
        }
        if first == "oh", words.count == 2, let v = onesValues[words[1]] {
            return v
        }
        if words.count == 1, let v = minuteTeens[first] { return v }
        if let t = minuteTens[first] {
            if words.count == 1 { return t }
            if words.count == 2, let o = onesValues[words[1]] { return t + o }
        }
        return nil
    }

    /// Convert a spoken clock time to `H:MM` before the model sees it, so the
    /// 0.6B does not misconvert it (e.g. "three thirty" -> "3:00"). Conservative:
    /// fires only on an hour+minute run introduced by a time preposition
    /// ("at three thirty"), and the minute grammar excludes scale words, so
    /// "around twelve thousand" and "about nine hundred" are left untouched.
    static func convertSpokenTime(_ text: String) -> String {
        let prep = "at|around|by|before|after|until|from|to|for"
        let hour = "one|two|three|four|five|six|seven|eight|nine|ten|eleven"
            + "|twelve|\\d{1,2}"
        let minute = "o'?clock|oh\\s+(?:one|two|three|four|five|six|seven|eight"
            + "|nine)|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen"
            + "|seventeen|eighteen|nineteen|(?:twenty|thirty|forty|fifty)"
            + "(?:\\s+(?:one|two|three|four|five|six|seven|eight|nine))?"
        let pattern = "(?i)\\b(\(prep))\\s+(\(hour))\\s+(\(minute))"
            + "(?=\\s|[.,!?;:]|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        var result = text
        let matches = regex.matches(
            in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: result),
                let prepR = Range(match.range(at: 1), in: result),
                let hourR = Range(match.range(at: 2), in: result),
                let minR = Range(match.range(at: 3), in: result),
                let h = parseHour(String(result[hourR])),
                let m = parseMinute(
                    String(result[minR]).lowercased()
                        .split(separator: " ").map(String.init))
            else { continue }
            result.replaceSubrange(
                full,
                with: "\(result[prepR]) \(h):\(String(format: "%02d", m))")
        }
        return result
    }

    private static let teens: [(String, Int)] = [
        ("thirteen", 13), ("fourteen", 14), ("fifteen", 15),
        ("sixteen", 16), ("seventeen", 17), ("eighteen", 18),
        ("nineteen", 19),
    ]

    private static let onesValues: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    private static let onesWords = [
        "one", "two", "three", "four", "five",
        "six", "seven", "eight", "nine",
    ]

    /// Cardinals 1–12 that the spell-out style leaves as words. A percentage
    /// always takes a numeral, so these are converted when they directly
    /// precede "percent" (13 and up are already digits by then).
    private static let percentCardinals: [(String, Int)] = [
        ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5),
        ("six", 6), ("seven", 7), ("eight", 8), ("nine", 9),
        ("ten", 10), ("eleven", 11), ("twelve", 12),
    ]

    /// Convert unambiguous number words to digits.
    ///
    /// Handles hyphenated compounds ("twenty-seven" → "27"),
    /// space-separated compounds ("ninety nine" → "99"), and
    /// standalone tens ("eighty" → "80"). Avoids ambiguous words
    /// like "one", "two", or ordinals.
    static func convertNumberWords(_ text: String) -> String {
        var result = text

        // Step 0: Year patterns — "twenty twenty-seven" → "2027"
        // Must run before compound conversion so the year is consumed
        // as a whole unit.
        for (unit, digit) in digitWords {
            result = result.replacingOccurrences(
                of: "(?i)\\btwenty twenty-\(unit)\\b",
                with: "202\(digit)", options: .regularExpression)
            result = result.replacingOccurrences(
                of: "(?i)\\btwenty twenty \(unit)\\b",
                with: "202\(digit)", options: .regularExpression)
        }
        result = result.replacingOccurrences(
            of: "(?i)\\btwenty twenty\\b",
            with: "2020", options: .regularExpression)

        // Step 1: Hyphenated compounds — "twenty-seven" → "27"
        // Skip when preceded by a tens word (year pattern like
        // "twenty twenty-seven" should stay for the model).
        let tensPattern = tens.map(\.0).joined(separator: "|")
        for (ten, tenVal) in tens {
            for (unit, unitVal) in onesValues {
                let compound = "\(ten)-\(unit)"
                let digit = "\(tenVal + unitVal)"
                result = result.replacingOccurrences(
                    of: "(?i)(?<!(?:\(tensPattern)) )\\b\(compound)\\b",
                    with: digit,
                    options: .regularExpression)
            }
        }

        // Step 2: Space-separated compounds — "ninety nine" → "99"
        // Must run before standalone tens to avoid "ninety" → "90"
        // leaving "nine" orphaned. Skip when preceded by a tens word
        // (year pattern like "twenty twenty seven").
        for (ten, tenVal) in tens {
            for (unit, unitVal) in onesValues {
                let compound = "\(ten) \(unit)"
                let digit = "\(tenVal + unitVal)"
                result = result.replacingOccurrences(
                    of: "(?i)(?<!(?:\(tensPattern)) )\\b\(compound)\\b",
                    with: digit,
                    options: .regularExpression)
            }
        }

        // Step 3: Standalone tens — "eighty" → "80"
        // Guards:
        // - Not followed by a ones word ("ninety nine" handled in step 2)
        // - Not followed by scale/ordinal words that form compounds
        // - Not preceded by a number word or "and" after "hundred"
        //   (e.g., "two thirty" = 2:30, "two hundred and fifty" = 250)
        let tensWords = tens.map(\.0)
        let skipAfter = (onesWords + tensWords + [
            "hundred", "thousand", "million", "billion", "trillion",
            "first", "second", "third", "fourth", "fifth",
            "sixth", "seventh", "eighth", "ninth",
        ]).joined(separator: "|")
        let skipBefore = (onesWords + tensWords + [
            "hundred",
        ]).joined(separator: "|")
        for (ten, tenVal) in tens {
            result = result.replacingOccurrences(
                of: "(?i)(?<!(?:\(skipBefore)) )(?<!hundred and )\\b\(ten)\\b(?![ -](?:\(skipAfter))\\b)(?! \\d)",
                with: "\(tenVal)",
                options: .regularExpression)
        }

        // Step 4: Standalone teens — "thirteen" → "13"
        // Same guards as tens: not before scale/ordinal words,
        // not after "hundred" (e.g., "one hundred thirteen").
        for (teen, teenVal) in teens {
            result = result.replacingOccurrences(
                of: "(?i)(?<!hundred )(?<!hundred and )\\b\(teen)\\b(?![ -](?:\(skipAfter))\\b)(?! \\d)",
                with: "\(teenVal)",
                options: .regularExpression)
        }

        return result
    }

    // MARK: - Cloud System Prompt

    /// Build a dynamic system prompt for cloud polish models.
    ///
    /// Start with the language-appropriate cloud prompt and append
    /// optional context lines for casual mode and preceding text.
    /// Cloud models (GPT) follow instructions natively — no training
    /// needed, just clear instructions.
    public static func buildCloudSystemPrompt(
        context: AppContext, language: String?
    ) -> String {
        let usesCasualEnglish = language == "en"
            && toneLabel(for: context.bundleID) == "casual"
        var prompt = usesCasualEnglish
            ? systemPromptCasual
            : systemPrompt(forLanguage: language)

        if let content = context.focusedFieldContent,
           !content.isEmpty
        {
            let suffix: String
            if content.count > 80 {
                suffix = String(content.suffix(80))
            } else {
                suffix = content
            }
            let sanitized = sanitizeContextField(suffix)
            if !sanitized.isEmpty {
                prompt += "\nPreceding text: \(sanitized)"
            }
        }

        return prompt
    }

    // MARK: - Keep Tag Processing

    private static let keepTagPattern = try! NSRegularExpression(
        pattern: #"<keep>(.*?)</keep>"#)

    /// Remove `<keep>` tags, leaving their content in place.
    ///
    /// Expand `[PAR]` and `[NL]` placeholders to real line breaks.
    /// Clean up whitespace around revealed symbols.
    public static func stripKeepTags(
        _ text: String, casual: Bool = false, expandBreaks: Bool = true
    ) -> String {
        var result = text

        // Strip tags, keep content.
        result = keepTagPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1")

        // Expand break placeholders to real newlines. Skipped when the
        // caller wants breaks carried as literal `[PAR]`/`[NL]` tokens
        // through the model — so model-invented newlines can be stripped
        // afterward and only commanded breaks expand back to real ones.
        if expandBreaks {
            result = result.replacingOccurrences(
                of: " *\\[PAR\\] *", with: "\n\n", options: .regularExpression)
            result = result.replacingOccurrences(
                of: " *\\[NL\\] *", with: "\n", options: .regularExpression)
            // Legacy placeholders (pilcrow / return arrow).
            result = result.replacingOccurrences(
                of: " *\u{00b6} *", with: "\n\n", options: .regularExpression)
            result = result.replacingOccurrences(
                of: " *\u{21b5} *", with: "\n", options: .regularExpression)
            // Drop a stray period a line break inherited from "new paragraph"
            // that followed a sentence period in the input.
            result = result.replacingOccurrences(
                of: "\n( *\\.)+ *", with: "\n", options: .regularExpression)
        }

        // Clean up whitespace around symbols that were inside tags.
        // Punctuation that attaches to preceding word.
        result = result.replacingOccurrences(
            of: " +([.,;:?!)\\]>\u{201d}\u{2026}%\u{2122}\u{00a9}\u{00b0}])",
            with: "$1",
            options: .regularExpression)

        // Symbols that attach to following word.
        result = result.replacingOccurrences(
            of: "([(\\[\u{201c}#$<]) +",
            with: "$1",
            options: .regularExpression)

        // Symbols that attach on both sides.
        result = result.replacingOccurrences(
            of: " *([-@/\\\\_'\u{2013}\u{2014}]) +",
            with: "$1",
            options: .regularExpression)

        // Asterisks: collapse internal spaces in asterisk groups.
        // "* really *" → "*really*", "* * * *" → "****"
        // Matches a run starting and ending with * (with optional
        // content between), collapses all spaces within the run.
        result = collapseAsteriskGroups(result)

        // Collapse multiple spaces.
        result = result.replacingOccurrences(
            of: " {2,}", with: " ", options: .regularExpression)

        if !casual {
            // Capitalize the first letter after a sentence terminator, as the
            // input preprocessing does: the model often leaves a sentence it
            // split (or one that starts at a unit seam) lowercase.
            result = capitalizeAfterPattern(result, pattern: "([.!?]\\s+)(\\w)")
            // Capitalize first letter after paragraph/line breaks.
            result = capitalizeAfterPattern(result, pattern: "(\\n)(\\w)")
            // Capitalize the standalone pronoun "i" ("i think" -> "I think",
            // "i'll" -> "I'll"), which the model sometimes leaves lowercase.
            result = result.replacingOccurrences(
                of: "(?<![A-Za-z])i(?![A-Za-z])", with: "I",
                options: .regularExpression)
        }

        return result
    }

    /// Collapse every run of model-emitted newlines to a single space.
    /// Literal `[PAR]`/`[NL]` tokens are left untouched so commanded
    /// breaks survive to be expanded by `normalizeFormatting`.
    static func stripModelNewlines(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[ \\t]*\\n+[ \\t]*", with: " ", options: .regularExpression)
    }

    // MARK: - Normalize Formatting

    /// Fix common LLM formatting inconsistencies.
    public static func normalizeFormatting(
        _ text: String, casual: Bool = false
    ) -> String {
        var result = text

        // Safety net for leaked placeholders.
        result = result.replacingOccurrences(
            of: " *\\[PAR\\] *", with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(
            of: " *\\[NL\\] *", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(
            of: " *\u{00b6} *", with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(
            of: " *\u{21b5} *", with: "\n", options: .regularExpression)

        // Collapse doubled slashes (guard :// in URLs).
        result = result.replacingOccurrences(
            of: "(?<!:)//", with: "/", options: .regularExpression)

        // Collapse doubled backslashes between word characters.
        result = result.replacingOccurrences(
            of: "(?<=\\w)\\\\\\\\(?=\\w)", with: "\\\\",
            options: .regularExpression)

        // Normalize a.m./p.m. to AM/PM.
        // Primary conversion happens in substituteDictatedPunctuation
        // (before split-word rejoin). This is a safety net for any
        // a.m./p.m. that the model re-introduces in its output.
        result = result.replacingOccurrences(
            of: #"\ba\.m\.(?= [A-Z])"#, with: "AM.", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\ba\.m\.(?= )"#, with: "AM", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\ba\.m\.(?=$|\n)"#, with: "AM.", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\bp\.m\.(?= [A-Z])"#, with: "PM.", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\bp\.m\.(?= )"#, with: "PM", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\bp\.m\.(?=$|\n)"#, with: "PM.", options: .regularExpression)

        // Collapse redundant terminal punctuation (e.g. "!." → "!").
        result = result.replacingOccurrences(
            of: #"([!?])\."#, with: "$1", options: .regularExpression)

        // A percentage always takes a numeral, even for the small numbers the
        // spell-out style otherwise leaves as words ("five percent" -> "5%",
        // "twelve percent" -> "12%"). Only fires directly before "percent", so
        // "five items" stays spelled.
        for (word, digit) in percentCardinals {
            result = result.replacingOccurrences(
                of: "(?i)\\b\(word) percent\\b",
                with: "\(digit) percent", options: .regularExpression)
        }

        // Convert "X percent" → "X%" when preceded by a number.
        result = result.replacingOccurrences(
            of: #"\b(\d+(?:\.\d+)?) percent\b"#,
            with: "$1%", options: .regularExpression)

        // Process line by line.
        // Strip trailing whitespace, normalize bullets, and strip
        // trailing periods from list items for consistent style.
        let lines = result.split(
            separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        for line in lines {
            var l = String(line)
            // Strip trailing whitespace.
            while l.hasSuffix(" ") || l.hasSuffix("\t") {
                l = String(l.dropLast())
            }
            // Normalize bullet items: "-X" -> "- X".
            l = l.replacingOccurrences(
                of: "^(\\s*)-(\\S)",
                with: "$1- $2",
                options: .regularExpression)
            // Strip trailing period from list items (bullet or numbered).
            if l.hasSuffix("."),
               l.range(of: #"^\s*(?:-|\d+\.)\s+"#,
                       options: .regularExpression) != nil
            {
                l = String(l.dropLast())
            }
            output.append(l)
        }
        result = output.joined(separator: "\n")

        if !casual {
            // Fix capitalization of known tech terms. These are product
            // names that should always be capitalized the same way. This
            // is additive only — never removes or transforms content.
            result = capitalizeKnownTerms(result)

            // Capitalize the first letter after a sentence terminator or a
            // line break. The model frequently lowercases its output and
            // leaves a sentence it kept mid-string (or one that begins at a
            // unit seam) uncapitalized. The input preprocessing already does
            // this, so mirror it on the output.
            result = capitalizeAfterPattern(result, pattern: "([.!?]\\s+)(\\w)")
            result = capitalizeAfterPattern(result, pattern: "(\\n)(\\w)")
        }

        return result
    }

    // MARK: - Known Term Capitalization

    /// Terms mapped from lowercase to correct capitalization.
    /// Only whole-word matches are replaced to avoid mangling
    /// substrings (e.g. "redis" in "predispose").
    private static let knownTerms: [(NSRegularExpression, String)] = {
        let terms: [(String, String)] = [
            // Databases
            ("redis", "Redis"),
            ("memcached", "Memcached"),
            ("elasticsearch", "Elasticsearch"),
            ("postgresql", "PostgreSQL"),
            ("postgres", "Postgres"),
            ("mongodb", "MongoDB"),
            ("mysql", "MySQL"),
            ("sqlite", "SQLite"),
            ("dynamodb", "DynamoDB"),
            ("cassandra", "Cassandra"),
            ("couchdb", "CouchDB"),
            // Infrastructure / DevOps
            ("kubernetes", "Kubernetes"),
            ("docker", "Docker"),
            ("terraform", "Terraform"),
            ("ansible", "Ansible"),
            ("jenkins", "Jenkins"),
            ("nginx", "Nginx"),
            ("apache", "Apache"),
            ("grafana", "Grafana"),
            ("prometheus", "Prometheus"),
            ("datadog", "Datadog"),
            ("splunk", "Splunk"),
            ("istio", "Istio"),
            ("pagerduty", "PagerDuty"),
            ("cloudflare", "Cloudflare"),
            ("vercel", "Vercel"),
            ("supabase", "Supabase"),
            ("heroku", "Heroku"),
            // Messaging / streaming
            ("rabbitmq", "RabbitMQ"),
            ("kafka", "Kafka"),
            // Languages / runtimes
            ("javascript", "JavaScript"),
            ("typescript", "TypeScript"),
            ("python", "Python"),
            ("kotlin", "Kotlin"),
            ("java", "Java"),
            ("swift", "Swift"),
            ("rust", "Rust"),
            ("golang", "Golang"),
            // Frameworks / libraries
            ("react", "React"),
            ("angular", "Angular"),
            ("vue", "Vue"),
            ("svelte", "Svelte"),
            ("django", "Django"),
            ("flask", "Flask"),
            ("fastapi", "FastAPI"),
            ("nextjs", "Next.js"),
            ("nodejs", "Node.js"),
            ("nuxt", "Nuxt"),
            ("webpack", "Webpack"),
            ("vite", "Vite"),
            ("numpy", "NumPy"),
            ("pandas", "Pandas"),
            ("pytorch", "PyTorch"),
            ("tensorflow", "TensorFlow"),
            ("swiftui", "SwiftUI"),
            ("combine", "Combine"),
            // Cloud services
            ("firebase", "Firebase"),
            // Platforms / tools
            ("github", "GitHub"),
            ("gitlab", "GitLab"),
            ("bitbucket", "Bitbucket"),
            ("jira", "Jira"),
            ("confluence", "Confluence"),
            ("notion", "Notion"),
            ("slack", "Slack"),
            ("zoom", "Zoom"),
            ("figma", "Figma"),
            ("linear", "Linear"),
            // Abbreviations
            ("lgtm", "LGTM"),
            // Products
            ("macos", "macOS"),
            ("ios", "iOS"),
            ("iphone", "iPhone"),
            ("ipad", "iPad"),
            ("watchos", "watchOS"),
            ("xcode", "Xcode"),
            // Cloud providers
            ("aws", "AWS"),
            ("gcp", "GCP"),
            ("azure", "Azure"),
            ("amazon", "Amazon"),
            ("google", "Google"),
            ("microsoft", "Microsoft"),
            // Tech acronyms (3+ chars, unambiguous)
            ("api", "API"),
            ("sql", "SQL"),
            ("css", "CSS"),
            ("html", "HTML"),
            // Note: "http" and "https" omitted — they appear in URLs
            // (https://...) where capitalizing would break the URL.
            ("json", "JSON"),
            ("xml", "XML"),
            ("yaml", "YAML"),
            ("url", "URL"),
            ("cli", "CLI"),
            ("sdk", "SDK"),
            ("dns", "DNS"),
            ("tcp", "TCP"),
            ("ssh", "SSH"),
            ("ssl", "SSL"),
            ("tls", "TLS"),
            ("vpn", "VPN"),
            ("cdn", "CDN"),
            // French loanwords — always use accented form
            ("cafe", "café"),
            ("resume", "résumé"),
            ("fiance", "fiancé"),
            ("fiancee", "fiancée"),
            ("naive", "naïve"),
            ("protege", "protégé"),
            ("entrees", "entrées"),
            ("entree", "entrée"),
        ]
        return terms.map { (pattern, replacement) in
            // Case-insensitive whole-word match. Negative lookbehind
            // for "/" to avoid capitalizing inside paths like
            // "application/json".
            // swiftlint:disable:next force_try
            let regex = try! NSRegularExpression(
                pattern: "(?<!/)(?<=\\b)\(NSRegularExpression.escapedPattern(for: pattern))(?=\\b)",
                options: .caseInsensitive)
            return (regex, replacement)
        }
    }()

    /// Multi-word phrase transforms — patterns that span multiple words.
    /// Compiled once at startup like knownTerms.
    private static let knownPhrases: [(NSRegularExpression, String)] = {
        let phrases: [(String, String)] = [
            // Number idioms — keep as words, not digits
            ("one on one", "one-on-one"),
            // HTTP terms (only as phrases to avoid false positives)
            ("bearer token", "Bearer token"),
            ("authorization header", "Authorization header"),
            ("content type", "Content-Type"),
            ("cache control", "Cache-Control"),
            ("cache-control", "Cache-Control"),
            ("accept header", "Accept header"),
            ("x forwarded for", "X-Forwarded-For"),
            ("x-forwarded-for", "X-Forwarded-For"),
            ("api key", "API key"),
            ("fetch api", "Fetch API"),
            // Place names
            ("new york", "New York"),
            ("san francisco", "San Francisco"),
            ("los angeles", "Los Angeles"),
            ("las vegas", "Las Vegas"),
            // Number idioms — convert back from digits to words
            ("square 1", "square one"),
            ("day 1", "day one"),
            ("1 on 1", "one-on-one"),
            ("1-on-1", "one-on-one"),
            ("2 to tango", "two to tango"),
            // Node.js variants
            ("node js", "Node.js"),
            ("node.js", "Node.js"),
            // Units
            ("gigs of", "GB of"),
            // French phrases
            ("raison d'etre", "raison d'être"),
            ("tete a tete", "tête-à-tête"),
            ("tete-a-tete", "tête-à-tête"),
            // AWS service phrases
            ("s3 bucket", "S3 bucket"),
            ("ec2 instance", "EC2 instance"),
            ("rds database", "RDS database"),
            ("sqs queue", "SQS queue"),
            ("sns topic", "SNS topic"),
            ("iam role", "IAM role"),
            ("gke cluster", "GKE cluster"),
            ("eks cluster", "EKS cluster"),
            // AWS regions
            ("us east one", "us-east-1"),
            ("us east two", "us-east-2"),
            ("us west one", "us-west-1"),
            ("us west two", "us-west-2"),
            ("eu west one", "eu-west-1"),
            ("eu west two", "eu-west-2"),
            ("eu central one", "eu-central-1"),
            ("ap southeast one", "ap-southeast-1"),
            ("ap northeast one", "ap-northeast-1"),
        ]
        return phrases.map { (pattern, replacement) in
            // swiftlint:disable:next force_try
            let regex = try! NSRegularExpression(
                pattern: "(?<=\\b)\(NSRegularExpression.escapedPattern(for: pattern))(?=\\b)",
                options: .caseInsensitive)
            return (regex, replacement)
        }
    }()

    /// Replace known tech terms with their correct capitalization
    /// and apply known phrase transforms.
    static func capitalizeKnownTerms(_ text: String) -> String {
        var result = text
        // Multi-word phrases first (before single words break them).
        for (regex, replacement) in knownPhrases {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement)
        }
        for (regex, replacement) in knownTerms {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement)
        }
        return result
    }

    // MARK: - Verb-Prep Rejoin

    /// Verbs that govern "on" as a modifier ("the layout *breaks on* small
    /// screens", "the sync *times out on* large accounts"). After such a verb,
    /// "on X" is almost never a new heading, so a split there is a mis-attach.
    /// Nouns before "on" are deliberately excluded: "usage on X" (keep) versus
    /// "redesign on X" (split) is genuinely ambiguous, which the model handles.
    static let verbsGoverningOn: Set<String> = [
        "breaks", "break", "broke", "broken",
        "crashes", "crash", "crashed",
        "freezes", "freeze", "froze", "frozen",
        "hangs", "hang", "hung",
        "lags", "lag", "lagged",
        "depends", "depend", "depended",
        "relies", "rely", "relied",
        "fails", "fail", "failed",
        "spikes", "spike", "spiked",
        "hinges", "hinge", "hinged",
        "based", "focused", "blocked", "waiting",
        // Additional unambiguous "verb + on" collocations. Deliberately omits
        // noun homographs (acts, feeds, touches, borders, land) and phrasals
        // whose token before "on" is "out" (times/maxes out on).
        "lands", "landed",
        "insists", "insist", "insisted",
        "elaborates", "elaborate", "elaborated",
        "capitalizes", "capitalize", "capitalized",
        "dwells", "dwell", "dwelt", "dwelled",
        "verges", "preys", "preyed",
        "agrees", "agree", "agreed",
        "decides", "decide", "decided",
        "operates", "operate", "operated",
        "reflects", "reflect", "reflected",
        "draws", "drew",
        "thrives", "thrive", "thrived",
        "weighs", "weigh", "weighed",
        "impinges", "impinge", "impinged",
    ]

    private static let verbPrepSplitPattern = try! NSRegularExpression(
        pattern: #"\b(\w+)\.\s+On\s+([A-Za-z][^,.\n]*?)\s*([,.])"#)

    /// Rejoin a verb-prep modifier the model wrongly split into a heading.
    ///
    /// When the model turns "<verb> on <X>" into a fronted heading
    /// ("<verb>. On <X>, ..."), and the raw `input` had "<verb> on <X>"
    /// contiguous, move the boundary back so it reads "<verb> on <X>. ...".
    /// Only sentence punctuation moves — no content word is added or dropped —
    /// so the fidelity guards still bound the result. The word after the new
    /// period is re-capitalized by `normalizeFormatting`.
    static func rejoinVerbPrepModifier(_ output: String, input: String) -> String {
        let ns = output as NSString
        let matches = verbPrepSplitPattern.matches(
            in: output, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return output }

        let inputNorm = input.lowercased().replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)

        var result = ""
        var lastEnd = 0
        for match in matches {
            let verb = ns.substring(with: match.range(at: 1))
            let x = ns.substring(with: match.range(at: 2))
            let matchStart = match.range.location
            let matchEnd = match.range.location + match.range.length
            // Fire only for a verb that governs "on", and only when the raw
            // input actually had "<verb> on <X>" contiguous (so this was a
            // split, not a genuine heading the speaker introduced).
            guard verbsGoverningOn.contains(verb.lowercased()),
                  inputNorm.contains("\(verb.lowercased()) on \(x.lowercased())")
            else { continue }
            result += ns.substring(with: NSRange(
                location: lastEnd, length: matchStart - lastEnd))
            result += "\(verb) on \(x)."
            lastEnd = matchEnd
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    // MARK: - Frequency-Adverb Restoration

    /// Frequency and recurrence adverbs form a closed class the model must
    /// never rewrite: swapping one for another ("occasionally" -> "often")
    /// always changes how often something happens, which polish never
    /// legitimately does. Kept closed so the restore below only ever touches a
    /// genuine one-for-another swap.
    static let frequencyAdverbs: Set<String> = [
        "never", "rarely", "seldom", "infrequently",
        "occasionally", "sometimes", "periodically", "intermittently",
        "sporadically", "often", "oftentimes", "frequently",
        "usually", "normally", "generally", "regularly",
        "routinely", "typically", "commonly", "mostly",
        "always", "constantly", "continually", "continuously",
        "repeatedly",
    ]

    /// Count each frequency adverb (case-insensitive, whole word) in `text`.
    private static func frequencyAdverbCounts(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        var current = ""
        func flush() {
            if frequencyAdverbs.contains(current) {
                counts[current, default: 0] += 1
            }
            current = ""
        }
        for ch in text.lowercased() {
            if ch.isLetter { current.append(ch) } else { flush() }
        }
        flush()
        return counts
    }

    /// Restore a frequency adverb the model swapped for another.
    ///
    /// When the polished `output` drops exactly one frequency adverb the raw
    /// `input` had and introduces exactly one it did not — a clean
    /// one-for-another swap, with the same total count so nothing was added or
    /// dropped — put the spoken word back. Only that single content word
    /// changes, so the fidelity guards still bound the result. A reorder (the
    /// multiset is unchanged) or an add/drop (unequal totals) is left to the
    /// other guards.
    static func restoreFrequencyAdverb(_ output: String, input: String) -> String {
        let inCounts = frequencyAdverbCounts(in: input)
        let outCounts = frequencyAdverbCounts(in: output)
        guard inCounts != outCounts,
              inCounts.values.reduce(0, +) == outCounts.values.reduce(0, +)
        else { return output }

        var missing: [String] = []
        for (word, count) in inCounts {
            let extra = count - (outCounts[word] ?? 0)
            if extra > 0 { missing += Array(repeating: word, count: extra) }
        }
        var foreign: [String] = []
        for (word, count) in outCounts {
            let extra = count - (inCounts[word] ?? 0)
            if extra > 0 { foreign += Array(repeating: word, count: extra) }
        }
        guard missing.count == 1, foreign.count == 1 else { return output }

        let pattern = try! NSRegularExpression(
            pattern: "\\b" + NSRegularExpression.escapedPattern(for: foreign[0])
                + "\\b",
            options: [.caseInsensitive])
        let ns = output as NSString
        guard let match = pattern.firstMatch(
            in: output, range: NSRange(location: 0, length: ns.length))
        else { return output }
        let matched = ns.substring(with: match.range)
        let replacement = matched.first?.isUppercase == true
            ? missing[0].prefix(1).uppercased() + missing[0].dropFirst()
            : missing[0]
        return ns.replacingCharacters(in: match.range, with: replacement)
    }

    // MARK: - Full Polish Pipeline

    /// How dictated paragraph/line breaks are handled through the model.
    public enum BreakMode: Sendable {
        /// Expand `[PAR]`/`[NL]` to real newlines before the model, and
        /// keep whatever breaks the model returns. Suits whole-transcript
        /// polish, where the model has full context to paragraph well.
        case expandBeforeModel
        /// Split at each `[PAR]`/`[NL]`, polish the text segments with all
        /// model-emitted newlines stripped, then rejoin with the commanded
        /// break inserted deterministically. Suits per-chunk streaming
        /// polish, where the model otherwise over-breaks a single
        /// committed sentence. Breaks never depend on the model.
        case commandsOnly
    }

    /// Total resample attempts a single finalize may spend across all of its
    /// segments before the remaining failing segments fall back to raw
    /// promptly. Bounds the post-release wait without denying a single
    /// failing segment its usual recovery.
    private static let finalizeResampleBudget = 2

    /// postprocess. This is the single source of truth for how raw
    /// dictated text becomes polished output. Used by both the
    /// streaming provider and the eval test suite.
    public static func polish(
        _ raw: String,
        chatClient: (any PolishChatClient)?,
        model: String = polishModel,
        tone: String? = nil,
        precedingText: String? = nil,
        breakMode: BreakMode = .expandBeforeModel,
        finalFlush: Bool = false
    ) async -> String {
        let casual = tone == "casual"
        let substituted = substituteDictatedPunctuation(
            raw, casual: casual, precedingText: precedingText)

        // Whole-transcript polish: expand commanded breaks before the
        // model and keep the model's own paragraphing.
        if breakMode == .expandBeforeModel {
            return await polishUnit(
                substituted: substituted, chatClient: chatClient,
                model: model, tone: tone, precedingText: precedingText,
                casual: casual, stripModelBreaks: false).text
        }

        // Per-chunk streaming polish: keep only commanded breaks. Split at
        // each `[PAR]`/`[NL]`, polish the token-free text segments (whose
        // model-emitted newlines are all stripped), then rejoin with the
        // commanded break inserted deterministically. Breaks no longer
        // depend on the model preserving a break token.
        //
        // The break separates sentences on its own, so drop a stray
        // terminator the recognizer left right after the spoken command
        // (e.g. "new paragraph." → the trailing period would otherwise
        // become a "." fragment at the start of the next segment).
        let forSplit = substituted.replacingOccurrences(
            of: #"(<keep>\[(?:PAR|NL)\]</keep>)\s*[.,;:]+"#,
            with: "$1", options: .regularExpression)
        let segments = splitOnCommands(forSplit)
        if segments.count == 1 {
            // A single-segment finalize keeps full resample recovery — the
            // compounding post-release wait only comes from many segments each
            // retrying, so one segment is already bounded.
            return await polishUnit(
                substituted: segments[0].text, chatClient: chatClient,
                model: model, tone: tone, precedingText: precedingText,
                casual: casual, stripModelBreaks: true).text
        }

        var result = ""
        // Only the first segment inherits the caller's preceding text.
        // Every later segment begins a fresh line or paragraph, so it
        // polishes without preceding context — which also capitalizes its
        // first character as a paragraph start.
        var preceding = precedingText
        // The finalize shares one resample budget across all of its segments,
        // so several failing segments can't each pay the full 3× retry and
        // stack into a long post-release wait. Streaming units (finalFlush
        // false) stay unbounded — their resamples are absorbed while the user
        // is still speaking.
        var resampleBudget = finalFlush ? finalizeResampleBudget : Int.max
        for segment in segments {
            // Trim the segment so its first character is the real word:
            // a leading space left by the split would otherwise defeat the
            // paragraph-start capitalization.
            let text = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let (block, used) = await polishUnit(
                    substituted: text, chatClient: chatClient,
                    model: model, tone: tone, precedingText: preceding,
                    casual: casual, stripModelBreaks: true,
                    maxResamples: min(2, resampleBudget))
                resampleBudget -= used
                result += block.trimmingCharacters(in: .whitespaces)
            }
            result += segment.breakAfter
            preceding = nil
        }
        return result
    }

    /// Polish one already-substituted text unit through the model: run it,
    /// apply the echo/hallucination/truncation guards, and normalize.
    ///
    /// When `stripModelBreaks` is true, every newline the model emits is
    /// collapsed — the caller reinserts commanded breaks around this unit.
    /// Otherwise commanded breaks were already expanded to newlines before
    /// the model and are kept.
    /// Debug-only diagnostic: emit the deterministic-vs-model stages of one
    /// polish (preprocessed model input, raw model output, and the final text
    /// after post-processing + guards) when the unit-trace flag file is
    /// present. Compiled out of Release — it logs dictated content — see
    /// `ProductionSurfaceTests`.
    private static func tracePolish(
        modelIn: String, modelOut: String, final: String, guardAction: String
    ) {
        #if DEBUG
        guard FileManager.default.fileExists(atPath: "/tmp/unramble-unit-trace")
        else { return }
        if let data = try? JSONSerialization.data(withJSONObject: [
            "model_in": modelIn, "model_out": modelOut,
            "final": final, "guard": guardAction,
        ]), let line = String(data: data, encoding: .utf8) {
            Log.debug("[[POLISH]] \(line)")
        }
        #endif
    }

    private static func polishUnit(
        substituted: String,
        chatClient: (any PolishChatClient)?,
        model: String,
        tone: String?,
        precedingText: String?,
        casual: Bool,
        stripModelBreaks: Bool,
        maxResamples: Int = 2
    ) async -> (text: String, resamplesUsed: Int) {
        let stripped = stripKeepTags(
            substituted, casual: casual, expandBreaks: !stripModelBreaks)

        guard let chatClient else {
            return (normalizeFormatting(stripped, casual: casual), 0)
        }

        let noPreceding = precedingText == nil || precedingText!.isEmpty

        do {
            // Greedy on the first attempt; when a guard fires, resample with a
            // little temperature and try again before falling back to raw.
            // Fidelity is unchanged either way — the guards bound every
            // attempt — but a resample often recovers a usable polish. The
            // caller caps `maxResamples`: the final flush shares one small
            // resample budget across all its segments, so a multi-segment
            // finalize can't compound many 3× retries into a long post-release
            // wait, while a single-segment finalize still gets full recovery.
            var lastModelOut = ""
            let temperatures =
                [0.0] + Array(repeating: 0.4, count: max(0, min(2, maxResamples)))
            for (attempt, temperature) in temperatures.enumerated() {
                let polished = try await polishThroughModel(
                    stripped, chatClient: chatClient, model: model,
                    tone: tone, precedingText: precedingText,
                    temperature: temperature)
                if polished.isEmpty { continue }
                lastModelOut = polished

                var cleaned = guardAgainstEcho(
                    polished: polished, precedingText: precedingText)
                // Strip a leading run that re-emits the tail of the preceding
                // context (a partial echo guardAgainstEcho misses). It removes
                // only already-injected duplicate content, so the guards below
                // still hold — and it lets a bled but otherwise-good polish
                // pass the greedy attempt instead of falling back to raw.
                cleaned = stripBledPrefix(cleaned, precedingText: precedingText)
                // Undo a verb-prep modifier the model split into a heading
                // ("layout breaks. On small screens," -> "breaks on small
                // screens."). Punctuation-only, so the guards below still hold.
                cleaned = rejoinVerbPrepModifier(cleaned, input: stripped)
                // Put back a frequency adverb the model swapped for another
                // ("occasionally" -> "often"): a closed-class, one-for-one swap
                // that always changes meaning. One content word, so the guards
                // below still hold.
                cleaned = restoreFrequencyAdverb(cleaned, input: stripped)
                if stripModelBreaks {
                    cleaned = stripModelNewlines(cleaned)
                }
                if stripped.contains("\u{2026}") {
                    cleaned = cleaned.replacingOccurrences(
                        of: "...", with: "\u{2026}")
                }

                // The batch path keeps the model's edits (so intentional
                // corrections survive); the streaming path also rejects a
                // dropped or invented run of content words.
                let guardFires = guardAgainstHallucination(
                        polished: cleaned, preprocessed: stripped) != nil
                    || guardAgainstTruncation(
                        polished: cleaned, preprocessed: stripped) != nil
                    || (stripModelBreaks && guardAgainstContentLoss(
                        polished: cleaned, preprocessed: stripped) != nil)
                    || (stripModelBreaks && guardAgainstFabrication(
                        polished: cleaned, preprocessed: stripped) != nil)
                    || (stripModelBreaks && guardAgainstDuplication(
                        polished: cleaned, preprocessed: stripped) != nil)
                    || (stripModelBreaks && guardAgainstNumberChange(
                        polished: cleaned, preprocessed: stripped) != nil)
                if !guardFires {
                    if attempt > 0 {
                        Log.debug("[POLISH_RESAMPLE_OK] attempt=\(attempt)")
                    }
                    let out = adjustFirstCharCasing(
                        normalizeFormatting(cleaned, casual: casual),
                        preprocessed: stripped, casual: casual,
                        noPreceding: noPreceding)
                    tracePolish(modelIn: stripped, modelOut: polished,
                        final: out, guardAction: attempt == 0 ? "ok"
                            : "resample\(attempt)")
                    return (out, attempt)
                }
            }

            // Every attempt failed a guard or was empty: keep the raw unit, so
            // nothing is dropped, invented, or truncated.
            Log.debug("[POLISH_RAW_FALLBACK] all attempts failed guards")
            let out = adjustFirstCharCasing(
                normalizeFormatting(stripped, casual: casual),
                preprocessed: stripped, casual: casual,
                noPreceding: noPreceding)
            tracePolish(modelIn: stripped, modelOut: lastModelOut,
                final: out, guardAction: "RAW_FALLBACK")
            return (out, temperatures.count - 1)
        } catch {
            Log.debug("[PolishPipeline] Polish failed: \(error)")
            return (normalizeFormatting(stripped, casual: casual), 0)
        }
    }

    /// Split substituted text at each `[PAR]`/`[NL]` command token into
    /// segments, each carrying the break that follows it (`"\n\n"` for a
    /// paragraph, `"\n"` for a line, or `""` for the final segment).
    private static let commandTokenPattern = try! NSRegularExpression(
        pattern: #"<keep>\[(PAR|NL)\]</keep>"#)

    private static func splitOnCommands(
        _ text: String
    ) -> [(text: String, breakAfter: String)] {
        let ns = text as NSString
        var segments: [(String, String)] = []
        var lastEnd = 0
        let matches = commandTokenPattern.matches(
            in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let seg = ns.substring(with: NSRange(
                location: lastEnd, length: match.range.location - lastEnd))
            let kind = ns.substring(with: match.range(at: 1))
            segments.append((seg, kind == "PAR" ? "\n\n" : "\n"))
            lastEnd = match.range.location + match.range.length
        }
        segments.append((ns.substring(from: lastEnd), ""))
        return segments
    }

    // MARK: - Tone Mapping

    /// Known casual app bundle IDs — chat and messaging apps where
    /// users expect informal tone: lowercase starts, no trailing
    /// periods, contractions preserved.
    private static let casualBundleIDs: Set<String> = [
        // Apple
        "com.apple.MobileSMS",          // Messages
        // Slack
        "com.tinyspeck.slackmacgap",
        // Discord
        "com.hnc.Discord",
        // Telegram
        "ru.keepcoder.Telegram",
        // WhatsApp
        "net.whatsapp.WhatsApp",
        // Signal
        "org.whispersystems.signal-desktop",
        // Microsoft Teams (chat context)
        "com.microsoft.teams2",
    ]

    /// Return the tone label for a given bundle ID.
    ///
    /// Returns `"casual"` for chat/messaging apps, `nil` for everything
    /// else (which uses the default formal behavior).
    public static func toneLabel(for bundleID: String) -> String? {
        casualBundleIDs.contains(bundleID) ? "casual" : nil
    }

    // MARK: - Context Formatting

    /// Build the user prompt for the LLM polishing call.
    /// Strip known prompt-injection markers from a context field.
    ///
    /// Remove ChatML delimiters, role-like line prefixes, and other
    /// patterns that could trick the LLM into following injected
    /// instructions embedded in window titles, URLs, or field content.
    public static func sanitizeContextField(_ text: String) -> String {
        var result = text
        // Strip ChatML delimiters.
        result = result.replacingOccurrences(of: "<|im_start|>", with: "")
        result = result.replacingOccurrences(of: "<|im_end|>", with: "")
        // Strip <keep> tags so context fields cannot inject protected
        // content that the LLM would preserve verbatim.
        result = result.replacingOccurrences(of: "<keep>", with: "")
        result = result.replacingOccurrences(of: "</keep>", with: "")
        // Strip role-like prefixes at the start of the string or after
        // newlines (e.g. "SYSTEM:", "USER:", "ASSISTANT:").
        if let regex = try? NSRegularExpression(
            pattern: #"(?:^|\n)\s*(SYSTEM|USER|ASSISTANT)\s*:"#,
            options: .caseInsensitive
        ) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func buildUserPrompt(
        _ text: String, context: AppContext, language: String? = nil,
        includeFieldContent: Bool = true
    ) -> String {
        var parts = ["Transcription:\n\(text)"]

        if let language {
            parts.append("Language: \(language)")
        }

        var ctxLines: [String] = []
        let appName = sanitizeContextField(context.appName)
        if !appName.isEmpty {
            ctxLines.append("App: \(appName)")
        }
        let windowTitle = sanitizeContextField(context.windowTitle)
        if !windowTitle.isEmpty {
            ctxLines.append("Window: \(windowTitle)")
        }
        if includeFieldContent, let url = context.browserURL {
            ctxLines.append("URL: \(sanitizeContextField(url))")
        }
        if includeFieldContent, let content = context.focusedFieldContent {
            // cursorPosition is a UTF-16 offset from macOS accessibility
            // APIs (NSString-style). Use the utf16 view for windowing.
            var truncated: String
            let utf16Count = content.utf16.count
            if utf16Count > 2000 {
                let pos = context.cursorPosition ?? utf16Count
                let start16 = max(0, pos - 1000)
                let end16 = min(utf16Count, pos + 1000)
                let startIdx = String.Index(
                    utf16Offset: start16, in: content)
                let endIdx = String.Index(
                    utf16Offset: end16, in: content)
                truncated = String(content[startIdx..<endIdx])
                if start16 > 0 { truncated = "..." + truncated }
                if end16 < utf16Count { truncated = truncated + "..." }
            } else {
                truncated = content
            }
            // Sanitize after truncation so injection markers within the
            // cursor window are always stripped.
            truncated = sanitizeContextField(truncated)
            ctxLines.append("Field content:\n\(truncated)")
        }
        if includeFieldContent, let pos = context.cursorPosition {
            ctxLines.append("Cursor position: \(pos)")
        }
        if includeFieldContent, let selected = context.selectedText {
            ctxLines.append("Selected text: \(sanitizeContextField(selected))")
        }

        if !ctxLines.isEmpty {
            parts.append("Context:\n" + ctxLines.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - System Prompts

    // Prompt text is defined in the Prompts/ directory, one file per
    // prompt. Each file is a Swift extension on PolishPipeline with a
    // single multiline string literal. Edit those files to tune prompt
    // behavior; run `make test` after changes.

    /// Select the system prompt based on the transcription language.
    ///
    /// Explicit English uses the detailed English prompt. Languages with a
    /// dedicated prompt use it; Auto/nil and all others fall back to the
    /// language-safe minimal prompt. Auto must not assume English because
    /// English filler and correction rules can delete words in other languages.
    public static func systemPrompt(forLanguage language: String?) -> String {
        if language == "en" {
            return systemPromptEnglish
        }
        switch language {
        case "hi": return systemPromptHindi
        case "kn": return systemPromptKannada
        case "ta": return systemPromptTamil
        default: return systemPromptMinimal
        }
    }

    // swiftlint:enable line_length

    // MARK: - Asterisk Grouping

    /// Collapse spaces inside asterisk groups.
    ///
    /// Finds runs that start and end with `*` (like `* really *` or
    /// `* * * *`) and removes all spaces within the run.
    /// "is * really * important" → "is *really* important"
    /// "password is * * * *" → "password is ****"
    private static func collapseAsteriskGroups(_ text: String) -> String {
        // Match: asterisk, then any mix of spaces/words/asterisks, ending
        // with an asterisk. The whole group's internal spaces collapse.
        guard let regex = try? NSRegularExpression(
            pattern: #"\*[\w* ]*\*"#) else { return text }
        var result = text
        let matches = regex.matches(
            in: result, range: NSRange(result.startIndex..., in: result))
        // Process from end to preserve indices.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let group = String(result[range])
            let collapsed = group.replacingOccurrences(of: " ", with: "")
            result.replaceSubrange(range, with: collapsed)
        }
        return result
    }

    // MARK: - Cloud Output Capitalization

    /// Match the first-letter casing of the cloud model output to the
    /// preprocessed input.
    ///
    /// If the preprocessed input started lowercase (continuation
    /// mid-sentence), force the output lowercase — the model sometimes
    /// capitalizes despite receiving lowercase input. If the input
    /// started uppercase and the model stripped a preamble leaving
    /// lowercase output, re-capitalize it.
    public static func matchInputCasing(
        _ text: String, preprocessedInput: String,
        casual: Bool
    ) -> String {
        guard !casual else { return text }
        guard let outputFirst = text.first, outputFirst.isLetter,
              let inputFirst = preprocessedInput.first, inputFirst.isLetter
        else { return text }

        if inputFirst.isLowercase && outputFirst.isUppercase {
            // Continuation: input was lowercase, force output lowercase.
            // But skip acronyms — if the first word is all-uppercase
            // (e.g. "AWS", "API"), don't lowercase it.
            let firstWord = text.prefix(while: { $0.isLetter })
            if firstWord.count > 1 && firstWord.allSatisfy({ $0.isUppercase }) {
                return text
            }
            return outputFirst.lowercased() + text.dropFirst()
        } else if inputFirst.isUppercase && outputFirst.isLowercase {
            // Preamble stripped: input was uppercase, re-capitalize.
            return outputFirst.uppercased() + text.dropFirst()
        }
        return text
    }

    /// Adjust the first character's casing to match the preprocessed
    /// input. If preprocessing lowercased the first word (mid-sentence
    /// continuation) but the model uppercased it back, restore
    /// lowercase — but only when the first word is the same in both.
    /// If there's no preceding text and the model lowercased, capitalize.
    public static func adjustFirstCharCasing(
        _ text: String, preprocessed: String, casual: Bool,
        noPreceding: Bool
    ) -> String {
        guard !casual,
              let outFirst = text.first, outFirst.isLetter,
              let inFirst = preprocessed.first, inFirst.isLetter
        else { return text }

        if noPreceding && outFirst.isLowercase {
            // No preceding text — capitalize.
            return outFirst.uppercased() + text.dropFirst()
        }

        if !noPreceding && inFirst.isLowercase && outFirst.isUppercase {
            // Preprocessing lowercased for mid-sentence continuation,
            // model uppercased it back. Restore only if same first word.
            let inWord = preprocessed.prefix(while: { $0.isLetter })
            let outWord = text.prefix(while: { $0.isLetter })
            // Never lowercase the pronoun "I", even mid-sentence.
            if inWord.lowercased() == outWord.lowercased(),
                outWord.lowercased() != "i" {
                return outFirst.lowercased() + text.dropFirst()
            }
        }

        if !noPreceding && inFirst.isUppercase && outFirst.isLowercase {
            // Preprocessing capitalized the first word (preceding ended at a
            // sentence boundary — e.g. this unit starts a new sentence across a
            // seam), but the model lowercased it. Restore only if same first word.
            let inWord = preprocessed.prefix(while: { $0.isLetter })
            let outWord = text.prefix(while: { $0.isLetter })
            if inWord.lowercased() == outWord.lowercased() {
                return outFirst.uppercased() + text.dropFirst()
            }
        }

        return text
    }

    // MARK: - Helpers

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    /// Capitalize the first letter matched by the second capture group
    /// in the given pattern.
    private static func capitalizeAfterPattern(
        _ text: String, pattern: String
    ) -> String {
        guard let regex = cachedRegex(pattern) else {
            return text
        }
        var result = text
        // Process matches in reverse order to preserve ranges.
        let matches = regex.matches(
            in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                let letterRange = Range(match.range(at: 2), in: result)
            else { continue }
            let upper = result[letterRange].uppercased()
            result.replaceSubrange(letterRange, with: upper)
        }
        return result
    }

    // MARK: - Trailing Filler Stripping

    /// Strip trailing standalone discourse fillers from the final
    /// polished output. Words like "Yeah.", "Right.", "Mm." as the
    /// last sentence are streaming ASR hallucinations or meaningless
    /// discourse closers. Only applied to the final assembled result,
    /// not during incremental polish, to avoid cache mismatches.
    public static func stripTrailingFiller(_ text: String) -> String {
        let fillers: Set<String> = [
            "yeah", "right", "mm", "mm-hmm", "mmm", "hmm",
            "sure", "okay", "ok", "yep", "nah", "mhm",
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match trailing word with optional period.
        guard let last = trimmed.split(separator: ".").last else {
            return text
        }
        let candidate = last.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if fillers.contains(candidate) {
            let stripped = String(trimmed.dropLast(last.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return text
    }

    // MARK: - Sentence Boundary Detection

    /// Whether the text ends with sentence-ending punctuation.
    ///
    /// Used by the chunk buffer to decide when accumulated raw
    /// transcripts form a complete unit worth polishing and injecting.
    /// Only checks the last non-whitespace character.
    public static func endsAtSentenceBoundary(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else {
            return false
        }
        return last == "." || last == "?" || last == "!"
    }

    /// Strip echoed preceding text from model output.
    ///
    /// The model sometimes echoes the preceding text at the start of
    /// its output instead of polishing only the new input. If the
    /// output begins with the preceding text, strip the echoed prefix
    /// and return the remainder.
    ///
    /// Only triggers when the preceding text is 15+ characters (short
    /// preceding text like "OK." is too likely to match coincidentally)
    /// and the remainder after stripping is non-empty.
    static func guardAgainstEcho(
        polished: String, precedingText: String?
    ) -> String {
        guard let preceding = precedingText,
              preceding.count >= 15
        else { return polished }

        let trimmed = preceding.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard polished.hasPrefix(trimmed) else { return polished }

        let remainder = String(polished.dropFirst(trimmed.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip leading punctuation left from the echo boundary.
            .drop(while: { $0 == "." || $0 == "," || $0 == ";" })
            .trimmingCharacters(in: .whitespaces)

        guard !remainder.isEmpty else { return polished }

        Log.debug(
            "[ECHO_GUARD] Stripped echoed preceding text"
            + " (\(trimmed.count) chars)")
        return String(remainder)
    }

    /// Strip a leading run of `polished` that re-emits the tail of the
    /// preceding context.
    ///
    /// The model is shown only the last ~80 characters of preceding context
    /// (see `buildPolishPrompt`). On long dictation it sometimes starts its
    /// output by repeating that last sentence or two — usually lightly
    /// reworded — before polishing the new unit. That duplicated prefix trips
    /// the duplication guard and forces a raw fallback, discarding the good
    /// polish underneath. `guardAgainstEcho` misses it because that only
    /// catches a verbatim echo of the *entire* preceding text.
    ///
    /// Detect it at the sentence level: drop each leading output sentence whose
    /// content words are almost entirely contained in one of the last two
    /// preceding sentences. Because the stripped content is already injected,
    /// removing it never loses information — so this is a safe recovery, not an
    /// edit. At least one sentence is always kept.
    static func stripBledPrefix(
        _ polished: String, precedingText: String?
    ) -> String {
        guard let preceding = precedingText, preceding.count >= 15
        else { return polished }
        let tailSets = sentenceStrings(preceding).suffix(2)
            .map { Set(contentWords($0)) }
            .filter { $0.count >= 4 }
        guard !tailSets.isEmpty else { return polished }

        let outSentences = sentenceStrings(polished)
        guard outSentences.count >= 2 else { return polished }

        var strip = 0
        while strip < outSentences.count - 1 {
            let set = Set(contentWords(outSentences[strip]))
            guard set.count >= 4 else { break }
            let duplicatesTail = tailSets.contains { tail in
                Double(set.intersection(tail).count) / Double(set.count) >= 0.8
            }
            if duplicatesTail { strip += 1 } else { break }
        }
        guard strip > 0 else { return polished }

        let remainder = dropLeadingSentences(polished, strip)
        guard !remainder.isEmpty else { return polished }
        Log.debug("[BLEED_GUARD] Stripped \(strip) bled sentence(s)")
        return remainder
    }

    /// Split text into sentence strings at `.`/`!`/`?` boundaries. Each piece
    /// keeps its terminator; trailing text without one is a final piece.
    private static func sentenceStrings(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" { flush() }
        }
        flush()
        return result
    }

    /// Return `text` with its first `n` sentences removed, using the same
    /// boundary rule as `sentenceStrings` so counts align.
    private static func dropLeadingSentences(_ text: String, _ n: Int) -> String {
        guard n > 0 else { return text }
        var count = 0
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            idx = text.index(after: idx)
            if ch == "." || ch == "!" || ch == "?" {
                count += 1
                if count == n { break }
            }
        }
        return String(text[idx...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check whether the model aggressively truncated input by
    /// misidentifying normal speech as a self-correction.
    ///
    /// Two triggers:
    /// - Output is less than 25% of input length (extreme truncation)
    /// - Output dropped 2+ sentences AND is less than 60% of input
    ///   length (moderate sentence dropping)
    ///
    /// Returns the preprocessed text as fallback, or nil if no
    /// truncation detected.
    public static func guardAgainstTruncation(
        polished: String, preprocessed: String
    ) -> String? {
        guard preprocessed.count >= 40 else { return nil }
        let ratio = Double(polished.count) / Double(preprocessed.count)

        // Extreme truncation: output is tiny compared to input.
        if ratio < 0.25 {
            Log.debug(
                "[TRUNCATION_GUARD] ratio=\(String(format: "%.0f", ratio * 100))%"
                + " polished=\(polished.count)chars"
                + " input=\(preprocessed.count)chars"
                + " — falling back to preprocessed")
            return preprocessed
        }

        // Sentence dropping: model removed whole sentences.
        let inputSentences = countSentences(preprocessed)
        let outputSentences = countSentences(polished)
        if inputSentences >= 3
            && outputSentences < inputSentences - 1
            && ratio < 0.6 {
            Log.debug(
                "[TRUNCATION_GUARD] sentences=\(inputSentences)→\(outputSentences)"
                + " ratio=\(String(format: "%.0f", ratio * 100))%"
                + " polished=\(polished.count)chars"
                + " input=\(preprocessed.count)chars"
                + " — falling back to preprocessed")
            return preprocessed
        }

        return nil
    }

    /// Detect when the model hallucinated unrelated text.
    ///
    /// Extract content words (3+ chars) from input and output. If they
    /// share fewer than 30% of input words, the model likely hallucinated
    /// and we fall back to the preprocessed input.
    static func guardAgainstHallucination(
        polished: String, preprocessed: String
    ) -> String? {
        // Length explosion: polished output should never be dramatically
        // longer than input. Polish adds punctuation and fixes casing but
        // does not add content. A 2x ratio is generous — legitimate
        // expansions (number words → digits don't grow, abbreviations
        // stay similar). Anything beyond that is the model incorporating
        // context or hallucinating.
        if preprocessed.count >= 20 && polished.count > preprocessed.count * 2 {
            Log.debug(
                "[HALLUCINATION_GUARD] length inflation"
                + " input=\(preprocessed.count)chars"
                + " output=\(polished.count)chars"
                + " — falling back to preprocessed")
            return preprocessed
        }
        if preprocessed.count < 20 && polished.count > preprocessed.count * 4 {
            Log.debug(
                "[HALLUCINATION_GUARD] length explosion"
                + " input=\(preprocessed.count)chars"
                + " output=\(polished.count)chars"
                + " — falling back to preprocessed")
            return preprocessed
        }

        return nil
    }

    /// Detect when polish dropped a contiguous run of spoken content.
    ///
    /// Align the input's ordered content words (letters only, 3+ characters,
    /// lowercased, excluding spelled-out numbers) against the output's via a
    /// longest common subsequence. The input words outside that subsequence are
    /// the dropped or reordered ones; a long contiguous run of them means a
    /// clause was summarized away, so fall back to the raw input. Matching a
    /// subsequence rather than set membership catches a drop even when the
    /// missing words reappear out of order elsewhere in the output. Scattered
    /// gaps from filler removal, number normalization, or dedup stay short and
    /// pass.
    ///
    /// Returns the preprocessed text as fallback, or nil if no dropped run.
    static func guardAgainstContentLoss(
        polished: String, preprocessed: String,
        maxConsecutiveMissing: Int = 3
    ) -> String? {
        let inputWords = contentWords(preprocessed)
        let matched = orderedMatchMask(inputWords, contentWords(polished))
        var longestMissingRun = 0
        var currentRun = 0
        for isMatched in matched {
            if isMatched {
                currentRun = 0
            } else {
                currentRun += 1
                longestMissingRun = max(longestMissingRun, currentRun)
            }
        }
        if longestMissingRun > maxConsecutiveMissing {
            Log.debug(
                "[CONTENT_GUARD] dropped run=\(longestMissingRun)"
                + " — falling back to preprocessed")
            return preprocessed
        }
        return nil
    }

    /// Detect when polish invented content not present in the input.
    ///
    /// The mirror of `guardAgainstContentLoss`: content words in the polished
    /// output but not in the input mean the model fabricated text, often by
    /// completing a dangling fragment. More than a few such words is a
    /// fabrication, so fall back to the raw input. Number and casing
    /// normalization introduce no new content words.
    ///
    /// Returns the preprocessed text as fallback, or nil if no fabrication.
    static func guardAgainstFabrication(
        polished: String, preprocessed: String,
        maximumNovelWords: Int = 3,
        maximumNovelRun: Int = 1
    ) -> String? {
        // Drop function words so a preposition swap ("waiting on" -> "waiting
        // for") is not counted as inserted content, and so a novel pair split
        // by one ("tightened OUR brakes") reads as adjacent.
        let inputContent = contentWords(preprocessed)
            .filter { !functionWords.contains($0) }
        let outputContent = contentWords(polished)
            .filter { !functionWords.contains($0) }
        let inputWords = Set(inputContent)
        let novel = Set(outputContent).subtracting(inputWords)
        // Longest contiguous run of novel content words, in output order. A
        // legitimate single-word repair ("scenarios" -> "scanners") is a lone
        // novel word between input anchors (run 1); an invented phrase ("a good
        // idea", "tightened our brakes") is a run of 2+ the count misses.
        var longestRun = 0
        var run = 0
        for word in outputContent {
            if inputWords.contains(word) {
                run = 0
            } else {
                run += 1
                longestRun = max(longestRun, run)
            }
        }
        // A novel word inserted without a matching input word dropped is an
        // addition (content count grows), not a substitution ("green" inserted
        // vs "scenarios" -> "scanners" which keeps the count flat).
        let netInserted = outputContent.count - inputContent.count
        if novel.count > maximumNovelWords
            || longestRun > maximumNovelRun
            || (!novel.isEmpty && netInserted >= 1)
        {
            Log.debug(
                "[FABRICATION_GUARD] novel=\(novel.count) run=\(longestRun)"
                + " inserted=\(netInserted) — falling back to preprocessed"
                + " | novel=\(novel.sorted())"
                + " | polished=\"\(polished)\""
                + " | preprocessed=\"\(preprocessed)\"")
            return preprocessed
        }
        return nil
    }

    /// Common function words the fabrication run treats as transparent — they
    /// pass the `contentWords` length filter but carry no content, so a novel
    /// word on either side is still adjacent for run purposes.
    private static let functionWords: Set<String> = [
        "the", "and", "for", "but", "nor", "yet", "our", "your", "his", "her",
        "hers", "its", "their", "they", "them", "you", "she", "him", "was",
        "were", "are", "has", "have", "had", "been", "being", "will", "with",
        "that", "this", "these", "those", "not", "any", "all", "who", "whom",
        "from", "into", "than", "then", "would", "could", "should", "can",
    ]

    /// Detect when polish duplicated content the input states once — a phrase
    /// repeated across a seam or a segmentation boundary (e.g. "we're two weeks
    /// out" emitted for two different areas). The fabrication guard misses this
    /// because the repeated words are already in the input, so they are not
    /// novel. Counts, per content word present in the input, how many extra
    /// times it appears in the output; a repeated phrase shows as excess on two
    /// or more words. Number normalization is excluded (contentWords drops
    /// number words). Returns the preprocessed text as fallback, or nil.
    static func guardAgainstDuplication(
        polished: String, preprocessed: String,
        maximumExcess: Int = 1
    ) -> String? {
        var inputCounts: [String: Int] = [:]
        for word in contentWords(preprocessed) {
            inputCounts[word, default: 0] += 1
        }
        var outputCounts: [String: Int] = [:]
        for word in contentWords(polished) {
            outputCounts[word, default: 0] += 1
        }
        var excess = 0
        for (word, outputCount) in outputCounts {
            // Only words the input actually contains — novel words are the
            // fabrication guard's job, not duplication.
            if let inputCount = inputCounts[word], inputCount >= 1 {
                excess += max(0, outputCount - inputCount)
            }
        }
        if excess > maximumExcess {
            Log.debug(
                "[DUPLICATION_GUARD] excess=\(excess)"
                + " — falling back to preprocessed"
                + " | polished=\"\(polished)\""
                + " | preprocessed=\"\(preprocessed)\"")
            return preprocessed
        }
        return nil
    }

    /// Detect when polish substituted or duplicated a dictated number — the
    /// costliest faithfulness failure, and one the content-word guards ignore
    /// because they exclude numbers. Compares the multiset of numeric values in
    /// the input and output, counting a spelled cardinal ("twelve") and its
    /// digits ("12") as the same value, and fires only on the unambiguous
    /// signature of a substitution: a value present in the input is dropped
    /// while another is invented or duplicated in the output. Abstains on
    /// time/year/sequence forms a simple parser cannot verify.
    ///
    /// Returns the preprocessed text as fallback, or nil if numbers are faithful.
    static func guardAgainstNumberChange(
        polished: String, preprocessed: String
    ) -> String? {
        let input = numericValues(preprocessed)
        let output = numericValues(polished)
        // Abstain when either side holds a time, year, or sequence form a simple
        // additive parser cannot verify, rather than risk a false alarm on a
        // number that already renders correctly.
        guard !input.ambiguous, !output.ambiguous else { return nil }
        let dropped = multisetDifference(input.values, output.values)
        let invented = multisetDifference(output.values, input.values)
        // A faithful rewrite keeps the same values; a substitution both drops a
        // dictated value and invents or duplicates another.
        if !dropped.isEmpty, !invented.isEmpty {
            Log.debug(
                "[NUMBER_GUARD] dropped=\(dropped.count) "
                + "invented=\(invented.count) — falling back to preprocessed")
            return preprocessed
        }
        return nil
    }

    /// Extract the multiset of numeric values a text mentions, mapping a spelled
    /// cardinal or ordinal to its value and a digit run to its integer, so
    /// "twelve" and "12" compare equal. `ambiguous` is true when a spelled run
    /// reads as a time, year, or sequence — ascending number words like "three
    /// thirty" or "nineteen eighty four" — that additive parsing cannot verify.
    private static func numericValues(_ text: String)
        -> (values: [Int], ambiguous: Bool)
    {
        // Join digits split by a thousands separator ("1,200" -> "1200").
        let joined = text.replacingOccurrences(
            of: #"(?<=\d),(?=\d)"#, with: "", options: .regularExpression)
        let tokens = joined.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        var values: [Int] = []
        var ambiguous = false
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if let first = token.first, first.isNumber {
                // Digit-led token: take the leading integer ("15th" -> 15).
                if let value = Int(token.prefix { $0.isNumber }) {
                    values.append(value)
                }
                i += 1
            } else if isNumberWord(token) {
                var run: [String] = []
                while i < tokens.count {
                    let word = tokens[i]
                    if isNumberWord(word) {
                        run.append(word)
                        i += 1
                    } else if word == "and", !run.isEmpty,
                        i + 1 < tokens.count, isNumberWord(tokens[i + 1])
                    {
                        i += 1  // "two hundred and fifty" keeps "and" in the run
                    } else {
                        break
                    }
                }
                let parsed = parseNumberRun(run)
                if parsed.ambiguous {
                    ambiguous = true
                } else {
                    values.append(parsed.value)
                }
            } else {
                i += 1
            }
        }
        return (values, ambiguous)
    }

    private static func isNumberWord(_ word: String) -> Bool {
        numberWordValues[word] != nil || numberScaleValues[word] != nil
            || ordinalWordValues[word] != nil
    }

    /// Compose a run of spelled number words into a value the standard way —
    /// tens plus units, scaled by hundred/thousand. Flags the run ambiguous when
    /// its terminal words ascend in magnitude, the mark of a spoken time or year
    /// ("three thirty", "nineteen eighty four") rather than a plain cardinal.
    private static func parseNumberRun(_ run: [String])
        -> (value: Int, ambiguous: Bool)
    {
        var total = 0
        var current = 0
        var previousTerminal: Int?
        var ascending = false
        for word in run {
            if let scale = numberScaleValues[word] {
                if scale >= 1000 {
                    total += (current == 0 ? 1 : current) * scale
                    current = 0
                } else {
                    current = (current == 0 ? 1 : current) * scale
                }
                previousTerminal = nil
            } else if let value = numberWordValues[word]
                ?? ordinalWordValues[word]
            {
                if let previous = previousTerminal, value >= previous {
                    ascending = true
                }
                previousTerminal = value
                current += value
            }
        }
        return (total + current, ascending && run.count > 1)
    }

    /// Elements of `a` beyond what `b` supplies, counting multiplicity.
    private static func multisetDifference(_ a: [Int], _ b: [Int]) -> [Int] {
        var counts: [Int: Int] = [:]
        for value in b { counts[value, default: 0] += 1 }
        var result: [Int] = []
        for value in a {
            if let remaining = counts[value], remaining > 0 {
                counts[value] = remaining - 1
            } else {
                result.append(value)
            }
        }
        return result
    }

    /// Mark which of `a`'s elements participate in a longest common subsequence
    /// with `b`. A dropped or reordered clause then shows up as a contiguous run
    /// of unmarked words, even when individual words reappear elsewhere in `b`.
    private static func orderedMatchMask(
        _ a: [String], _ b: [String]
    ) -> [Bool] {
        let n = a.count
        let m = b.count
        if n == 0 { return [] }
        if m == 0 { return Array(repeating: false, count: n) }
        // dp[i][j] = LCS length of a[i...] and b[j...].
        var dp = Array(
            repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j]
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var mask = Array(repeating: false, count: n)
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                mask[i] = true
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return mask
    }

    /// Spelled-out numbers are excluded from content-word coverage because
    /// faithful polish rewrites them as digits ("forty" becomes "40").
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "billion",
    ]

    /// Spelled cardinals mapped to their value for the number-faithfulness
    /// guard (distinct from `numberWords`, which only needs the word set).
    private static let numberWordValues: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let numberScaleValues: [String: Int] = [
        "hundred": 100, "thousand": 1000, "million": 1_000_000,
        "billion": 1_000_000_000,
    ]

    private static let ordinalWordValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40,
        "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80,
        "ninetieth": 90,
    ]

    /// Extract lowercased letter-only words of 3+ characters, excluding
    /// spelled-out numbers.
    private static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count >= 3 && !numberWords.contains($0) }
    }

    /// Send preprocessed text through the model, dropping the preceding
    /// context for a long, mostly-unpunctuated run — with that context
    /// the model summarizes such a run and drops content, without it the
    /// content is preserved. Returns the raw model output, before the
    /// echo/hallucination/truncation guards.
    private static func polishThroughModel(
        _ stripped: String, chatClient: any PolishChatClient, model: String,
        tone: String?, precedingText: String?, temperature: Double = 0
    ) async throws -> String {
        // A long, mostly-unpunctuated run makes the model summarize and
        // drop content — but only when it also has preceding context.
        // Drop the preceding for such input so it preserves what the user
        // said. Short input keeps its context for casing continuity.
        let wordCount = stripped.split(separator: " ").count
        let longRun = wordCount > 30 && countSentences(stripped) <= 1
        let prompt = buildPolishPrompt(
            tone: tone, precedingText: longRun ? nil : precedingText)
        return try await chatClient.complete(
            model: model, systemPrompt: prompt, userPrompt: stripped,
            temperature: temperature)
    }

    /// Build the model system prompt with optional style and preceding
    /// context lines.
    private static func buildPolishPrompt(
        tone: String?, precedingText: String?
    ) -> String {
        var prompt = systemPromptQwen
        if let tone {
            prompt += "\nStyle: \(tone)"
        }
        if let preceding = precedingText, !preceding.isEmpty {
            let suffix = preceding.count > 80
                ? String(preceding.suffix(80)) : preceding
            prompt += "\nPreceding text: \(suffix)"
            Log.debug(
                "[PolishPipeline] preceding context (\(suffix.count) chars)")
        }
        return prompt
    }

    /// Count sentence-ending punctuation marks in text.
    private static func countSentences(_ text: String) -> Int {
        var count = 0
        var prev: Character = " "
        for char in text {
            if (char == "." || char == "!" || char == "?") && prev != "." && prev != "!" && prev != "?" {
                count += 1
            }
            prev = char
        }
        return count
    }
}
