import Foundation
import Testing

@testable import UnrambleKit

@Suite("Kokoro text normalizer")
struct KokoroTextNormalizerTests {

    @Test("Pound shorthand retains its currency and scale", arguments: [
        ("£318M", "three hundred eighteen million pounds"),
        ("£200M", "two hundred million pounds"),
        ("£48.65M", "forty eight point six five million pounds"),
        ("£.05b", "zero point zero five billion pounds"),
        ("£\u{00A0}1,250.05\u{202F}K", "one thousand two hundred fifty point zero five thousand pounds"),
    ])
    func abbreviatedPoundAmounts(input: String, expected: String) {
        #expect(KokoroTextNormalizer.normalize(input) == expected)
    }

    @Test("Lowercase k counts speak thousands", arguments: [
        ("1k to 100k employees", "one thousand to one hundred thousand employees"),
        ("1.25k records", "one point two five thousand records"),
        ("2025k records", "two thousand twenty five thousand records"),
    ])
    func abbreviatedCounts(input: String, expected: String) {
        #expect(KokoroTextNormalizer.normalize(input) == expected)
    }

    @Test("Ranges retain their connecting word", arguments: [
        ("10-20 people", "ten to twenty people"),
        ("18-22 days", "eighteen to twenty two days"),
        ("7–9 days", "seven to nine days"),
        ("600-800 invoices", "six hundred to eight hundred invoices"),
        ("8-12%", "eight to twelve percent"),
        ("1.14–2.05", "one point one four to two point zero five"),
        ("1k-2k employees", "one thousand to two thousand employees"),
    ])
    func numericRanges(input: String, expected: String) {
        #expect(KokoroTextNormalizer.normalize(input) == expected)
    }

    @Test("Decimal fractions speak each digit", arguments: [
        ("1.14 actions", "one point one four actions"),
        ("0.005", "zero point zero zero five"),
        (".25", "zero point two five"),
        ("2025.14", "two thousand twenty five point one four"),
        ("1.14x faster", "one point one four times faster"),
    ])
    func decimalPrecision(input: String, expected: String) {
        #expect(KokoroTextNormalizer.normalize(input) == expected)
    }

    @Test("Common fractions speak their denominator", arguments: [
        ("2/3 of them", "two thirds of them"),
        ("1/2", "one half"),
        ("3/4", "three quarters"),
        ("5/8", "five eighths"),
        ("1 1/2 hours", "one and one half hours"),
    ])
    func commonFractions(input: String, expected: String) {
        #expect(KokoroTextNormalizer.normalize(input) == expected)
    }

    @Test("Numeric rules do not reinterpret dates, identifiers, or units", arguments: [
        "2026-09-14", "09/14/2026", "on 2/3", "version 1.2.3", "RFC-10-20",
        "24kHz", "1TB", "4K", "v1k", "£1MB", "£1\n\nM", "1\n\nk",
    ])
    func numericTokenBoundaries(input: String) {
        let result = KokoroTextNormalizer.normalize(input)
        #expect(!result.contains(" to "))
        #expect(!result.contains("thirds"))
        #expect(!result.contains("million pounds"))
        #expect(!result.contains("thousand"))
    }

    @Test("Slash-form date ranges are not fractions", arguments: [
        ("09/14-09/20", "zero nine/fourteen zero nine/twenty"),
        ("09/14–09/20", "zero nine/fourteen, zero nine/twenty"),
        ("09/14 - 09/20", "zero nine/fourteen - zero nine/twenty"),
    ])
    func slashDateRanges(input: String, expected: String) {
        #expect(KokoroTextNormalizer.normalize(input) == expected)
    }

    @Test("IT in technology contexts carries letter pronunciation", arguments: [
        "IT specialists understand", "HR touches IT and Ops", "AI cannot come from just IT,",
        "AI adoption is changing. He said this about IT back in 1990", "The IT department",
    ])
    func technologyInitialism(input: String) {
        #expect(KokoroTextNormalizer.normalize(input).contains("[IT](/ˌItˈi/)"))
    }

    @Test("Ordinary it and unrelated capitals keep their reading", arguments: [
        "It is fine.", "it works", "IT IS FINE.", "JUST DO IT.", "You did IT!",
        "GO FOR IT!", "Go for IT!", "I asked for IT.", "What about IT?",
        "AI adoption.\n\nWhat about IT?",
        "The CEO uses AI.", "ITinerary", "FP&AB", "Microsoft 3650",
    ])
    func abbreviationBoundaries(input: String) {
        let result = KokoroTextNormalizer.normalize(input)
        #expect(!result.contains("[IT]"))
        #expect(!result.contains("eff pee"))
        #expect(!result.contains("three sixty five"))
    }

    @Test("Finance abbreviation retains and and the letter A")
    func financeInitialism() {
        #expect(KokoroTextNormalizer.normalize("AP, AR, FP&A, Billing")
            == "AP, AR, eff pee and [A](/ˈA/), Billing")
        #expect(KokoroTextNormalizer.normalize("PO & goods receipt") == "PO and goods receipt")
    }

    @Test("Microsoft 365 uses its product-name reading")
    func microsoftProductName() {
        #expect(KokoroTextNormalizer.normalize("Microsoft 365 licenses")
            == "Microsoft three sixty five licenses")
    }

    @Test("Article-style numeric fixes preserve paragraph pauses")
    func articleNumberParagraphs() {
        let script = SpeechScriptBuilder().script(for: ReadableContent(segments: [
            .init(kind: .prose, text: "£48.65M covers 1k to 100k people."),
            .init(kind: .prose, text: "2/3 finish in 18-22 days, averaging 1.14 actions."),
        ]))
        let normalized = KokoroTextNormalizer.normalize(script)
        #expect(normalized == "forty eight point six five million pounds covers one thousand to one hundred thousand people.\n\n"
            + "two thirds finish in eighteen to twenty two days, averaging one point one four actions.")
        #expect(KokoroSpeechChunker.paragraphChunks(from: normalized).filter(\.pauseAfter).count == 1)
    }

    @Test("Abbreviation pronunciations stay intact when a long sentence is split")
    func abbreviationsAtChunkBoundaries() {
        let normalized = KokoroTextNormalizer.normalize("The IT department works with FP&A every day.")
        for limit in 12...40 {
            let chunks = KokoroSpeechChunker.chunks(from: normalized, maximumLength: limit)
            for chunk in chunks {
                // No opening override can be separated from its closing marker.
                #expect(chunk.filter { $0 == "[" }.count == chunk.components(separatedBy: "/)").count - 1)
            }
        }
    }

    @Test("Decade abbreviations use their plural spoken names", arguments: [
        ("90s", "nineties"),
        ("the 90s", "the nineties"),
        ("’90s music", "nineties music"),
        ("early 80s", "early eighties"),
        ("1990s", "nineteen nineties"),
        ("2020s", "twenty twenties"),
        ("1900s", "nineteen hundreds"),
        ("2000s", "two thousands"),
        ("Search for 90s music.", "Search for nineties music."),
        ("Wait for 90s music.", "Wait for nineties music."),
        ("After the 90s, things changed.", "After the nineties, things changed."),
    ])
    func decadeAbbreviations(input: String, expected: String) {
        #expect(KokoroTextNormalizer.normalize(input) == expected)
    }

    @Test("Timing context changes a decade-shaped token to seconds", arguments: [
        ("Wait 90s.", "Wait ninety seconds."),
        ("Wait for 90s.", "Wait for ninety seconds."),
        ("timeout: 90s", "timeout: ninety seconds"),
        ("The timeout is 90s.", "The timeout is ninety seconds."),
        ("90s later", "ninety seconds later"),
        ("90s remaining", "ninety seconds remaining"),
        ("It runs for 90s.", "It runs for ninety seconds."),
        ("Finish within 90s.", "Finish within ninety seconds."),
        ("Wait about 90s.", "Wait about ninety seconds."),
        ("the 90s timeout", "the ninety second timeout"),
        ("a 90s delay", "a ninety second delay"),
        ("Use 90s intervals.", "Use ninety second intervals."),
        ("Wait 1990s.", "Wait one thousand nine hundred ninety seconds."),
    ])
    func timingContext(input: String, expected: String) {
        #expect(KokoroTextNormalizer.normalize(input) == expected)
    }

    @Test("Each occurrence uses its own context in a mixed sentence")
    func mixedDecadeAndDuration() {
        #expect(KokoroTextNormalizer.normalize("Music from the 90s plays for 90s.")
            == "Music from the nineties plays for ninety seconds.")
        #expect(KokoroTextNormalizer.normalize("Wait 90s, then play 90s music.")
            == "Wait ninety seconds, then play nineties music.")
    }

    @Test("Timing context follows soft wraps but stops at sentence and paragraph boundaries")
    func timingContextBoundaries() {
        #expect(KokoroTextNormalizer.normalize("Wait\n90s.") == "Wait\nninety seconds.")
        #expect(KokoroTextNormalizer.normalize("Wait.\n\n90s music.")
            == "Wait.\n\nnineties music.")
        #expect(KokoroTextNormalizer.normalize("Wait\n \n90s") == "Wait\n \nnineties")
        #expect(KokoroTextNormalizer.normalize("Wait. 90s.") == "Wait. nineties.")
    }

    @Test("Decade recognition does not match pieces of identifiers or decimals")
    func decadeTokenBoundaries() {
        #expect(KokoroTextNormalizer.normalize("A90s 90sThing 90.90s _90s")
            == "A90 s ninety sThing ninety point nine zero s ninety s")
    }

    @Test("The approved masked word speaks its uncensored spelling")
    func maskedWord() {
        #expect(KokoroTextNormalizer.normalize("That is sh*t. Oh, SH*T!")
            == "That is shit. Oh, shit!")
        #expect(KokoroTextNormalizer.normalize("**sh*t**") == "shit")
        #expect(KokoroTextNormalizer.normalize("sh*tty sh**t push*t") == "sh tty sh t push t")
    }

    @Test("Abbreviated dollar amounts speak their scale and currency", arguments: [
        ("$1T", "one trillion dollars"),
        ("$410B", "four hundred ten billion dollars"),
        ("$37B", "thirty seven billion dollars"),
        ("$250K", "two hundred fifty thousand dollars"),
        ("$12M", "twelve million dollars"),
        ("$1.5T", "one point five trillion dollars"),
        ("$.5B", "zero point five billion dollars"),
        ("$0.25M", "zero point two five million dollars"),
        ("$1,250.05M", "one thousand two hundred fifty point zero five million dollars"),
        ("$2025M", "two thousand twenty five million dollars"),
        ("$2k", "two thousand dollars"),
        ("$3m", "three million dollars"),
        ("$4b", "four billion dollars"),
        ("$5t", "five trillion dollars"),
        ("$ 1.5 T", "one point five trillion dollars"),
        ("$\u{00A0}1T", "one trillion dollars"),
        ("$1\u{202F}T", "one trillion dollars"),
    ])
    func abbreviatedDollarAmounts(input: String, expected: String) {
        #expect(KokoroTextNormalizer.normalize(input) == expected)
    }

    @Test("Article currency amounts expand without losing paragraph boundaries")
    func currencyAmountsInParagraphs() {
        let script = SpeechScriptBuilder().script(for: ReadableContent(segments: [
            .init(kind: .prose, text: "Over $1T was spent on infrastructure."),
            .init(kind: .prose, text: "They spent $410B in 2025, but only $37B using it."),
        ]))

        let normalized = KokoroTextNormalizer.normalize(script)

        #expect(normalized == "Over one trillion dollars was spent on infrastructure.\n\n"
            + "They spent four hundred ten billion dollars in twenty twenty five, "
            + "but only thirty seven billion dollars using it.")
        #expect(KokoroSpeechChunker.paragraphChunks(from: normalized).filter(\.pauseAfter).count == 1)
    }

    @Test("Only complete dollar amounts expand their magnitude suffix")
    func currencyDoesNotExpandOtherTokens() {
        #expect(KokoroTextNormalizer.normalize("1T 410B 24kHz $1TB $2MB")
            == "one T four hundred ten B twenty four kHz $one TB $two MB")
        #expect(KokoroTextNormalizer.normalize("$1\n\nT") == "$one\n\nT")
        #expect(KokoroTextNormalizer.normalize("$\n\n1T") == "$\n\none T")
        #expect(KokoroTextNormalizer.normalize("$1\u{2028}T") == "$one\u{2028}T")
        #expect(KokoroTextNormalizer.normalize("$1\u{2029}T") == "$one\u{2029}T")
        #expect(KokoroTextNormalizer.normalize("$1,23M") == "$one,twenty three M")
    }

    @Test("Hyphenated compounds split into their words")
    func hyphenatedCompoundsSplit() {
        #expect(
            KokoroTextNormalizer.normalize(
                "The read-aloud voice uses focused-pane matching.")
                == "The read aloud voice uses focused pane matching.")
    }

    @Test("Number ranges speak to between endpoints")
    func numberRangesSpell() {
        #expect(
            KokoroTextNormalizer.normalize("Rows 5-10 changed.")
                == "Rows five to ten changed.")
    }

    @Test("Dashes become comma pauses")
    func dashesBecomePauses() {
        #expect(
            KokoroTextNormalizer.normalize("One thing — the tests pass.")
                == "One thing, the tests pass.")
        #expect(
            KokoroTextNormalizer.normalize("A – B")
                == "A, B")
    }

    @Test("Leading and trailing hyphens stay untouched")
    func bareHyphensStay() {
        #expect(
            KokoroTextNormalizer.normalize("Use the - flag, or -v.")
                == "Use the - flag, or -v.")
    }

    @Test("Plain text passes through unchanged")
    func plainTextUnchanged() {
        #expect(
            KokoroTextNormalizer.normalize("Nothing to change here.")
                == "Nothing to change here.")
    }

    @Test("Keyboard glyphs read as modifier names")
    func keyboardGlyphsReadAsNames() {
        #expect(
            KokoroTextNormalizer.normalize("Press ⌃⇧R to read aloud.")
                == "Press control shift R to read aloud.")
    }

    @Test("Multipliers after numbers read as times")
    func multipliersReadAsTimes() {
        #expect(
            KokoroTextNormalizer.normalize("The voice speaks at 1.1x now.")
                == "The voice speaks at one point one times now.")
        #expect(
            KokoroTextNormalizer.normalize("Warm generation runs 35× realtime.")
                == "Warm generation runs thirty five times real time.")
        #expect(
            KokoroTextNormalizer.normalize("Speed is now 1.2×.")
                == "Speed is now one point two times.")
    }

    @Test("Decimals speak their point instead of vanishing")
    func decimalsSpeakThePoint() {
        #expect(
            KokoroTextNormalizer.normalize("Version 0.3.1 shipped.")
                == "Version zero point three point one shipped.")
        #expect(
            KokoroTextNormalizer.normalize("It took 2.5 seconds.")
                == "It took two point five seconds.")
    }

    @Test("Dimensions between numbers read as by")
    func dimensionsReadAsBy() {
        #expect(
            KokoroTextNormalizer.normalize("A 1920×1080 screen.")
                == "A nineteen twenty by one thousand eighty screen.")
        #expect(
            KokoroTextNormalizer.normalize("A 1920x1080 screen.")
                == "A nineteen twenty by one thousand eighty screen.")
        #expect(
            KokoroTextNormalizer.normalize("A 3x5 card.")
                == "A three by five card.")
    }

    @Test("Hex literals spell per character")
    func hexLiteralsSpell() {
        #expect(
            KokoroTextNormalizer.normalize("Flag 0x1F is set.")
                == "Flag zero x one F is set.")
    }

    @Test("Missing compounds respell as their words")
    func compoundsRespell() {
        #expect(
            KokoroTextNormalizer.normalize("It runs 35x realtime.")
                == "It runs thirty five times real time.")
    }

    @Test("Years read as date pairs")
    func yearsReadAsDatePairs() {
        #expect(
            KokoroTextNormalizer.normalize("Signed on July 27, 2026.")
                == "Signed on July twenty seven, twenty twenty six.")
        #expect(
            KokoroTextNormalizer.normalize("Back in 1984 and 2005.")
                == "Back in nineteen eighty four and two thousand five.")
    }

    @Test("Counts spell as cardinals")
    func countsSpellAsCardinals() {
        #expect(
            KokoroTextNormalizer.normalize("It moved 1,432 files.")
                == "It moved one thousand four hundred thirty two files.")
        #expect(
            KokoroTextNormalizer.normalize("All 27 tests pass.")
                == "All twenty seven tests pass.")
    }

    @Test("Ordinals keep their suffix reading")
    func ordinalsKeepReading() {
        #expect(
            KokoroTextNormalizer.normalize("The 27th try on the 2nd.")
                == "The twenty seventh try on the second.")
    }

    @Test("Percentages read as percent")
    func percentagesReadAsPercent() {
        #expect(
            KokoroTextNormalizer.normalize("Coverage rose 27%.")
                == "Coverage rose twenty seven percent.")
    }

    @Test("Curly quotes become straight ones")
    func curlyQuotesBecomeStraight() {
        #expect(
            KokoroTextNormalizer.normalize("that\u{2019}s Fluent\u{2019}s plan")
                == "that's Fluent's plan")
    }

    @Test("Past-tense read pins the red sound after auxiliaries")
    func pastTenseReadPinsSound() {
        #expect(
            KokoroTextNormalizer.normalize("The file was read aloud.")
                == "The file was [read](/ɹˈɛd/) aloud.")
        #expect(
            KokoroTextNormalizer.normalize("They've read the docs.")
                == "They've [read](/ɹˈɛd/) the docs.")
        #expect(
            KokoroTextNormalizer.normalize("Press it to read aloud.")
                == "Press it to read aloud.")
    }

    @Test("Mixed identifiers spell character by character")
    func mixedIdentifiersSpell() {
        #expect(
            KokoroTextNormalizer.normalize("Commit 1db11e86 is ready.")
                == "Commit one d b one one e eight six is ready.")
    }

    @Test("Letters glued to numbers split apart")
    func gluedLettersSplit() {
        #expect(
            KokoroTextNormalizer.normalize("A 24kHz sample rate.")
                == "A twenty four kHz sample rate.")
    }

    @Test("Unspeakable symbols drop instead of garbling")
    func unspeakableSymbolsDrop() {
        #expect(
            KokoroTextNormalizer.normalize("Done ✅ ship it 🚀 now")
                == "Done ship it now")
        #expect(
            KokoroTextNormalizer.normalize("│ box ─ drawing ╰ art")
                == "box drawing art")
        #expect(
            KokoroTextNormalizer.normalize("Run `make test` first.")
                == "Run make test first.")
    }

    @Test("URLs read as their host")
    func urlsReadAsHost() {
        #expect(
            KokoroTextNormalizer.normalize(
                "See https://example.com/articles/how-i-built-a-factory/ today.")
                == "See example dot com today.")
        #expect(
            KokoroTextNormalizer.normalize(
                "Clone https://www.github.com/Blaizzy/mlx-audio-swift now.")
                == "Clone github dot com now.")
    }

    @Test("Mispronounced words carry phoneme overrides")
    func mispronouncedWordsCarryOverrides() {
        #expect(
            KokoroTextNormalizer.normalize("It was written by Mrinal Wadhwa.")
                == "It was [written](/ɹˈɪtᵊn/) by [Mrinal](/mɹinˈɑl/) [Wadhwa](/wˈɑdwɑ/).")
    }

    @Test("Arrows and bullets read as phrasing")
    func arrowsAndBulletsPhrase() {
        #expect(
            KokoroTextNormalizer.normalize("idle → speaking")
                == "idle to speaking")
        #expect(
            KokoroTextNormalizer.normalize("Steps: • build • sign")
                == "Steps:, build, sign")
    }
}
