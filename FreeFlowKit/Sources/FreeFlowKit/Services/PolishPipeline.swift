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

        if !casual {
            // Capitalize first letter after sentence-ending punctuation + space.
            result = capitalizeAfterPattern(result, pattern: "([.!?]\\s+)(\\w)")

            // Capitalize very first character — unless we're continuing
            // mid-sentence from preceding text.
            let midSentence = precedingText.map {
                !$0.isEmpty && !endsAtSentenceBoundary($0)
            } ?? false
            if !midSentence, let first = result.first, first.isLetter {
                result = first.uppercased() + result.dropFirst()
            }
        }

        // Remove spurious commas from Apple STT artifacts.
        result = cleanSpuriousCommas(result)

        // Strip multi-word noise phrases (uh huh, mm hmm) as units
        // before single filler sounds, so they aren't split by L1.
        result = stripNoisePhrases(result)

        // Strip pure filler sounds (um, uh, ah, hmm, etc.).
        result = stripFillerSounds(result)

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

    // MARK: - Spurious Comma Cleanup

    /// Remove spurious commas inserted by Apple's speech-to-text engine.
    ///
    /// Apple's dictation sometimes inserts commas before or after words
    /// where they don't belong: "I will be there at 3, PM,, tomorrow,"
    /// becomes "I will be there at 3 PM tomorrow".
    public static func cleanSpuriousCommas(_ text: String) -> String {
        var result = text

        // Collapse doubled/tripled commas: ",," or ",,," → ","
        result = result.replacingOccurrences(
            of: #",{2,}"#, with: ",", options: .regularExpression)

        // Remove comma before AM/PM (case insensitive).
        result = result.replacingOccurrences(
            of: #",\s*(AM|PM|a\.m\.|p\.m\.)"#, with: " $1",
            options: .regularExpression)

        // Remove trailing comma at end of sentence (before period or end).
        result = result.replacingOccurrences(
            of: #",(\s*[.!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #",\s*$"#, with: "", options: .regularExpression)

        // Remove comma-space-comma patterns.
        result = result.replacingOccurrences(
            of: #",\s*,"#, with: ",", options: .regularExpression)

        // Collapse multiple spaces left behind.
        result = result.replacingOccurrences(
            of: " {2,}", with: " ", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespaces)
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
        _ text: String, casual: Bool = false
    ) -> String {
        var result = text

        // Strip tags, keep content.
        result = keepTagPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1")

        // Expand break placeholders to real newlines.
        result = result.replacingOccurrences(
            of: " *\\[PAR\\] *", with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(
            of: " *\\[NL\\] *", with: "\n", options: .regularExpression)
        // Legacy placeholders (pilcrow / return arrow).
        result = result.replacingOccurrences(
            of: " *\u{00b6} *", with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(
            of: " *\u{21b5} *", with: "\n", options: .regularExpression)

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
        // Mid-sentence (followed by space): just replace, drop the dot.
        // End of sentence (followed by end-of-string or newline): restore
        // the period that did double duty as abbreviation and sentence end.
        result = result.replacingOccurrences(
            of: #"\ba\.m\.(?= )"#, with: "AM", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\ba\.m\.(?=$|\n)"#, with: "AM.", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\bp\.m\.(?= )"#, with: "PM", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\bp\.m\.(?=$|\n)"#, with: "PM.", options: .regularExpression)

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
        ]
        return terms.map { (pattern, replacement) in
            // Case-insensitive whole-word match.
            // swiftlint:disable:next force_try
            let regex = try! NSRegularExpression(
                pattern: "(?<=\\b)\(NSRegularExpression.escapedPattern(for: pattern))(?=\\b)",
                options: .caseInsensitive)
            return (regex, replacement)
        }
    }()

    /// Replace known tech terms with their correct capitalization.
    static func capitalizeKnownTerms(_ text: String) -> String {
        var result = text
        for (regex, replacement) in knownTerms {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement)
        }
        return result
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
}
