import Foundation
import Testing

@testable import FreeFlowKit

// The on-device provider closes bounded pause/size units, polishes each, and
// accumulates them internally. Nothing is injected mid-stream: the whole
// polished transcript is returned once at finish, whether or not a preview
// handler is set.
@Suite("Local unit streaming")
struct LocalUnitStreamingTests {

    private func speech(_ bytes: Int) -> Data { Data(repeating: 0x40, count: bytes) }
    private func silence(_ bytes: Int) -> Data { Data(repeating: 0, count: bytes) }

    private func makeProvider(_ transcripts: [String]) -> LocalStreamingProvider {
        LocalStreamingProvider(
            sttEngine: ScriptRecognizer(transcripts),
            polishChatClient: EchoPolishClient(),
            unitPolicy: LocalUnitPolicy(
                minimumSpeechBytes: 100, softPauseSilenceBytes: 40,
                hardPauseSilenceBytes: 200, maximumUnitBytes: 1_000_000),
            silenceThreshold: 0.01)
    }

    @Test("finish returns the full transcript whether or not a preview handler is set")
    func finishReturnsFullRegardlessOfHandler() async throws {
        // Five 100-byte steps: speech, speech, silence, speech, speech.
        // The silence step closes the first unit; finish closes the second.
        let transcripts = [
            "first part", "first part", "first part",
            "first part second part", "first part second part",
        ]
        let audio = speech(100) + speech(100) + silence(100)
            + speech(100) + speech(100)

        let withHandler = makeProvider(transcripts)
        withHandler.setChunkHandler { _ in }
        let a = try await withHandler.replay(audio: audio, stepBytes: 100)

        let without = makeProvider(transcripts)
        let b = try await without.replay(audio: audio, stepBytes: 100)

        #expect(a == b, "a preview handler must not change the returned text")
        #expect(a.lowercased().contains("first part"))
        #expect(a.lowercased().contains("second part"))
    }
}

/// A recognizer whose session returns a scripted transcript indexed by the
/// number of feeds so far.
private final class ScriptRecognizer: LocalStreamingRecognizer, @unchecked Sendable {
    let name = "ScriptRecognizer"
    var isReady = true
    private let transcripts: [String]

    init(_ transcripts: [String]) { self.transcripts = transcripts }

    func load() async throws {}
    func makeRecognitionSession() throws -> any LocalRecognitionSession {
        ScriptSession(transcripts)
    }
}

private final class ScriptSession: LocalRecognitionSession {
    private let transcripts: [String]
    private var feeds = 0

    init(_ transcripts: [String]) { self.transcripts = transcripts }

    func feed(_ samples: [Float]) throws { feeds += 1 }
    func transcript() -> String {
        guard feeds > 0, !transcripts.isEmpty else { return "" }
        return transcripts[min(feeds - 1, transcripts.count - 1)]
    }
    func finish() throws -> String { transcript() }
}

/// Returns the model input unchanged (a polish that improves nothing).
private final class EchoPolishClient: PolishChatClient, @unchecked Sendable {
    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String { userPrompt }
}
