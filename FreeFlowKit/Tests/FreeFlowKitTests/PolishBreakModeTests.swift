import Foundation
import Testing

@testable import FreeFlowKit

// Break handling in PolishPipeline.polish, exercised with mock clients so
// it runs deterministically under `swift test` (no model needed).
//
// commandsOnly (streaming per-chunk): breaks come ONLY from dictated
// "new paragraph"/"new line" commands, inserted deterministically by
// splitting and rejoining — never from the model. expandBeforeModel
// (whole-transcript): the model's own paragraphing is kept.

@Suite("Polish break modes")
struct PolishBreakModeTests {

    @Test("commandsOnly maps a dictated paragraph to exactly one break")
    func commandsOnlyOneBreak() async throws {
        let out = await PolishPipeline.polish(
            "first point new paragraph second point",
            chatClient: EchoClient(), breakMode: .commandsOnly)

        #expect(out.components(separatedBy: "\n\n").count == 2,
            "expected one paragraph break, got: \(out.debugDescription)")
        #expect(!out.contains("\n\n\n"))
        // Second segment starts a fresh paragraph → capitalized.
        let after = out.components(separatedBy: "\n\n").last ?? ""
        #expect(after.hasPrefix("Second"),
            "second paragraph not capitalized: \(after.debugDescription)")
    }

    @Test("commandsOnly maps a dictated new line to a single newline")
    func commandsOnlyNewLine() async throws {
        let out = await PolishPipeline.polish(
            "first line new line second line",
            chatClient: EchoClient(), breakMode: .commandsOnly)

        #expect(out.contains("\n"))
        #expect(!out.contains("\n\n"),
            "new line must be a single break: \(out.debugDescription)")
    }

    @Test("commandsOnly strips a break the model invents")
    func commandsOnlyStripsModelBreak() async throws {
        // No command in the input, but the model injects a paragraph break.
        let out = await PolishPipeline.polish(
            "the server is fine the dashboard is clean",
            chatClient: BreakInjectingClient(), breakMode: .commandsOnly)

        #expect(!out.contains("\n"),
            "model-invented break should be stripped: \(out.debugDescription)")
    }

    @Test("expandBeforeModel keeps a break the model produces")
    func expandKeepsModelBreak() async throws {
        // Same injecting model, but whole-transcript mode keeps its break.
        let out = await PolishPipeline.polish(
            "the server is fine the dashboard is clean",
            chatClient: BreakInjectingClient(), breakMode: .expandBeforeModel)

        #expect(out.contains("\n"),
            "expandBeforeModel should keep the model break: \(out.debugDescription)")
    }

    @Test("commandsOnly drops a stray terminator after a command")
    func commandsOnlyNoStrayPeriod() async throws {
        // Recognizer left a period right after the spoken "new paragraph".
        let out = await PolishPipeline.polish(
            "we are done new paragraph. next steps follow",
            chatClient: EchoClient(), breakMode: .commandsOnly)

        let paras = out.components(separatedBy: "\n\n")
        #expect(paras.count == 2)
        let second = paras.last ?? ""
        #expect(!second.hasPrefix("."),
            "stray period leaked into second paragraph: \(second.debugDescription)")
        #expect(second.hasPrefix("Next"),
            "second paragraph should start at the real word: \(second.debugDescription)")
    }
}

/// Returns the model input unchanged (a model that improves nothing).
private final class EchoClient: PolishChatClient, @unchecked Sendable {
    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String { userPrompt }
}

/// Echoes the input but injects a paragraph break at the first space,
/// simulating a model that over-breaks a single committed sentence.
private final class BreakInjectingClient: PolishChatClient, @unchecked Sendable {
    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        guard let r = userPrompt.range(of: " ") else { return userPrompt }
        return userPrompt.replacingCharacters(in: r, with: "\n\n")
    }
}
