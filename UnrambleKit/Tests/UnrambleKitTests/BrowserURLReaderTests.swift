import Foundation
import Testing

@testable import UnrambleKit

@Suite("Browser URL reader")
struct BrowserURLReaderTests {

    // MARK: - Known Browsers

    @Test("Safari is a browser")
    func safariIsBrowser() {
        #expect(BrowserURLReader.isBrowser(bundleID: "com.apple.Safari"))
    }

    @Test("Safari Technology Preview is a browser")
    func safariTPIsBrowser() {
        #expect(BrowserURLReader.isBrowser(bundleID: "com.apple.SafariTechnologyPreview"))
    }

    @Test("Chrome is a browser")
    func chromeIsBrowser() {
        #expect(BrowserURLReader.isBrowser(bundleID: "com.google.Chrome"))
    }

    @Test("Chrome Canary is a browser")
    func chromeCanaryIsBrowser() {
        #expect(BrowserURLReader.isBrowser(bundleID: "com.google.Chrome.canary"))
    }

    @Test("Edge is a browser")
    func edgeIsBrowser() {
        #expect(BrowserURLReader.isBrowser(bundleID: "com.microsoft.edgemac"))
    }

    @Test("Brave is a browser")
    func braveIsBrowser() {
        #expect(BrowserURLReader.isBrowser(bundleID: "com.brave.Browser"))
    }

    @Test("Arc is a browser")
    func arcIsBrowser() {
        #expect(BrowserURLReader.isBrowser(bundleID: "company.thebrowser.Browser"))
    }

    @Test("Firefox is a browser")
    func firefoxIsBrowser() {
        #expect(BrowserURLReader.isBrowser(bundleID: "org.mozilla.firefox"))
    }

    @Test("Firefox Developer Edition is a browser")
    func firefoxDevIsBrowser() {
        #expect(BrowserURLReader.isBrowser(bundleID: "org.mozilla.firefoxdeveloperedition"))
    }

    // MARK: - Non-Browsers

    @Test("TextEdit is not a browser")
    func textEditIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: "com.apple.TextEdit"))
    }

    @Test("Terminal is not a browser")
    func terminalIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: "com.apple.Terminal"))
    }

    @Test("Slack is not a browser")
    func slackIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: "com.tinyspeck.slackmacgap"))
    }

    @Test("VS Code is not a browser")
    func vsCodeIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: "com.microsoft.VSCode"))
    }

    @Test("Xcode is not a browser")
    func xcodeIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: "com.apple.dt.Xcode"))
    }

    @Test("Notes is not a browser")
    func notesIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: "com.apple.Notes"))
    }

    @Test("Mail is not a browser")
    func mailIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: "com.apple.mail"))
    }

    @Test("Discord is not a browser")
    func discordIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: "com.hnc.Discord"))
    }

    @Test("Empty bundle ID is not a browser")
    func emptyBundleIDIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: ""))
    }

    @Test("Unknown app is not a browser")
    func unknownAppIsNotBrowser() {
        #expect(!BrowserURLReader.isBrowser(bundleID: "com.example.UnknownApp"))
    }

    // MARK: - readURL Returns nil for Non-Browsers

    @Test("readURL returns nil for non-browser bundle ID")
    func readURLReturnsNilForNonBrowser() {
        let url = BrowserURLReader.readURL(bundleID: "com.apple.TextEdit", pid: 1)
        #expect(url == nil)
    }

    @Test("readURL returns nil for empty bundle ID")
    func readURLReturnsNilForEmptyBundleID() {
        let url = BrowserURLReader.readURL(bundleID: "", pid: 1)
        #expect(url == nil)
    }
}
