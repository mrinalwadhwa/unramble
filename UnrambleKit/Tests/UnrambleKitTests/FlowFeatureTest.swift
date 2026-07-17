import Testing
import Foundation
@testable import UnrambleKit

/// Compare Unramble pipeline against Wispr Flow feature set.
/// Runs preprocessing only (no model) to verify pipeline behavior.
@Suite("Flow Feature Comparison — Pipeline Only")
struct FlowFeaturePipelineTest {

    private func pipeline(_ input: String) -> (substituted: String, stripped: String) {
        let substituted = PolishPipeline.substituteDictatedPunctuation(input)
        let stripped = PolishPipeline.stripKeepTags(substituted)
        return (substituted, stripped)
    }

    // MARK: - Dictated Punctuation

    @Test("exclamation + question mark")
    func exclamationAndQuestion() {
        let (sub, _) = pipeline(
            "I can't wait to see you exclamation point When do we meet question mark")
        #expect(sub.contains("!"), "exclamation: \(sub)")
        #expect(sub.contains("?"), "question: \(sub)")
    }

    @Test("asterisk spacing")
    func asterisk() {
        let (sub, stripped) = pipeline("use asterisk bold asterisk for emphasis")
        print("  substituted: [\(sub)]")
        print("  stripped:     [\(stripped)]")
        // Check if asterisks are present
        #expect(sub.contains("*"), "asterisk missing: \(sub)")
    }

    @Test("backslash")
    func backslash() {
        let (sub, stripped) = pipeline(
            "the path is C backslash users backslash documents")
        print("  substituted: [\(sub)]")
        print("  stripped:     [\(stripped)]")
        #expect(sub.contains("\\"), "backslash missing: \(sub)")
    }

    @Test("new line")
    func newLine() {
        let (sub, stripped) = pipeline(
            "when is reading club new line should be tomorrow")
        print("  substituted: [\(sub)]")
        print("  stripped:     [\(stripped)]")
        #expect(sub.contains("\n") || sub.contains("\u{21b5}") || sub.contains("<keep>"),
            "newline missing: \(sub)")
    }

    @Test("new paragraph")
    func newParagraph() {
        let (sub, stripped) = pipeline(
            "first paragraph new paragraph second paragraph")
        print("  substituted: [\(sub)]")
        print("  stripped:     [\(stripped)]")
    }

    @Test("minus sign")
    func minus() {
        let (sub, stripped) = pipeline("the temperature is minus ten degrees")
        print("  substituted: [\(sub)]")
        print("  stripped:     [\(stripped)]")
    }

    @Test("all symbols")
    func allSymbols() {
        let cases: [(String, String, String)] = [
            ("ampersand", "R ampersand D", "&"),
            ("at sign", "john at sign example", "@"),
            ("hashtag", "check hashtag trending", "#"),
            ("forward slash", "input forward slash output", "/"),
            ("backslash", "C backslash users", "\\"),
            ("asterisk", "asterisk bold asterisk", "*"),
            ("underscore", "max underscore value", "_"),
            ("percent sign", "fifty percent sign", "%"),
            ("dollar sign", "dollar sign fifty", "$"),
            ("equals sign", "x equals sign five", "="),
            ("plus sign", "two plus sign three", "+"),
            ("ellipsis", "wait ellipsis okay", "\u{2026}"),
            ("dot dot dot", "and then dot dot dot", "\u{2026}"),
            ("open paren", "func open paren x close paren", "("),
            ("open quote", "she said open quote hello close quote", "\u{201c}"),
        ]
        for (name, input, expected) in cases {
            let (sub, stripped) = pipeline(input)
            let has = sub.contains(expected) || stripped.contains(expected)
            print("  \(name): [\(stripped)] — \(has ? "✓" : "✗")")
            #expect(has, "\(name) missing from: \(stripped)")
        }
    }
}
