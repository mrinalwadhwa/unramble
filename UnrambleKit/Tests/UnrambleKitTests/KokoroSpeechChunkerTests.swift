import Foundation
import Testing

@testable import UnrambleKit

@Suite("Kokoro speech chunker")
struct KokoroSpeechChunkerTests {

    @Test("Short paragraphs remain separate even when they fit in one chunk")
    func shortParagraphsStaySeparate() {
        let content = ReadableContent(segments: [
            .init(kind: .prose, text: "First paragraph"),
            .init(kind: .prose, text: "Second paragraph"),
        ])
        let script = SpeechScriptBuilder().script(for: content)
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: KokoroTextNormalizer.normalize(script))

        #expect(chunks.count == 2)
        #expect(chunks.map(\.text) == ["First paragraph.", "Second paragraph"])
        #expect(chunks.map(\.pauseAfter) == [true, false])
    }

    @Test("A short script stays in one chunk")
    func shortScriptStaysWhole() {
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: "The build finished. All tests passed.")
        #expect(chunks.map(\.text) == ["The build finished. All tests passed."])
        #expect(chunks.map(\.pauseAfter) == [false])
    }

    @Test("Sentences pack into chunks up to the limit")
    func sentencesPackUpToLimit() {
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: "One two three. Four five six. Seven eight nine.",
            maximumLength: 32)
        #expect(chunks.map(\.text) == [
            "One two three. Four five six.",
            "Seven eight nine.",
        ])
    }

    @Test("Chunks break at sentence boundaries, not mid-sentence")
    func breaksAtSentenceBoundaries(){
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: "A very long opening sentence here. Short tail.",
            maximumLength: 40)
        #expect(chunks.map(\.text) == [
            "A very long opening sentence here.",
            "Short tail.",
        ])
    }

    @Test("An overlong sentence splits at word boundaries")
    func overlongSentenceSplitsAtWords() {
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: "alpha beta gamma delta epsilon",
            maximumLength: 12)
        #expect(chunks.map(\.text) == ["alpha beta", "gamma delta", "epsilon"])
    }

    @Test("Decimals and dotted names do not end sentences")
    func decimalsStayWhole() {
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: "Version 2.5 shipped to unramble.app today. Enjoy.")
        #expect(chunks.map(\.text) == ["Version 2.5 shipped to unramble.app today. Enjoy."])
    }

    @Test("Line breaks separate sentences")
    func lineBreaksSeparate() {
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: "First line\nSecond line",
            maximumLength: 11)
        #expect(chunks.map(\.text) == ["First line", "Second line"])
        #expect(chunks.map(\.pauseAfter) == [false, false])
    }

    @Test("Whitespace-only input yields no chunks")
    func whitespaceYieldsNothing() {
        #expect(KokoroSpeechChunker.paragraphChunks(from: "  \n  ").isEmpty)
    }

    @Test("Questions and exclamations end sentences")
    func questionsAndExclamationsEnd() {
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: "Ready? Go! Done.",
            maximumLength: 9)
        #expect(chunks.map(\.text) == ["Ready?", "Go! Done."])
    }

    @Test("Soft line wraps stay within a paragraph")
    func softLineWrapsStayTogether() {
        let chunks = KokoroSpeechChunker.paragraphChunks(from: "First line\nSecond line")
        #expect(chunks.map(\.text) == ["First line Second line"])
        #expect(chunks.map(\.pauseAfter) == [false])
    }

    @Test("Blank lines produce one boundary without leading or trailing pauses",
        arguments: ["\n", "\r\n", "\r"])
    func blankLinesProduceOneBoundary(newline: String) {
        let text = ["", "First.", " \t", "", "Second.", ""].joined(separator: newline)
        let chunks = KokoroSpeechChunker.paragraphChunks(from: text)
        #expect(chunks.map(\.text) == ["First.", "Second."])
        #expect(chunks.map(\.pauseAfter) == [true, false])
    }

    @Test("Only the last chunk before the next paragraph carries a pause")
    func longParagraphMarksOnlyItsFinalChunk() {
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: "alpha beta gamma delta epsilon\n\nNext.", maximumLength: 12)
        #expect(chunks.map(\.text) == ["alpha beta", "gamma delta", "epsilon", "Next."])
        #expect(chunks.map(\.pauseAfter) == [false, false, true, false])
    }

    @Test("The cloud voice retains its existing sentence packing")
    func cloudSentencePackingIsUnchanged() {
        #expect(KokoroSpeechChunker.chunks(
            from: "First.\n\nSecond.", maximumLength: 3000) == ["First. Second."])
    }
}
