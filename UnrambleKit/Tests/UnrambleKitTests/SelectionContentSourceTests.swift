import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Selection content source")
struct SelectionContentSourceTests {

    @Test("Browser selections recover paragraph breaks missing from selected text")
    func browserSelectionPreservesParagraphs() async throws {
        let paragraphs = [
            "That's a real quote. Are you kidding me?",
            "Note: To pave the cow paths means to automate an existing process.",
            "Meanwhile, spending on infrastructure continues.",
        ]
        let reader = MockSelectionReader(stubbedSelection: paragraphs.joined())
        let webReader = MockWebContentReader(stubbedContent: ReadableContent(
            segments: paragraphs.map { .init(kind: .prose, text: $0) }))
        let source = SelectionContentSource(selectionReader: reader, webReader: webReader)
        let context = AppContext(
            bundleID: "com.brave.Browser", appName: "Brave", windowTitle: "Article",
            processIdentifier: 123)

        let content = try #require(try await source.readContent(for: context))

        #expect(content.segments.map(\.text) == paragraphs)
        let chunks = KokoroSpeechChunker.paragraphChunks(
            from: KokoroTextNormalizer.normalize(SpeechScriptBuilder().script(for: content)))
        #expect(chunks.filter(\.pauseAfter).count == 2)
    }

    @Test("Uses the snapshot selection without a live read")
    func usesSnapshotSelection() async throws {
        let reader = MockSelectionReader(stubbedSelection: "live value")
        let source = SelectionContentSource(selectionReader: reader)
        let context = AppContext(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Untitled",
            selectedText: "snapshot value")

        let content = try await source.readContent(for: context)

        #expect(content?.segments == [
            .init(kind: .prose, text: "snapshot value")
        ])
        #expect(reader.readCount == 0)
    }

    @Test("Falls back to a live read when the snapshot has no selection")
    func fallsBackToLiveRead() async throws {
        let reader = MockSelectionReader(stubbedSelection: "from web page")
        let source = SelectionContentSource(selectionReader: reader)

        let content = try await source.readContent(for: .stub)

        #expect(content?.segments == [
            .init(kind: .prose, text: "from web page")
        ])
        #expect(reader.readCount == 1)
    }

    @Test("A whitespace-only snapshot selection falls back to a live read")
    func whitespaceSnapshotFallsBack() async throws {
        let reader = MockSelectionReader(stubbedSelection: "live")
        let source = SelectionContentSource(selectionReader: reader)
        let context = AppContext(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Untitled",
            selectedText: "  \n ")

        let content = try await source.readContent(for: context)

        #expect(content?.segments == [.init(kind: .prose, text: "live")])
        #expect(reader.readCount == 1)
    }

    @Test("Returns nil when nothing is selected")
    func returnsNilWithoutSelection() async throws {
        let reader = MockSelectionReader(stubbedSelection: nil)
        let source = SelectionContentSource(selectionReader: reader)
        #expect(try await source.readContent(for: .stub) == nil)
    }

    @Test("Treats a whitespace-only selection as no selection")
    func ignoresWhitespaceSelection() async throws {
        let reader = MockSelectionReader(stubbedSelection: "  \n ")
        let source = SelectionContentSource(selectionReader: reader)
        #expect(try await source.readContent(for: .stub) == nil)
    }

    @Test("Restoring paragraphs only includes the selected part of the first and last blocks")
    func partialParagraphSelectionStaysBounded() throws {
        let page = ReadableContent(segments: [
            .init(kind: .prose, text: "Unselected introduction. First paragraph ends here."),
            .init(kind: .prose, text: "Second paragraph begins here. Unselected ending."),
        ])
        let selected = "paragraph ends here.Second paragraph begins"

        let segments = try #require(WebSelectionParagraphs.segments(for: selected, in: page))

        #expect(segments.map(\.text) == ["paragraph ends here.", "Second paragraph begins"])
    }

    @Test("Matching tolerates collapsed whitespace without changing selected words")
    func matchingPreservesSelectionWhitespace() throws {
        let page = ReadableContent(segments: [
            .init(kind: .prose, text: "Café 👩🏽‍💻 uses a link."),
            .init(kind: .prose, text: "Next paragraph."),
        ])
        let selected = "Café 👩🏽‍💻 uses  a\tlink.\u{00a0}Next paragraph."

        let segments = try #require(WebSelectionParagraphs.segments(for: selected, in: page))

        #expect(segments.map(\.text) == ["Café 👩🏽‍💻 uses  a\tlink.", "Next paragraph."])
    }

    @Test("A selection within one paragraph does not gain breaks at wrapped lines")
    func aSingleParagraphKeepsSoftWraps() throws {
        let page = ReadableContent(segments: [
            .init(kind: .prose, text: "First line second line."),
        ])
        let selected = "First line\nsecond line."

        let segments = try #require(WebSelectionParagraphs.segments(for: selected, in: page))

        #expect(segments.map(\.text) == [selected])
        let script = SpeechScriptBuilder().script(for: ReadableContent(segments: segments))
        #expect(KokoroSpeechChunker.paragraphChunks(from: script).filter(\.pauseAfter).isEmpty)
    }

    @Test("Ambiguous or missing page matches leave the original selection intact",
        arguments: ["Missing selection.", "Repeat."])
    func unmatchedSelectionIsPreserved(selection: String) async throws {
        let page = ReadableContent(segments: [
            .init(kind: .prose, text: "Repeat."),
            .init(kind: .prose, text: "Repeat."),
        ])
        let source = SelectionContentSource(
            selectionReader: MockSelectionReader(stubbedSelection: selection),
            webReader: MockWebContentReader(stubbedContent: page))
        let context = AppContext(
            bundleID: "com.brave.Browser", appName: "Brave", windowTitle: "Article",
            processIdentifier: 123)

        let content = try #require(try await source.readContent(for: context))

        #expect(content.segments == [.init(kind: .prose, text: selection)])
    }

    @Test("Overlapping duplicate matches do not choose a paragraph boundary")
    func overlappingMatchesAreAmbiguous() {
        let page = ReadableContent(segments: [
            .init(kind: .prose, text: "aaa"),
            .init(kind: .prose, text: "aaa"),
        ])
        #expect(WebSelectionParagraphs.segments(for: "aaaa", in: page) == nil)
    }

    @Test("Whitespace removal that combines selected characters keeps the original selection")
    func recombinedSelectionCharactersAreNotSplit() {
        let page = ReadableContent(segments: [
            .init(kind: .prose, text: "🇺🇸"),
            .init(kind: .prose, text: "X"),
        ])

        #expect(WebSelectionParagraphs.segments(for: "\u{1F1FA} \u{1F1F8}X", in: page) == nil)
    }

    @Test("Page blocks that combine into a single character cannot define a selection cut")
    func recombinedPageCharactersAreNotSplit() {
        let page = ReadableContent(segments: [
            .init(kind: .prose, text: "e"),
            .init(kind: .prose, text: "\u{301}X"),
        ])

        #expect(WebSelectionParagraphs.segments(for: "e\u{301}X", in: page) == nil)
    }

    @Test("Changed Unicode boundaries are rejected even when character counts stay equal")
    func regroupedRegionalIndicatorsAreNotSplit() {
        let page = ReadableContent(segments: [
            .init(kind: .prose, text: "\u{1F1FA}"),
            .init(kind: .prose, text: "\u{1F1F8}\u{1F1E6}X"),
        ])

        #expect(WebSelectionParagraphs.segments(
            for: "\u{1F1FA}\u{1F1F8}\u{1F1E6}X", in: page) == nil)
    }

    @Test("Slow selection acquisition does not start an additional page lookup")
    func slowSelectionSkipsOptionalLookup() async throws {
        let webReader = MockWebContentReader(stubbedContent: ReadableContent(segments: [
            .init(kind: .prose, text: "First."),
            .init(kind: .prose, text: "Second."),
        ]))
        let source = SelectionContentSource(
            selectionReader: DelayedSelectionReader(), webReader: webReader,
            paragraphLookupTimeout: 0.01)
        let context = AppContext(
            bundleID: "com.brave.Browser", appName: "Brave", windowTitle: "Article",
            processIdentifier: 123)

        let content = try #require(try await source.readContent(for: context))

        #expect(content.segments == [.init(kind: .prose, text: "First.Second.")])
        #expect(webReader.requestedProcessIdentifiers.isEmpty)
    }

    @Test("Cancellation during selection acquisition does not publish the selection")
    func cancellationBeforeLookupStopsSelection() async throws {
        let source = SelectionContentSource(selectionReader: CancellingSelectionReader())
        let task = Task { try await source.readContent(for: .stub) }

        do {
            _ = try await task.value
            Issue.record("Cancelled acquisition returned content")
        } catch is CancellationError {
            // A valid selection cannot revive a cancelled read-aloud request.
        }
    }

    @Test("A native app selection never requests browser content")
    func nativeSelectionSkipsPageLookup() async throws {
        let webReader = MockWebContentReader()
        let source = SelectionContentSource(
            selectionReader: MockSelectionReader(stubbedSelection: "Selected text."),
            webReader: webReader)
        let context = AppContext(
            bundleID: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Document",
            processIdentifier: 123)

        let content = try #require(try await source.readContent(for: context))

        #expect(content.segments == [.init(kind: .prose, text: "Selected text.")])
        #expect(webReader.requestedProcessIdentifiers.isEmpty)
    }

    @Test("A timed-out page lookup still returns the selection", .timeLimit(.minutes(1)))
    func lookupTimeoutKeepsSelection() async throws {
        let webReader = SuspendedWebContentReader()
        let source = SelectionContentSource(
            selectionReader: MockSelectionReader(stubbedSelection: "Keep this selection."),
            webReader: webReader, paragraphLookupTimeout: 0.01)
        let context = AppContext(
            bundleID: "com.brave.Browser", appName: "Brave", windowTitle: "Article",
            processIdentifier: 123)

        let content = try #require(try await source.readContent(for: context))
        await webReader.finish()

        #expect(content.segments == [.init(kind: .prose, text: "Keep this selection.")])
    }

    @Test("Cancelling paragraph lookup does not publish a late selection",
        .timeLimit(.minutes(1)))
    func cancellationStopsParagraphLookup() async throws {
        let webReader = SuspendedWebContentReader()
        let source = SelectionContentSource(
            selectionReader: MockSelectionReader(stubbedSelection: "Selected text."),
            webReader: webReader)
        let context = AppContext(
            bundleID: "com.brave.Browser", appName: "Brave", windowTitle: "Article",
            processIdentifier: 123)
        let task = Task { try await source.readContent(for: context) }
        await webReader.waitForRead()

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled lookup returned content")
        } catch is CancellationError {
            // Cancellation must win even if the page reader has not returned.
        }
        await webReader.finish()
    }
}

private struct DelayedSelectionReader: SelectionReading {
    func readSelectedText() async -> String? {
        try? await Task.sleep(for: .milliseconds(30))
        return "First.Second."
    }
}

private struct CancellingSelectionReader: SelectionReading {
    func readSelectedText() async -> String? {
        withUnsafeCurrentTask { $0?.cancel() }
        return "Selected text."
    }
}

/// A read-only external operation that does not return on cancellation.
private actor SuspendedWebContentReader: WebContentReading {
    private var continuation: CheckedContinuation<ReadableContent?, Never>?
    private var started = false
    private var finished = false
    private var startWaiter: CheckedContinuation<Void, Never>?

    func readMainContent(processIdentifier: Int32) async -> ReadableContent? {
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitForRead() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish() {
        finished = true
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
