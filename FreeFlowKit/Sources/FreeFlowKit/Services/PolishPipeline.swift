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

        init(_ pattern: String, _ replacement: String, protect: Bool = false) {
            // swiftlint:disable:next force_try
            self.pattern = try! NSRegularExpression(
                pattern: pattern, options: .caseInsensitive)
            self.replacement = replacement
            self.protect = protect
        }
    }

    // Order matters: "new paragraph" must come before "period" to avoid
    // partial matches.
    private static let punctuationRules: [PunctuationRule] = [
        // Paragraph and line breaks.
        PunctuationRule(#"\bnew paragraph\b"#, "[PAR]", protect: true),
        PunctuationRule(#"\bnew line\b"#, "[NL]", protect: true),
        PunctuationRule(#"\bnewline\b"#, "[NL]", protect: true),
        // "period" and "full stop" are handled by the model, not
        // deterministically — they collide with nouns ("billing period",
        // "came to a full stop").
        PunctuationRule(#"\bquestion mark\b"#, "?"),
        PunctuationRule(#"\bexclamation point\b"#, "!"),
        PunctuationRule(#"\bexclamation mark\b"#, "!"),
        // Inline punctuation.
        PunctuationRule(#"\bcomma\b"#, ","),
        PunctuationRule(#"\bcolon\b"#, ":"),
        PunctuationRule(#"\bsemicolon\b"#, ";"),
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
                output += replacement
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

        return result
    }

    // MARK: - Number Word Conversion

    private static let tens: [(String, Int)] = [
        ("twenty", 20), ("thirty", 30), ("forty", 40),
        ("fifty", 50), ("sixty", 60), ("seventy", 70),
        ("eighty", 80), ("ninety", 90),
    ]

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
        let isCasual = toneLabel(for: context.bundleID) == "casual"
        var prompt = isCasual
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
            // Capitalize first letter after paragraph/line breaks.
            result = capitalizeAfterPattern(result, pattern: "(\\n)(\\w)")
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

    /// postprocess. This is the single source of truth for how raw
    /// dictated text becomes polished output. Used by both the
    /// streaming provider and the eval test suite.
    public static func polish(
        _ raw: String,
        chatClient: (any PolishChatClient)?,
        model: String = polishModel,
        tone: String? = nil,
        precedingText: String? = nil,
        breakMode: BreakMode = .expandBeforeModel
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
                casual: casual, stripModelBreaks: false)
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
            return await polishUnit(
                substituted: segments[0].text, chatClient: chatClient,
                model: model, tone: tone, precedingText: precedingText,
                casual: casual, stripModelBreaks: true)
        }

        var result = ""
        // Only the first segment inherits the caller's preceding text.
        // Every later segment begins a fresh line or paragraph, so it
        // polishes without preceding context — which also capitalizes its
        // first character as a paragraph start.
        var preceding = precedingText
        for segment in segments {
            // Trim the segment so its first character is the real word:
            // a leading space left by the split would otherwise defeat the
            // paragraph-start capitalization.
            let text = segment.text.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let block = await polishUnit(
                    substituted: text, chatClient: chatClient,
                    model: model, tone: tone, precedingText: preceding,
                    casual: casual, stripModelBreaks: true)
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
    private static func polishUnit(
        substituted: String,
        chatClient: (any PolishChatClient)?,
        model: String,
        tone: String?,
        precedingText: String?,
        casual: Bool,
        stripModelBreaks: Bool
    ) async -> String {
        let stripped = stripKeepTags(
            substituted, casual: casual, expandBreaks: !stripModelBreaks)

        guard let chatClient else {
            return normalizeFormatting(stripped, casual: casual)
        }

        let noPreceding = precedingText == nil || precedingText!.isEmpty

        do {
            let polished = try await polishThroughModel(
                stripped, chatClient: chatClient, model: model,
                tone: tone, precedingText: precedingText)
            if polished.isEmpty {
                return normalizeFormatting(stripped, casual: casual)
            }
            var cleaned = guardAgainstEcho(
                polished: polished, precedingText: precedingText)
            if stripModelBreaks {
                cleaned = stripModelNewlines(cleaned)
            }
            if stripped.contains("\u{2026}") {
                cleaned = cleaned.replacingOccurrences(
                    of: "...", with: "\u{2026}")
            }
            if let fallback = guardAgainstHallucination(
                polished: cleaned, preprocessed: stripped) {
                return adjustFirstCharCasing(
                    normalizeFormatting(fallback, casual: casual),
                    preprocessed: stripped, casual: casual,
                    noPreceding: noPreceding)
            }
            if let fallback = guardAgainstTruncation(
                polished: cleaned, preprocessed: stripped) {
                return adjustFirstCharCasing(
                    normalizeFormatting(fallback, casual: casual),
                    preprocessed: stripped, casual: casual,
                    noPreceding: noPreceding)
            }
            return adjustFirstCharCasing(
                normalizeFormatting(cleaned, casual: casual),
                preprocessed: stripped, casual: casual,
                noPreceding: noPreceding)
        } catch {
            Log.debug("[PolishPipeline] Polish failed: \(error)")
            return normalizeFormatting(stripped, casual: casual)
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

    // MARK: - Local System Prompt

    /// Build a dynamic system prompt for the fine-tuned Qwen model.
    ///
    /// Starts with the base `systemPromptQwen` and appends optional
    /// context lines. The model was trained with these lines present
    /// or absent, so it adapts its behavior accordingly.
    ///
    /// - Parameters:
    ///   - context: App context for tone detection and preceding text.
    /// - Returns: The system prompt string.
    public static func buildQwenSystemPrompt(
        context: AppContext
    ) -> String {
        var prompt = systemPromptQwen

        if let tone = toneLabel(for: context.bundleID) {
            prompt += "\nStyle: \(tone)"
        }

        if let content = context.focusedFieldContent,
           !content.isEmpty
        {
            // Take the last ~80 characters as preceding text context.
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
    /// English (or nil) uses the detailed English prompt. Languages with
    /// a dedicated prompt use it; all others fall back to the minimal
    /// language-agnostic prompt.
    public static func systemPrompt(forLanguage language: String?) -> String {
        guard let language, !language.isEmpty, language != "en" else {
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
            if inWord.lowercased() == outWord.lowercased() {
                return outFirst.lowercased() + text.dropFirst()
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
    /// last sentence are Parakeet hallucinations or meaningless
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
            + " (\(trimmed.count) chars)"
            + " | remainder=\"\(remainder.prefix(80))\"")
        return String(remainder)
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
                + " — falling back to preprocessed"
                + " | polished=\"\(polished)\""
                + " | preprocessed=\"\(preprocessed)\"")
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
                + " — falling back to preprocessed"
                + " | polished=\"\(polished)\""
                + " | preprocessed=\"\(preprocessed)\"")
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
                + " — falling back to preprocessed"
                + " | polished=\"\(polished.prefix(200))\""
                + " | preprocessed=\"\(preprocessed)\"")
            return preprocessed
        }
        if preprocessed.count < 20 && polished.count > preprocessed.count * 4 {
            Log.debug(
                "[HALLUCINATION_GUARD] length explosion"
                + " input=\(preprocessed.count)chars"
                + " output=\(polished.count)chars"
                + " — falling back to preprocessed"
                + " | polished=\"\(polished)\""
                + " | preprocessed=\"\(preprocessed)\"")
            return preprocessed
        }

        return nil
    }

    /// Send preprocessed text through the model, dropping the preceding
    /// context for a long, mostly-unpunctuated run — with that context
    /// the model summarizes such a run and drops content, without it the
    /// content is preserved. Returns the raw model output, before the
    /// echo/hallucination/truncation guards.
    private static func polishThroughModel(
        _ stripped: String, chatClient: any PolishChatClient, model: String,
        tone: String?, precedingText: String?
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
            model: model, systemPrompt: prompt, userPrompt: stripped)
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
            Log.debug("[PolishPipeline] preceding: \"\(suffix)\"")
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
