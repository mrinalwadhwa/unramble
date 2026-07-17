import Foundation
import Testing

@testable import UnrambleKit

@Suite("Injection strategy selection")
struct StrategySelectionTests {

    // MARK: - Native macOS Apps Prefer Accessibility

    @Test("TextEdit prefers accessibility strategy")
    func textEditStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.apple.TextEdit")
        #expect(strategies.first == .accessibility)
        #expect(strategies.contains(.pasteboard))
    }

    @Test("Notes prefers accessibility strategy")
    func notesStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.apple.Notes")
        #expect(strategies.first == .accessibility)
        #expect(strategies.contains(.pasteboard))
    }

    @Test("Mail prefers accessibility strategy")
    func mailStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.apple.mail")
        #expect(strategies.first == .accessibility)
    }

    @Test("Xcode prefers accessibility strategy")
    func xcodeStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.apple.dt.Xcode")
        #expect(strategies.first == .accessibility)
    }

    // MARK: - Terminal Apps Prefer Pasteboard

    @Test("Terminal prefers pasteboard strategy")
    func terminalStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.apple.Terminal")
        #expect(strategies.first == .pasteboard)
        #expect(!strategies.contains(.accessibility))
    }

    @Test("iTerm2 prefers pasteboard strategy")
    func iterm2Strategy() {
        let strategies = AppTextInjector.strategies(for: "com.googlecode.iterm2")
        #expect(strategies.first == .pasteboard)
    }

    // MARK: - Electron Apps Prefer Pasteboard

    @Test("Slack prefers pasteboard strategy")
    func slackStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.tinyspeck.slackmacgap")
        #expect(strategies.first == .pasteboard)
    }

    @Test("VS Code prefers pasteboard strategy")
    func vsCodeStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.microsoft.VSCode")
        #expect(strategies.first == .pasteboard)
    }

    @Test("Discord prefers pasteboard strategy")
    func discordStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.hnc.Discord")
        #expect(strategies.first == .pasteboard)
    }

    @Test("Notion prefers pasteboard strategy")
    func notionStrategy() {
        let strategies = AppTextInjector.strategies(for: "notion.id")
        #expect(strategies.first == .pasteboard)
    }

    @Test("Obsidian prefers pasteboard strategy")
    func obsidianStrategy() {
        let strategies = AppTextInjector.strategies(for: "md.obsidian")
        #expect(strategies.first == .pasteboard)
    }

    // MARK: - Browsers Prefer Pasteboard

    @Test("Safari prefers pasteboard strategy")
    func safariStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.apple.Safari")
        #expect(strategies.first == .pasteboard)
    }

    @Test("Chrome prefers pasteboard strategy")
    func chromeStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.google.Chrome")
        #expect(strategies.first == .pasteboard)
    }

    @Test("Edge prefers pasteboard strategy")
    func edgeStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.microsoft.edgemac")
        #expect(strategies.first == .pasteboard)
    }

    @Test("Brave prefers pasteboard strategy")
    func braveStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.brave.Browser")
        #expect(strategies.first == .pasteboard)
    }

    @Test("Arc prefers pasteboard strategy")
    func arcStrategy() {
        let strategies = AppTextInjector.strategies(for: "company.thebrowser.Browser")
        #expect(strategies.first == .pasteboard)
    }

    @Test("Firefox prefers pasteboard with keystroke fallback")
    func firefoxStrategy() {
        let strategies = AppTextInjector.strategies(for: "org.mozilla.firefox")
        #expect(strategies.first == .pasteboard)
        #expect(strategies.contains(.keystroke))
        #expect(!strategies.contains(.accessibility))
    }

    // MARK: - Messages

    @Test("Messages prefers pasteboard strategy")
    func messagesStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.apple.MobileSMS")
        #expect(strategies.first == .pasteboard)
    }

    // MARK: - Unknown Apps Use Default Order

    @Test("Unknown app uses default strategy order")
    func unknownAppStrategy() {
        let strategies = AppTextInjector.strategies(for: "com.example.UnknownApp")
        #expect(strategies == [.accessibility, .pasteboard, .keystroke])
    }

    @Test("Empty bundle ID uses default strategy order")
    func emptyBundleIDStrategy() {
        let strategies = AppTextInjector.strategies(for: "")
        #expect(strategies == [.accessibility, .pasteboard, .keystroke])
    }

    // MARK: - Strategy Lists Are Non-Empty

    @Test("Every mapped app has at least one strategy")
    func allStrategiesNonEmpty() {
        let bundleIDs = [
            "com.apple.TextEdit",
            "com.apple.Notes",
            "com.apple.mail",
            "com.apple.dt.Xcode",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.tinyspeck.slackmacgap",
            "com.microsoft.VSCode",
            "com.hnc.Discord",
            "notion.id",
            "md.obsidian",
            "com.apple.Safari",
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "com.apple.MobileSMS",
        ]

        for bundleID in bundleIDs {
            let strategies = AppTextInjector.strategies(for: bundleID)
            #expect(!strategies.isEmpty, "Strategy list for \(bundleID) must not be empty")
        }
    }

    // MARK: - No Duplicate Strategies

    @Test("Default strategies contain no duplicates")
    func defaultStrategiesNoDuplicates() {
        let strategies = AppTextInjector.strategies(for: "com.example.Unknown")
        let unique = Set(strategies)
        #expect(strategies.count == unique.count)
    }
}
