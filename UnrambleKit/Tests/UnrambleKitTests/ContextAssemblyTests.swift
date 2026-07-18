import Foundation
import Testing

@testable import UnrambleKit
import UnrambleKitTestSupport

@Suite("Context assembly")
struct ContextAssemblyTests {

    // MARK: - AppContext Population

    @Test("Context with all fields populated")
    func contextFullyPopulated() {
        let context = AppContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Apple - Start",
            browserURL: "https://apple.com",
            focusedFieldContent: "search query",
            selectedText: "query",
            cursorPosition: 12
        )

        #expect(context.bundleID == "com.apple.Safari")
        #expect(context.appName == "Safari")
        #expect(context.windowTitle == "Apple - Start")
        #expect(context.browserURL == "https://apple.com")
        #expect(context.focusedFieldContent == "search query")
        #expect(context.selectedText == "query")
        #expect(context.cursorPosition == 12)
    }

    @Test("Context with only required fields")
    func contextMinimalFields() {
        let context = AppContext(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Untitled"
        )

        #expect(context.bundleID == "com.apple.TextEdit")
        #expect(context.appName == "TextEdit")
        #expect(context.windowTitle == "Untitled")
        #expect(context.browserURL == nil)
        #expect(context.focusedFieldContent == nil)
        #expect(context.selectedText == nil)
        #expect(context.cursorPosition == nil)
    }

    @Test("Context with browser URL but no focused field")
    func contextBrowserNoField() {
        let context = AppContext(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "GitHub",
            browserURL: "https://github.com"
        )

        #expect(context.browserURL == "https://github.com")
        #expect(context.focusedFieldContent == nil)
        #expect(context.selectedText == nil)
        #expect(context.cursorPosition == nil)
    }

    @Test("Context with focused field but no browser URL")
    func contextFieldNoBrowser() {
        let context = AppContext(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            windowTitle: "main.swift — project",
            focusedFieldContent: "let x = 42",
            selectedText: "42",
            cursorPosition: 10
        )

        #expect(context.browserURL == nil)
        #expect(context.focusedFieldContent == "let x = 42")
        #expect(context.selectedText == "42")
    }

    @Test("Context with empty strings for required fields")
    func contextEmptyStrings() {
        let context = AppContext(
            bundleID: "",
            appName: "",
            windowTitle: ""
        )

        #expect(context.bundleID == "")
        #expect(context.appName == "")
        #expect(context.windowTitle == "")
    }

    // MARK: - AppContext Equatable

    @Test("Two identical contexts are equal")
    func contextEquality() {
        let a = AppContext(
            bundleID: "com.apple.Notes",
            appName: "Notes",
            windowTitle: "My Note",
            focusedFieldContent: "Hello",
            cursorPosition: 5
        )
        let b = AppContext(
            bundleID: "com.apple.Notes",
            appName: "Notes",
            windowTitle: "My Note",
            focusedFieldContent: "Hello",
            cursorPosition: 5
        )
        #expect(a == b)
    }

    @Test("Contexts with different bundle IDs are not equal")
    func contextInequalityBundleID() {
        let a = AppContext(bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "A")
        let b = AppContext(bundleID: "com.apple.mail", appName: "Notes", windowTitle: "A")
        #expect(a != b)
    }

    @Test("Contexts with different optional fields are not equal")
    func contextInequalityOptionalFields() {
        let a = AppContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Page",
            browserURL: "https://example.com"
        )
        let b = AppContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Page",
            browserURL: nil
        )
        #expect(a != b)
    }

    // MARK: - Mock Context Provider Simulates Context Reading

    @Test("Mock provider returns configured context for Slack")
    func mockProviderSlackContext() async {
        let slackContext = AppContext(
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: "#general — Workspace",
            focusedFieldContent: "typing a message",
            selectedText: nil,
            cursorPosition: 16
        )

        let provider = MockAppContextProvider(context: slackContext)
        let context = await provider.readContext()

        #expect(context.bundleID == "com.tinyspeck.slackmacgap")
        #expect(context.windowTitle == "#general — Workspace")
        #expect(context.focusedFieldContent == "typing a message")
        #expect(context.cursorPosition == 16)
    }

    @Test("Mock provider returns configured context for Safari with URL")
    func mockProviderSafariContext() async {
        let safariContext = AppContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Example Domain",
            browserURL: "https://example.com",
            focusedFieldContent: nil,
            selectedText: nil,
            cursorPosition: nil
        )

        let provider = MockAppContextProvider(context: safariContext)
        let context = await provider.readContext()

        #expect(context.bundleID == "com.apple.Safari")
        #expect(context.browserURL == "https://example.com")
        #expect(context.focusedFieldContent == nil)
    }

    @Test("Mock provider returns configured context for VS Code")
    func mockProviderVSCodeContext() async {
        let vsCodeContext = AppContext(
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            windowTitle: "main.swift — myproject",
            focusedFieldContent: "func hello() {\n    print(\"hi\")\n}",
            selectedText: "print(\"hi\")",
            cursorPosition: 29
        )

        let provider = MockAppContextProvider(context: vsCodeContext)
        let context = await provider.readContext()

        #expect(context.bundleID == "com.microsoft.VSCode")
        #expect(context.windowTitle == "main.swift — myproject")
        #expect(context.selectedText == "print(\"hi\")")
    }

    // MARK: - Mock Provider Tracks Calls

    @Test("Mock provider increments call count")
    func mockProviderCallCounting() async {
        let provider = MockAppContextProvider()

        #expect(provider.readContextCallCount == 0)
        _ = await provider.readContext()
        #expect(provider.readContextCallCount == 1)
        _ = await provider.readContext()
        #expect(provider.readContextCallCount == 2)
        _ = await provider.readContext()
        #expect(provider.readContextCallCount == 3)
    }

    @Test("Mock provider allows changing context between reads")
    func mockProviderContextSwitch() async {
        let provider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.TextEdit",
                appName: "TextEdit",
                windowTitle: "Document 1"
            ))

        let first = await provider.readContext()
        #expect(first.appName == "TextEdit")

        provider.stubbedContext = AppContext(
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: "#random"
        )

        let second = await provider.readContext()
        #expect(second.appName == "Slack")
        #expect(second.windowTitle == "#random")
    }

    // MARK: - Pipeline Integration with Mocks

    @Test("Pipeline reads context and injects text using mocks")
    func pipelineMockIntegration() async throws {
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.TextEdit",
                appName: "TextEdit",
                windowTitle: "Untitled",
                focusedFieldContent: "Hello",
                cursorPosition: 5
            ))
        let textInjector = MockTextInjector()

        // Simulate pipeline: read context, then inject text
        let context = await contextProvider.readContext()
        try await textInjector.inject(text: " world", into: context)

        #expect(contextProvider.readContextCallCount == 1)
        #expect(textInjector.injectionCount == 1)
        #expect(textInjector.lastInjectedText == " world")
        #expect(textInjector.injections.first?.context == context)
    }

    @Test("Pipeline reads context from browser app and injects text")
    func pipelineBrowserIntegration() async throws {
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.Safari",
                appName: "Safari",
                windowTitle: "Search Results",
                browserURL: "https://google.com/search?q=test",
                focusedFieldContent: "test",
                selectedText: "test",
                cursorPosition: 4
            ))
        let textInjector = MockTextInjector()

        let context = await contextProvider.readContext()

        // Verify browser URL is available
        #expect(context.browserURL != nil)
        #expect(BrowserURLReader.isBrowser(bundleID: context.bundleID))

        // Inject replacement text
        try await textInjector.inject(text: "replacement query", into: context)

        #expect(textInjector.injectionCount == 1)
        #expect(textInjector.lastInjectedText == "replacement query")
    }

    @Test("Pipeline handles context with no focused field gracefully")
    func pipelineNoFocusedField() async throws {
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.finder",
                appName: "Finder",
                windowTitle: "Documents"
            ))
        let textInjector = MockTextInjector()

        let context = await contextProvider.readContext()

        #expect(context.focusedFieldContent == nil)
        #expect(context.cursorPosition == nil)

        // Injection should still be attempted — the injector decides what to do
        try await textInjector.inject(text: "some text", into: context)
        #expect(textInjector.injectionCount == 1)
    }

    @Test("Pipeline handles multiple sequential injections")
    func pipelineMultipleInjections() async throws {
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.Notes",
                appName: "Notes",
                windowTitle: "Meeting Notes",
                focusedFieldContent: "",
                cursorPosition: 0
            ))
        let textInjector = MockTextInjector()

        // Simulate multiple dictation rounds
        for i in 1...3 {
            let context = await contextProvider.readContext()
            try await textInjector.inject(text: "Sentence \(i). ", into: context)
        }

        #expect(contextProvider.readContextCallCount == 3)
        #expect(textInjector.injectionCount == 3)
        #expect(textInjector.injections[0].text == "Sentence 1. ")
        #expect(textInjector.injections[1].text == "Sentence 2. ")
        #expect(textInjector.injections[2].text == "Sentence 3. ")
    }

    @Test("Pipeline with mock audio provider, context provider, and injector")
    func fullPipelineMockRoundTrip() async throws {
        // Set up all mock components
        let audioProvider = MockAudioProvider()
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.tinyspeck.slackmacgap",
                appName: "Slack",
                windowTitle: "#general",
                focusedFieldContent: "Hey ",
                cursorPosition: 4
            ))
        let textInjector = MockTextInjector()

        // Simulate full pipeline: activate → record + read context → complete → inject

        // Step 1: Start recording (capture track)
        try await audioProvider.startRecording()
        #expect(audioProvider.isRecording)

        // Step 2: Read context in parallel (context track)
        let context = await contextProvider.readContext()
        #expect(context.bundleID == "com.tinyspeck.slackmacgap")

        // Step 3: Stop recording (capture track)
        let buffer = try await audioProvider.stopRecording()
        #expect(!audioProvider.isRecording)
        #expect(buffer.duration > 0)

        // Step 4: Process audio → text (future STT, hardcoded for now)
        let transcribedText = "everyone, the meeting is at 3pm"

        // Step 5: Inject text (context track)
        try await textInjector.inject(text: transcribedText, into: context)

        #expect(textInjector.injectionCount == 1)
        #expect(textInjector.lastInjectedText == transcribedText)
        #expect(textInjector.injections.first?.context.bundleID == "com.tinyspeck.slackmacgap")
    }

    // MARK: - Concurrent Context Read and Audio Capture

    @Test("Context read and audio capture run concurrently")
    func concurrentContextAndAudio() async throws {
        let audioProvider = MockAudioProvider()
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.mail",
                appName: "Mail",
                windowTitle: "New Message",
                focusedFieldContent: "Dear ",
                cursorPosition: 5
            ))

        // Start both operations concurrently
        try await audioProvider.startRecording()

        async let contextRead = contextProvider.readContext()
        // Audio continues recording while context is read

        let context = await contextRead
        let buffer = try await audioProvider.stopRecording()

        #expect(context.bundleID == "com.apple.mail")
        #expect(buffer.duration > 0)
        #expect(audioProvider.startCallCount == 1)
        #expect(audioProvider.stopCallCount == 1)
        #expect(contextProvider.readContextCallCount == 1)
    }

    // MARK: - Context for Various App Types

    @Test("Context snapshot for a terminal app")
    func terminalContextSnapshot() {
        let context = AppContext(
            bundleID: "com.apple.Terminal",
            appName: "Terminal",
            windowTitle: "mrinal — zsh — 80×24"
        )

        #expect(context.bundleID == "com.apple.Terminal")
        #expect(context.browserURL == nil)
        #expect(!BrowserURLReader.isBrowser(bundleID: context.bundleID))
    }

    @Test("Context snapshot for an Electron app")
    func electronContextSnapshot() {
        let context = AppContext(
            bundleID: "com.hnc.Discord",
            appName: "Discord",
            windowTitle: "#voice-chat — Server Name",
            focusedFieldContent: "",
            cursorPosition: 0
        )

        #expect(context.bundleID == "com.hnc.Discord")
        #expect(context.focusedFieldContent == "")
        #expect(context.cursorPosition == 0)
    }

    @Test("Context correctly identifies Notion")
    func notionContextSnapshot() {
        let context = AppContext(
            bundleID: "notion.id",
            appName: "Notion",
            windowTitle: "Project Board",
            focusedFieldContent: "Task: ",
            cursorPosition: 6
        )

        #expect(context.bundleID == "notion.id")
        #expect(context.focusedFieldContent == "Task: ")
    }

    @Test("Context correctly identifies Obsidian")
    func obsidianContextSnapshot() {
        let context = AppContext(
            bundleID: "md.obsidian",
            appName: "Obsidian",
            windowTitle: "Daily Note",
            focusedFieldContent: "## Meeting Notes\n\n",
            cursorPosition: 19
        )

        #expect(context.bundleID == "md.obsidian")
        #expect(context.focusedFieldContent?.contains("Meeting Notes") == true)
    }
}
