import Testing

@testable import UnrambleKit

@Suite("Markdown segmenter")
struct MarkdownSegmenterTests {

    @Test("Plain text becomes one prose segment")
    func plainTextBecomesProse() {
        let segments = MarkdownSegmenter.segments(
            from: "The fix is in the resampler.\nIt drops frames.")
        #expect(segments == [
            .init(
                kind: .prose,
                text: "The fix is in the resampler.\nIt drops frames.")
        ])
    }

    @Test("Blank lines separate prose paragraphs")
    func blankLinesSeparateProseParagraphs() {
        let segments = MarkdownSegmenter.segments(
            from: "First paragraph.\n\nSecond paragraph.")
        #expect(segments == [
            .init(kind: .prose, text: "First paragraph."),
            .init(kind: .prose, text: "Second paragraph."),
        ])
    }

    @Test("Fenced code splits surrounding prose")
    func fencedCodeSplitsProse() {
        let markdown = """
            Before the code.

            ```swift
            let x = 1
            let y = 2
            ```

            After the code.
            """
        let segments = MarkdownSegmenter.segments(from: markdown)
        #expect(segments == [
            .init(kind: .prose, text: "Before the code."),
            .init(kind: .code, text: "let x = 1\nlet y = 2"),
            .init(kind: .prose, text: "After the code."),
        ])
    }

    @Test("Unterminated fence still yields its code")
    func unterminatedFenceYieldsCode() {
        let segments = MarkdownSegmenter.segments(
            from: "Intro.\n```\nlet a = 1")
        #expect(segments == [
            .init(kind: .prose, text: "Intro."),
            .init(kind: .code, text: "let a = 1"),
        ])
    }

    @Test("Headings become heading segments without markers")
    func headingsLoseMarkers() {
        let segments = MarkdownSegmenter.segments(
            from: "## What changed\nDetails follow.")
        #expect(segments == [
            .init(kind: .heading, text: "What changed"),
            .init(kind: .prose, text: "Details follow."),
        ])
    }

    @Test("Seven or more hash marks stay prose")
    func tooManyHashesStayProse() {
        let segments = MarkdownSegmenter.segments(from: "####### not a heading")
        #expect(segments == [
            .init(kind: .prose, text: "####### not a heading")
        ])
    }

    @Test("Bulleted and numbered items become list segments")
    func listItemsBecomeSegments() {
        let markdown = """
            - first thing
            * second thing
            1. third thing
            2) fourth thing
            """
        let segments = MarkdownSegmenter.segments(from: markdown)
        #expect(segments == [
            .init(kind: .listItem, text: "first thing"),
            .init(kind: .listItem, text: "second thing"),
            .init(kind: .listItem, text: "third thing"),
            .init(kind: .listItem, text: "fourth thing"),
        ])
    }

    @Test("Block quotes become quote segments")
    func blockQuotesBecomeSegments() {
        let segments = MarkdownSegmenter.segments(from: "> quoted words")
        #expect(segments == [.init(kind: .quote, text: "quoted words")])
    }

    @Test("A number without list punctuation stays prose")
    func bareNumberStaysProse() {
        let segments = MarkdownSegmenter.segments(from: "1980 was a year.")
        #expect(segments == [.init(kind: .prose, text: "1980 was a year.")])
    }

    @Test("Marker boundaries are honored exactly")
    func markerBoundaries() {
        #expect(
            MarkdownSegmenter.segments(from: "###### deep heading")
                == [.init(kind: .heading, text: "deep heading")])
        #expect(
            MarkdownSegmenter.segments(from: "#nospace")
                == [.init(kind: .prose, text: "#nospace")])
        #expect(
            MarkdownSegmenter.segments(from: "1.nospace")
                == [.init(kind: .prose, text: "1.nospace")])
        #expect(MarkdownSegmenter.segments(from: ">").isEmpty)
    }

    @Test("Empty input yields no segments")
    func emptyInputYieldsNothing() {
        #expect(MarkdownSegmenter.segments(from: "").isEmpty)
        #expect(MarkdownSegmenter.segments(from: "  \n\n  ").isEmpty)
    }
}
