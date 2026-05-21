import Testing

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Edge case tests for the deterministic polish pipeline.
//
// Verify that the pipeline does not damage user content. Each test
// sends input through the actual pipeline stages and checks that
// content words survive. Tests are grouped by the category of
// false positive they guard against.
// ---------------------------------------------------------------------------

// swiftlint:disable line_length

// MARK: - Punctuation words used as content

@Suite("Punctuation – words used as content not commands",
    .disabled("Known: dictated punctuation rules match content words"))
struct PunctuationWordsAsContentTests {

    // "period" is a common English noun. The \bperiod\b rule replaces
    // it with ".". Fixing this requires context-aware matching.

    @Test("period as noun: billing period")
    func billingPeriod() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "the billing period is thirty days")
        #expect(result.lowercased().contains("period"),
            "User said 'billing period' (a noun) but got: \(result)")
    }

    @Test("period as noun: probation period")
    func probationPeriod() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "the probation period ends on Friday")
        #expect(result.lowercased().contains("period"),
            "User said 'probation period' (a noun) but got: \(result)")
    }

    @Test("period as noun: during that period")
    func duringThatPeriod() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "during that period we saw significant growth")
        #expect(result.lowercased().contains("period"),
            "User said 'during that period' but got: \(result)")
    }

    @Test("full stop as noun phrase")
    func fullStopNoun() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "the car came to a full stop at the intersection")
        #expect(result.lowercased().contains("full stop"),
            "User said 'full stop' (noun phrase) but got: \(result)")
    }

    @Test("colon as body part")
    func colonBodyPart() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "schedule a colon screening for next month")
        #expect(result.lowercased().contains("colon"),
            "User said 'colon screening' (medical term) but got: \(result)")
    }

    @Test("exclamation point as discussion topic")
    func exclamationPointMeta() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "what does the exclamation point in the error message mean")
        #expect(result.lowercased().contains("exclamation point"),
            "User was discussing the symbol but got: \(result)")
    }

    @Test("hashtag as noun")
    func hashtagNoun() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "the hashtag went viral on social media")
        #expect(result.lowercased().contains("hashtag"),
            "User said 'the hashtag' (noun) but got: \(result)")
    }
}

// MARK: - Sentence-initial content words survive pipeline

@Suite("Filler – sentence-initial content words survive pipeline")
struct SentenceInitialContentTests {

    // After dial-back, sentence-initial fillers (so, well, right,
    // okay, basically) are no longer stripped by the pipeline.
    // These tests verify content words survive.

    @Test("so far survives pipeline")
    func soFar() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "So far everything looks good")
        #expect(result.contains("So far") || result.contains("so far"),
            "'So far' should survive pipeline: \(result)")
    }

    @Test("so much for survives pipeline")
    func soMuchFor() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "So much for the plan to launch early")
        #expect(result.lowercased().contains("so much"),
            "'So much for' should survive pipeline: \(result)")
    }

    @Test("so be it survives pipeline")
    func soBeIt() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "So be it we'll go with plan B")
        #expect(result.lowercased().contains("so be it"),
            "'So be it' should survive pipeline: \(result)")
    }

    @Test("well done survives pipeline")
    func wellDone() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "Well done on shipping the release")
        #expect(result.lowercased().contains("well done"),
            "'Well done' should survive pipeline: \(result)")
    }

    @Test("well known survives pipeline")
    func wellKnown() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "Well known experts recommend this approach")
        #expect(result.lowercased().contains("well known")
            || result.lowercased().contains("well-known"),
            "'Well known' should survive pipeline: \(result)")
    }

    @Test("right now survives pipeline")
    func rightNow() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "Right now the priority is shipping the fix")
        #expect(result.lowercased().contains("right now"),
            "'Right now' should survive pipeline: \(result)")
    }

    @Test("right here survives pipeline")
    func rightHere() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "Right here is where the bug lives")
        #expect(result.lowercased().contains("right here"),
            "'Right here' should survive pipeline: \(result)")
    }

    @Test("right angles survives pipeline")
    func rightAngles() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "Right angles are important in the UI layout")
        #expect(result.lowercased().contains("right angles"),
            "'Right angles' should survive pipeline: \(result)")
    }

    @Test("basically survives pipeline")
    func basicallyContent() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "Basically identical results across all test runs")
        #expect(result.lowercased().contains("basically"),
            "'Basically' should survive pipeline: \(result)")
    }
}

// MARK: - Number words survive pipeline

@Suite("Number – number words survive pipeline without conversion")
struct NumberWordsSurviveTests {

    // After dial-back, NumberConverter is not called. Number words
    // pass through to the model unchanged.

    @Test("zero tolerance survives pipeline")
    func zeroTolerance() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "zero tolerance for downtime")
        #expect(result.lowercased().contains("zero"),
            "'zero tolerance' should survive pipeline: \(result)")
    }

    @Test("zero day survives pipeline")
    func zeroDay() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "we found a zero day vulnerability")
        #expect(result.contains("zero"),
            "'zero day' should survive pipeline: \(result)")
    }

    @Test("ground zero survives pipeline")
    func groundZero() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "we're starting from ground zero")
        #expect(result.contains("zero"),
            "'ground zero' should survive pipeline: \(result)")
    }

    @Test("one on one survives pipeline")
    func oneOnOne() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "let's schedule a one on one meeting")
        #expect(result.contains("one on one"),
            "'one on one' should survive pipeline: \(result)")
    }

    @Test("square one survives pipeline")
    func squareOne() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "we're back to square one on the design")
        #expect(result.contains("one"),
            "'square one' should survive pipeline: \(result)")
    }

    @Test("it takes two to tango survives pipeline")
    func twoToTango() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "it takes two to tango on this decision")
        #expect(result.contains("two"),
            "'two to tango' should survive pipeline: \(result)")
    }

    @Test("one and only survives pipeline")
    func oneAndOnly() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "the one and only solution is to rebuild")
        #expect(result.contains("one"),
            "'one and only' should survive pipeline: \(result)")
    }
}

// MARK: - Reduplicated phrases survive pipeline

@Suite("Repetition – reduplicated phrases survive pipeline")
struct ReduplicationSurvivesTests {

    // After dial-back, deduplicateRepeats is not called. Legitimate
    // reduplication passes through to the model unchanged.

    @Test("bye bye survives pipeline")
    func byeBye() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "bye bye see you tomorrow")
        #expect(result.lowercased().contains("bye bye"),
            "'bye bye' should survive pipeline: \(result)")
    }

    @Test("so so survives pipeline")
    func soSo() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "the results were so so")
        #expect(result.lowercased().contains("so so"),
            "'so so' should survive pipeline: \(result)")
    }

    @Test("ha ha survives pipeline")
    func haHa() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "ha ha that's funny")
        #expect(result.lowercased().contains("ha ha"),
            "'ha ha' should survive pipeline: \(result)")
    }

    @Test("hear hear survives pipeline")
    func hearHear() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "hear hear that's a great proposal")
        #expect(result.lowercased().contains("hear hear"),
            "'hear hear' should survive pipeline: \(result)")
    }

    @Test("knock knock survives pipeline")
    func knockKnock() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "knock knock who's there")
        #expect(result.lowercased().contains("knock knock"),
            "'knock knock' should survive pipeline: \(result)")
    }

    @Test("there there survives pipeline")
    func thereThere() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "there there it's going to be okay")
        #expect(result.lowercased().contains("there there"),
            "'there there' should survive pipeline: \(result)")
    }

    @Test("now now survives pipeline")
    func nowNow() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "now now let's not get ahead of ourselves")
        #expect(result.lowercased().contains("now now"),
            "'now now' should survive pipeline: \(result)")
    }

    @Test("chop chop survives pipeline")
    func chopChop() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "chop chop we need to ship this today")
        #expect(result.lowercased().contains("chop chop"),
            "'chop chop' should survive pipeline: \(result)")
    }

    @Test("aye aye survives pipeline")
    func ayeAye() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "aye aye I'll get it done")
        #expect(result.lowercased().contains("aye aye"),
            "'aye aye' should survive pipeline: \(result)")
    }

    // Stutters still pass through unchanged too (model handles them).
    @Test("stutters pass through for model to handle")
    func stutterPassThrough() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "I think I think we should fix it")
        #expect(result.lowercased().contains("i think i think"),
            "Stutters should pass through to model: \(result)")
    }
}

// MARK: - Homophones survive pipeline

@Suite("Homophone – homophones survive pipeline for model to handle")
struct HomophonesSurvivePipelineTests {

    // After dial-back, HomophoneCorrector is not called in the
    // pipeline. These verify homophones pass through unchanged.

    @Test("their + gerund-as-noun survives")
    func theirBuilding() {
        let result = PolishPipeline.normalizeFormatting(
            "their building was sold last year")
        #expect(result.contains("their building"),
            "'their building' should survive normalizeFormatting: \(result)")
    }

    @Test("who's + adjective survives")
    func whosReady() {
        let result = PolishPipeline.normalizeFormatting(
            "who's ready for the meeting")
        #expect(result.contains("who's ready"),
            "'who's ready' should survive normalizeFormatting: \(result)")
    }

    @Test("weather + clause word survives")
    func weatherThis() {
        let result = PolishPipeline.normalizeFormatting(
            "expect bad weather this week")
        #expect(result.contains("weather this"),
            "'weather this' should survive normalizeFormatting: \(result)")
    }

    @Test("bare with survives")
    func bareWith() {
        let result = PolishPipeline.normalizeFormatting(
            "please bare with me while I pull up the report")
        #expect(result.contains("bare with"),
            "'bare with' should survive normalizeFormatting: \(result)")
    }
}

// MARK: - Preamble phrases survive pipeline

@Suite("Filler – preamble phrases survive pipeline")
struct PreambleSurvivesTests {

    // After dial-back, preamble phrases are not stripped. They pass
    // through for the model to handle.

    @Test("I just wanted to say that survives")
    func justWantedToSay() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "I just wanted to say that the team did an amazing job")
        #expect(result.lowercased().contains("i just wanted to say"),
            "Preamble should survive pipeline: \(result)")
    }

    @Test("what happened was survives")
    func whatHappenedWas() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "what happened was the deploy script had a typo")
        #expect(result.lowercased().contains("what happened was"),
            "Preamble should survive pipeline: \(result)")
    }

    @Test("so the thing is survives")
    func soTheThingIs() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "so the thing is we need more budget for Q3")
        #expect(result.lowercased().contains("so the thing is")
            || result.lowercased().contains("the thing is"),
            "Preamble should survive pipeline: \(result)")
    }
}

// MARK: - Noise sounds still stripped (safe operations)

@Suite("Filler – noise sounds still stripped correctly")
struct NoiseSoundsStillStrippedTests {

    @Test("um stripped from input")
    func umStripped() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "um I was thinking about this")
        #expect(!result.lowercased().contains("um "),
            "'um' should still be stripped: \(result)")
    }

    @Test("uh stripped from input")
    func uhStripped() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "we should uh fix the bug")
        #expect(!result.lowercased().contains(" uh "),
            "'uh' should still be stripped: \(result)")
    }

    @Test("uh huh stripped from input")
    func uhHuhStripped() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "uh huh the meeting is at 3")
        #expect(!result.lowercased().contains("uh huh"),
            "'uh huh' should still be stripped: \(result)")
    }

    @Test("mm hmm stripped from input")
    func mmHmmStripped() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "mm hmm that makes sense")
        #expect(!result.lowercased().contains("mm hmm"),
            "'mm hmm' should still be stripped: \(result)")
    }

    @Test("hmm stripped from input")
    func hmmStripped() {
        let result = PolishPipeline.substituteDictatedPunctuation(
            "hmm I think we should wait")
        #expect(!result.lowercased().contains("hmm"),
            "'hmm' should still be stripped: \(result)")
    }
}

// MARK: - Punctuation commands must not match content words

@Suite("Punctuation – content words not converted to symbols")
struct PunctuationFalsePositiveTests {

    private func pp(_ input: String) -> String {
        PolishPipeline.substituteDictatedPunctuation(input)
    }

    // "star" as noun — must not become *
    @Test("star as noun")
    func starAsNoun() {
        let result = pp("she's a star player on the team")
        #expect(result.contains("star"), "star replaced: \(result)")
    }

    @Test("five star review")
    func fiveStarReview() {
        let result = pp("it got a five star review")
        #expect(result.contains("star"), "star replaced: \(result)")
    }

    // "slash" as verb — must not become /
    @Test("slash as verb")
    func slashAsVerb() {
        let result = pp("they had to slash the budget")
        #expect(result.contains("slash"), "slash replaced: \(result)")
    }

    // "dash" as noun/verb — must not become –
    @Test("dash as noun")
    func dashAsNoun() {
        let result = pp("add a dash of salt to the recipe")
        #expect(result.contains("dash"), "dash replaced: \(result)")
    }

    @Test("dash as verb")
    func dashAsVerb() {
        let result = pp("I need to dash to the store")
        #expect(result.contains("dash"), "dash replaced: \(result)")
    }

    // "mention" as verb — must not become @
    @Test("mention as verb")
    func mentionAsVerb() {
        let result = pp("don't mention it to the client")
        #expect(result.contains("mention"), "mention replaced: \(result)")
    }

    // "ping" as verb — must not become @
    @Test("ping as verb")
    func pingAsVerb() {
        let result = pp("ping the server to check if it's up")
        #expect(result.lowercased().contains("ping"), "ping replaced: \(result)")
    }

    // "less than" as comparison — must not become <
    @Test("less than as comparison")
    func lessThanComparison() {
        let result = pp("the result was less than ideal")
        #expect(result.contains("less than"), "less than replaced: \(result)")
    }

    // "greater than" as comparison — must not become >
    @Test("greater than as comparison")
    func greaterThanComparison() {
        let result = pp("the turnout was greater than expected")
        #expect(result.contains("greater than"), "greater than replaced: \(result)")
    }

    // "trademark" as noun — must not become ™
    @Test("trademark as noun")
    func trademarkAsNoun() {
        let result = pp("we need to protect our trademark")
        #expect(result.contains("trademark"), "trademark replaced: \(result)")
    }

    // "copyright" as noun — must not become ©
    @Test("copyright as noun")
    func copyrightAsNoun() {
        let result = pp("copyright law is complex")
        #expect(result.lowercased().contains("copyright"), "copyright replaced: \(result)")
    }

    // "negative" as adjective — must not become -
    @Test("negative as adjective")
    func negativeAsAdjective() {
        let result = pp("the negative impact was significant")
        #expect(result.contains("negative"), "negative replaced: \(result)")
    }

    // Safe commands that SHOULD still work
    @Test("forward slash still works")
    func forwardSlash() {
        let result = pp("the path is input forward slash output")
        #expect(result.contains("/"), "forward slash not converted: \(result)")
    }

    @Test("em dash still works")
    func emDash() {
        let result = pp("the project em dash which started in January em dash is done")
        #expect(result.contains("\u{2014}"), "em dash not converted: \(result)")
    }

    @Test("at sign still works")
    func atSign() {
        let result = pp("send it to john at sign example dot com")
        #expect(result.contains("@"), "at sign not converted: \(result)")
    }

    @Test("asterisk still works")
    func asteriskCommand() {
        let result = pp("wrap it in asterisk tags asterisk")
        #expect(result.contains("*"), "asterisk not converted: \(result)")
    }

    @Test("angle bracket still works")
    func angleBracket() {
        let result = pp("use angle bracket div close angle bracket")
        #expect(result.contains("<"), "angle bracket not converted: \(result)")
    }
}

// swiftlint:enable line_length
