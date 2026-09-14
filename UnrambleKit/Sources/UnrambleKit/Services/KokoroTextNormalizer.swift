import Foundation

/// Prepare a speech script for Kokoro's phonemizer.
///
/// The phonemizer only reads plain words and basic punctuation. Numbers
/// its own expansion misreads, mixed identifiers, keyboard glyphs,
/// hyphenated compounds, markdown leftovers, arrows, and emoji either
/// garble through the out-of-vocabulary network or silently drop. The
/// normalizer turns what has a spoken reading into words and removes
/// the rest.
enum KokoroTextNormalizer {

    /// Symbols with a conventional spoken reading. Keyboard modifiers
    /// matter most: shortcut hints are common in the app's own guidance
    /// and in agent output.
    private static let spokenSymbols: [(String, String)] = [
        ("’", "'"),
        ("‘", "'"),
        ("“", "\""),
        ("”", "\""),
        ("⌃", " control "),
        ("⌥", " option "),
        ("⌘", " command "),
        ("⇧", " shift "),
        ("⎋", " escape "),
        ("⏎", " return "),
        ("×", " times "),
        ("→", " to "),
        ("…", "..."),
        ("•", ", "),
        ("%", " percent "),
    ]

    /// Punctuation the phonemizer reads or phrases around; anything
    /// outside letters, numbers, whitespace, and this set is dropped.
    private static let keptPunctuation = Set(".,;:!?'\"()%-/$&@+#=")

    /// Words the packed lexicon mispronounces, with the phonemes to use
    /// instead. The phonemizer accepts inline overrides in Misaki's
    /// `[word](/phonemes/)` form, so these survive as exact
    /// pronunciations.
    private static let pronunciationOverrides: [(String, String)] = [
        ("written", "ɹˈɪtᵊn"),
        ("Mrinal", "mɹinˈɑl"),
        ("Wadhwa", "wˈɑdwɑ"),
    ]

    /// Compounds the lexicon lacks that read fine as their plain words.
    private static let respellings: [(String, String)] = [
        ("realtime", "real time")
    ]

    static func normalize(_ text: String) -> String {
        var result = text
        // A long URL reads as garble; its host is the part worth hearing.
        result = replaceMatches(
            of: #"https?://[^\s]+"#, in: result
        ) { match in
            var host = match
            for scheme in ["https://", "http://"] {
                if host.hasPrefix(scheme) {
                    host = String(host.dropFirst(scheme.count))
                }
            }
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            host = String(host.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
            return host.replacingOccurrences(of: ".", with: " dot ")
        }
        // Keep currency amounts together before the generic number rules
        // split decimals and detach magnitude suffixes from their digits.
        result = expandNumericRanges(in: result)
        result = expandCurrencyAmounts(in: result)
        result = expandThousandCounts(in: result)
        result = expandFractions(in: result)
        result = result.replacingOccurrences(
            of: #"\bMicrosoft\h+365(?![\p{L}\p{N}_])"#,
            with: "Microsoft three sixty five", options: .regularExpression)
        // A times sign or letter x between two numbers is a dimension
        // ("1920×1080", "1920x1080" read "by"); this must run before the
        // symbol map reads every remaining × as "times". Hex literals
        // ("0x1F") keep their x via the leading-zero guard.
        result = result.replacingOccurrences(
            of: #"(?<=\d)(?<!\b0)\s*[xX×]\s*(?=\d)"#,
            with: " by ",
            options: .regularExpression)
        for (symbol, replacement) in spokenSymbols {
            result = result.replacingOccurrences(of: symbol, with: replacement)
        }
        result = expandDecadesOrSeconds(in: result)
        // Only restore this approved masked spelling, not arbitrary words
        // containing an asterisk or other masked profanity.
        result = result.replacingOccurrences(
            of: #"(?i)(?<![\p{L}\p{N}_])sh\*t(?![\p{L}\p{N}_])"#,
            with: "shit", options: .regularExpression)
        // Hex literals spell per character before the number rules can
        // tear them apart.
        result = replaceMatches(
            of: #"(?<![\p{L}\d])0[xX][0-9A-Fa-f]+(?![\p{L}\d])"#, in: result
        ) { match in
            match.map { character in
                character.isNumber
                    ? EnglishNumberSpeller.spellDigits(String(character))
                    : String(character)
            }.joined(separator: " ")
        }
        result = spellIdentifiers(in: result)
        // A letter x glued to the end of a number is a multiplier
        // ("1.2x", "35x") whatever follows it, as long as it does not
        // start another word.
        result = result.replacingOccurrences(
            of: #"(?<=\d)[xX](?![\p{L}\p{N}])"#,
            with: " times",
            options: .regularExpression)
        // Fractional digits retain their precision, including leading zeroes.
        result = replaceMatchesWithRange(
            of: #"(?<![\p{L}\p{N}_.])(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)?(?:\.[0-9]+)+"#,
            in: result
        ) { number, range in
            let followedByUnit = range.upperBound < result.endIndex && result[range.upperBound].isLetter
            return spokenDecimal(number) + (followedByUnit ? " " : "")
        }
        result = result.replacingOccurrences(
            of: #"\s*[—–]\s*"#,
            with: ", ",
            options: .regularExpression)
        // Hyphenated compounds miss the lexicon and garble; their plain
        // words do not.
        result = result.replacingOccurrences(
            of: #"(?<=[\p{L}\p{N}])-(?=[\p{L}\p{N}])"#,
            with: " ",
            options: .regularExpression)
        result = spellOrdinals(in: result)
        // Letters glued to a number ("24kHz") read as one unknown token;
        // split so the number and the letters each get a reading.
        result = result.replacingOccurrences(
            of: #"(?<=\d)(?=\p{L})"#,
            with: " ",
            options: .regularExpression)
        result = spellNumbers(in: result)
        result = String(
            result.map { character in
                if character.isLetter || character.isNumber
                    || character.isWhitespace
                {
                    return character
                }
                return keptPunctuation.contains(character) ? character : " "
            })
        result = result.replacingOccurrences(
            of: #" {2,}"#,
            with: " ",
            options: .regularExpression)
        // Replacements can leave a space before closing punctuation
        // ("times ."); rejoin so phrasing stays natural.
        result = result.replacingOccurrences(
            of: #" +([.,;:!?])"#,
            with: "$1",
            options: .regularExpression)
        for (word, replacement) in respellings {
            result = result.replacingOccurrences(
                of: #"(?i)\b"# + NSRegularExpression.escapedPattern(for: word)
                    + #"\b"#,
                with: replacement,
                options: .regularExpression)
        }
        // "read" is a heteronym the phonemizer always reads as present
        // tense; after an auxiliary that forces the past participle, pin
        // the past-tense sound. Ambiguous contexts keep the default.
        result = result.replacingOccurrences(
            of: #"(?i)\b(was|were|been|being|had|have|has|having|[\p{L}]+'ve) +read\b"#,
            with: "$1 [read](/ɹˈɛd/)",
            options: .regularExpression)
        // Pronunciation overrides go last: their bracket syntax must
        // reach the phonemizer intact, and the filter above would strip
        // it.
        for (word, phonemes) in pronunciationOverrides {
            result = result.replacingOccurrences(
                of: #"(?i)\b"# + NSRegularExpression.escapedPattern(for: word)
                    + #"\b"#,
                with: "[\(word)](/\(phonemes)/)",
                options: .regularExpression)
        }
        result = expandTechnologyInitialism(in: result)
        result = result.replacingOccurrences(
            of: #"(?<![\p{L}\p{N}_])FP\h*&\h*A(?![\p{L}\p{N}_])"#,
            with: "eff pee and [A](/ˈA/)", options: .regularExpression)
        // The voice engine otherwise discards ampersands as punctuation.
        result = result.replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Numbers

    /// Read decade-shaped tokens from nearby wording. Without a timing cue,
    /// prose defaults to the decade reading; a bare "90s" remains ambiguous.
    private static func expandDecadesOrSeconds(in text: String) -> String {
        let decadeNames = [
            10: "tens", 20: "twenties", 30: "thirties", 40: "forties", 50: "fifties",
            60: "sixties", 70: "seventies", 80: "eighties", 90: "nineties",
        ]
        return replaceMatchesWithRange(
            of: #"(?<![\p{L}\p{N}_.$])'?(?:[12][0-9][0-9]0|[1-9]0)s(?![\p{L}\p{N}_])"#,
            in: text
        ) { token, range in
            let digits = token.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard let value = Int(digits) else { return token }
            // Use the original text for every occurrence: expanding an earlier
            // token must not change how a later one is interpreted.
            let before = localTimingContext(String(text[..<range.lowerBound].suffix(120)))
            let after = localTimingContext(String(text[range.upperBound...].prefix(120)))
            let attributive = containsPattern(
                #"^\h*(?:-\h*)?(?:timeouts?|delays?|pauses?|intervals?|durations?|countdowns?|timers?|waits?|latenc(?:y|ies)|rests?)\b"#,
                in: after)
            let timingVerb = containsPattern(
                #"\b(?:wait(?:ed|ing)?(?:\h+for)?|lasts|lasted|lasting|takes|took)(?:\h+(?:about|approximately|exactly|another|only|up\h+to|at\h+(?:least|most)))?\h*$"#,
                in: before)
            let timingLabel = containsPattern(
                #"\b(?:timeout|delay|duration|interval|countdown|timer|latency)(?:\h*[:=]|\h+(?:is|was|of))\h*$"#,
                in: before)
            let timingAfter = containsPattern(
                #"^\h+(?:later|earlier|ago|remaining|elapsed|long|apart)\b"#, in: after)
            let decadeAfter = containsPattern(
                #"^\h+(?:music|songs?|hits?|fashion|nostalgia|culture|movies?|films?|kids?|rock|pop|style|sitcoms?|history|era|decade)\b"#,
                in: after)
            let timingPreposition = containsPattern(
                #"\b(?:for|within|after|every|in)(?:\h+(?:about|approximately|exactly|another|only|up\h+to|at\h+(?:least|most)))?\h*$"#,
                in: before)
            if attributive || timingLabel || timingAfter || (timingVerb && !decadeAfter)
                || (timingPreposition && !decadeAfter && !token.hasPrefix("'"))
            {
                return EnglishNumberSpeller.cardinal(value)
                    + (attributive ? " second" : " seconds")
            }
            if let decade = decadeNames[value % 100] {
                return value < 100
                    ? decade
                    : EnglishNumberSpeller.cardinal(value / 100) + " " + decade
            }
            return value == 2000
                ? "two thousands"
                : EnglishNumberSpeller.cardinal(value / 100) + " hundreds"
        }
    }

    /// Soft line wraps can connect a cue to its number, but blank lines cannot.
    /// These replacements affect context matching only, never the speech script.
    private static func localTimingContext(_ text: String) -> String {
        text.replacingOccurrences(of: #"\r\n?"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n\h*\n"#, with: "|", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func containsPattern(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Expand financial shorthand only when a currency sign identifies it as
    /// money. Bare units and identifiers such as 24kHz or 1TB stay unchanged.
    private static func expandCurrencyAmounts(in text: String) -> String {
        let scales = ["k": "thousand", "m": "million", "b": "billion", "t": "trillion"]
        return replaceMatches(
            of: #"(?<![\p{L}\p{N}_$£])[$£]\h*(?:(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?|\.[0-9]+)\h*[kKmMbBtT](?![\p{L}\p{N}_])"#,
            in: text
        ) { match in
            guard let suffix = match.last, let scale = scales[suffix.lowercased()] else {
                return match
            }
            let amount = match.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: "")
            // Money is a count, never a year (e.g. $2025M). Preserve decimal
            // precision by reading fractional digits individually.
            let currency = match.first == "£" ? "pounds" : "dollars"
            return "\(spokenDecimal(amount)) \(scale) \(currency)"
        }
    }

    /// Lowercase k is a count suffix. Uppercase K can mean Kelvin or a
    /// display resolution, so leave it to the existing unit handling.
    private static func expandThousandCounts(in text: String) -> String {
        replaceMatches(
            of: #"(?<![\p{L}\p{N}_.,$£])(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?k(?![\p{L}\p{N}_])"#,
            in: text
        ) { spokenDecimal(String($0.dropLast())) + " thousand" }
    }

    private static func spokenDecimal(_ number: String) -> String {
        let parts = number.replacingOccurrences(of: ",", with: "")
            .split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        let spoken: String
        if let value = Int(whole), value <= 999_999 {
            spoken = EnglishNumberSpeller.cardinal(value)
        } else {
            spoken = EnglishNumberSpeller.spellDigits(whole)
        }
        return spoken + parts.dropFirst().map {
            " point " + EnglishNumberSpeller.spellDigits(String($0))
        }.joined()
    }

    /// Only a pair of complete numbers is a range. Adjacent separators
    /// exclude dates, phone numbers, versions, and compound identifiers.
    private static func expandNumericRanges(in text: String) -> String {
        let number = #"(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?k?"#
        return replaceMatches(
            of: #"(?<![\p{L}\p{N}_./:$£–-])"# + number + #"\h*[-–]\h*"# + number
                + #"(?![\p{L}\p{N}_/:–-]|[.,][0-9])"#,
            in: text
        ) { $0.replacingOccurrences(of: #"\h*[-–]\h*"#, with: " to ", options: .regularExpression) }
    }

    /// Standalone slash fractions use denominator names; a date cue or an
    /// adjacent slash keeps date-like text out of this rule.
    private static func expandFractions(in text: String) -> String {
        replaceMatchesWithRange(
            of: #"(?<![\p{L}\p{N}_./:–—-])(?:[0-9]+\h+)?[0-9]+/[0-9]+(?![\p{L}\p{N}_/:–—-]|\.[0-9])"#,
            in: text
        ) { token, range in
            let before = String(text[..<range.lowerBound].suffix(80))
            let after = String(text[range.upperBound...].prefix(80))
            guard !containsPattern(#"\b(?:on|dated|date|since|until|through|by)(?:\h*[:=])?\h*$"#, in: before)
                && !containsPattern(#"[0-9]+/[0-9]+\h*[-–—]\h*$"#, in: before)
                && !containsPattern(#"^\h*[-–—]\h*[0-9]+/[0-9]+"#, in: after)
            else { return token }
            let pieces = token.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).map(String.init)
            guard let numerator = Int(pieces[pieces.count - 2]), numerator <= 999_999,
                let denominator = Int(pieces.last!), (2...999_999).contains(denominator)
            else { return token }
            let singular = denominator == 2 ? "half"
                : denominator == 4 ? "quarter" : EnglishNumberSpeller.ordinal(denominator)
            let denominatorName = numerator == 1 ? singular
                : denominator == 2 ? "halves" : singular + "s"
            let fraction = EnglishNumberSpeller.cardinal(numerator) + " " + denominatorName
            return pieces.count == 3 ? spokenDecimal(pieces[0]) + " and " + fraction : fraction
        }
    }

    /// The lexicon mistakes uppercase IT for a pronoun even in technology
    /// prose. Require a nearby technology noun, or a preposition in a
    /// technology paragraph; capitalization alone is not enough.
    private static func expandTechnologyInitialism(in text: String) -> String {
        replaceMatchesWithRange(of: #"\bIT\b"#, in: text) { token, range in
            let before = String(text[..<range.lowerBound].suffix(80))
            let after = String(text[range.upperBound...].prefix(80))
            let nounAfter = containsPattern(
                #"^\h+(?:specialists?|teams?|departments?|support|services|systems?|staff|budgets?|spending|operations|infrastructure|security|management|and\h+Ops)\b"#,
                in: after)
            let prepositionBefore = containsPattern(
                #"\b(?:in|from|about|with|for|of|to|by)(?:\h+(?:just|the|our|your|their))?\h*$"#,
                in: before)
            // Expand abbreviations in their own paragraph only. An earlier
            // paragraph about software does not change an emphatic pronoun.
            let paragraphBefore = localTimingContext(String(text[..<range.lowerBound].suffix(512)))
                .components(separatedBy: "|").last ?? ""
            let paragraphAfter = localTimingContext(String(text[range.upperBound...].prefix(512)))
                .components(separatedBy: "|").first ?? ""
            let technologyContext = (paragraphBefore + " " + paragraphAfter).range(
                of: #"\b(?:AI|ERP|CRM|(?i:software|technology|technical|infrastructure|enterprise))\b"#,
                options: .regularExpression) != nil
            // No spaces inside an override: the chunker can split long
            // sentences at any space before passing them to the phonemizer.
            return nounAfter || (prepositionBefore && technologyContext) ? "[IT](/ˌItˈi/)" : token
        }
    }

    /// Replace standalone digit runs with their spoken words. A number
    /// written with thousands commas is a count, never a year, so it
    /// reads as a cardinal.
    private static func spellNumbers(in text: String) -> String {
        var result = replaceMatches(
            of: #"(?<![\p{L}\d])\d{1,3}(?:,\d{3})+(?![\p{L}\d])"#, in: text
        ) { match in
            let digits = match.replacingOccurrences(of: ",", with: "")
            guard let value = Int(digits), value <= 999_999 else {
                return EnglishNumberSpeller.spellDigits(digits)
            }
            return EnglishNumberSpeller.cardinal(value)
        }
        result = replaceMatches(
            of: #"(?<![\p{L}\d])\d+(?![\p{L}\d])"#, in: result
        ) { match in
            EnglishNumberSpeller.spellToken(match)
        }
        return result
    }

    /// Replace ordinals ("27th") before the digit-letter split tears
    /// their suffix off.
    private static func spellOrdinals(in text: String) -> String {
        replaceMatches(
            of: #"(?<![\p{L}\d])\d+(?:st|nd|rd|th)(?![\p{L}\d])"#, in: text
        ) { match in
            let digits = String(match.dropLast(2))
            guard let value = Int(digits), value <= 999_999 else {
                return match
            }
            return EnglishNumberSpeller.ordinal(value)
        }
    }

    // MARK: - Identifiers

    /// Spell tokens that mix letters and digits back and forth — commit
    /// hashes, identifiers — character by character, the way a person
    /// reads them. Single-boundary tokens like "24kHz" stay whole for
    /// the unit split instead.
    private static func spellIdentifiers(in text: String) -> String {
        replaceMatches(of: #"(?<![\p{L}\d])[a-zA-Z0-9]{6,}(?![\p{L}\d])"#, in: text) {
            match in
            var transitions = 0
            var previousIsDigit: Bool?
            var hasLetter = false
            var hasDigit = false
            for character in match {
                let isDigit = character.isNumber
                hasDigit = hasDigit || isDigit
                hasLetter = hasLetter || !isDigit
                if let previous = previousIsDigit, previous != isDigit {
                    transitions += 1
                }
                previousIsDigit = isDigit
            }
            guard hasLetter, hasDigit, transitions >= 2 else { return match }
            return match.map { character in
                character.isNumber
                    ? EnglishNumberSpeller.spellDigits(String(character))
                    : String(character)
            }.joined(separator: " ")
        }
    }

    private static func replaceMatches(
        of pattern: String,
        in text: String,
        with replacement: (String) -> String
    ) -> String {
        replaceMatchesWithRange(of: pattern, in: text) { match, _ in replacement(match) }
    }

    private static func replaceMatchesWithRange(
        of pattern: String,
        in text: String,
        with replacement: (String, Range<String.Index>) -> String
    ) -> String {
        guard
            let regex = try? NSRegularExpression(pattern: pattern)
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var lastEnd = text.startIndex
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else {
                continue
            }
            result += text[lastEnd..<matchRange.lowerBound]
            result += replacement(String(text[matchRange]), matchRange)
            lastEnd = matchRange.upperBound
        }
        result += text[lastEnd...]
        return result
    }
}
