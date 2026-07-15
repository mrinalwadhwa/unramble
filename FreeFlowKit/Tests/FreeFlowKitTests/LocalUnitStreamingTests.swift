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

    /// PCM of constant-amplitude samples; RMS is `abs(value) / 32768`.
    private func tone(_ value: Int16, bytes: Int) -> Data {
        let samples = [Int16](repeating: value, count: bytes / 2)
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

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

    @Test("A hard pause resets recognition and preserves content across resets")
    func hardPauseResetsAndPreservesContent() async throws {
        let recognizer = MultiSessionRecognizer([
            "first unit alpha", "second unit bravo", "unused",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: recognizer,
            polishChatClient: EchoPolishClient(),
            cycleInterval: 100.0 / Double(LocalUnitPolicy.sourceBytesPerSecond),
            unitPolicy: LocalUnitPolicy(
                minimumSpeechBytes: 100, softPauseSilenceBytes: 40,
                hardPauseSilenceBytes: 80, maximumUnitBytes: 1_000_000),
            silenceThreshold: 0.01)

        // speech, hard pause, speech, hard pause: two units, two resets.
        let audio = speech(200) + silence(100) + speech(200) + silence(100)
        let result = try await provider.replayCapturedAudio(
            audio,
            sessionID: DictationSessionID(),
            context: .empty,
            language: nil,
            micProximity: .farField,
            silenceThreshold: 0.01)

        // One fresh session per hard pause, plus the initial session. Discarding
        // the old sessions is what bounds memory on a long dictation.
        #expect(recognizer.sessionCount == 3)
        // Content on both sides of the resets survives.
        #expect(result.lowercased().contains("alpha"))
        #expect(result.lowercased().contains("bravo"))
    }

    @Test("A size-cap close does not reset recognition")
    func sizeCapCloseDoesNotReset() async throws {
        let recognizer = MultiSessionRecognizer(["only unit charlie"])
        let provider = LocalStreamingProvider(
            sttEngine: recognizer,
            polishChatClient: EchoPolishClient(),
            cycleInterval: 100.0 / Double(LocalUnitPolicy.sourceBytesPerSecond),
            unitPolicy: LocalUnitPolicy(
                minimumSpeechBytes: 2, softPauseSilenceBytes: 2,
                hardPauseSilenceBytes: 4, maximumUnitBytes: 100),
            silenceThreshold: 0.01)

        // Continuous speech, no pause: units close at the size cap, which is
        // not a safe reset point, so the session is never rebuilt.
        let result = try await provider.replayCapturedAudio(
            speech(400),
            sessionID: DictationSessionID(),
            context: .empty,
            language: nil,
            micProximity: .farField,
            silenceThreshold: 0.01)

        #expect(recognizer.sessionCount == 1)
        #expect(result.lowercased().contains("charlie"))
    }

    @Test("setSilenceThreshold makes low-energy audio count as a pause")
    func silenceThresholdControlsPauseDetection() async throws {
        func make() -> (LocalStreamingProvider, MultiSessionRecognizer) {
            let recognizer = MultiSessionRecognizer(["unit one", "unit two"])
            let provider = LocalStreamingProvider(
                sttEngine: recognizer,
                polishChatClient: EchoPolishClient(),
                unitPolicy: LocalUnitPolicy(
                    minimumSpeechBytes: 640, softPauseSilenceBytes: 640,
                    hardPauseSilenceBytes: 640, maximumUnitBytes: 1_000_000),
                silenceThreshold: 0.0005)
            return (provider, recognizer)
        }
        // Loud speech, then low-energy audio (~0.006 RMS) that reads as a pause
        // only above a ~0.006 threshold. One 640-byte step is one 20 ms window.
        let audio = tone(8000, bytes: 1280) + tone(200, bytes: 1280)

        // At the speech floor the low-energy tail is not silence: no pause.
        let (low, lowRec) = make()
        _ = try await low.replay(audio: audio, stepBytes: 640)
        #expect(lowRec.sessionCount == 1)

        // A higher threshold classifies the tail as a pause, which closes a
        // unit and resets recognition.
        let (high, highRec) = make()
        high.setSilenceThreshold(0.02)
        _ = try await high.replay(audio: audio, stepBytes: 640)
        #expect(highRec.sessionCount == 2)
    }

    @Test("a sentence split across a unit boundary is stitched back whole")
    func carryStitchesSplitSentence() async throws {
        let recognizer = ScriptRecognizer([
            "the plan is", "the plan is", "the plan is",
            "the plan is to ship on friday", "the plan is to ship on friday",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: recognizer,
            polishChatClient: SentenceFinalizingClient(),
            unitPolicy: LocalUnitPolicy(
                minimumSpeechBytes: 100, softPauseSilenceBytes: 40,
                hardPauseSilenceBytes: 100_000, maximumUnitBytes: 1_000_000),
            silenceThreshold: 0.01)
        // Speech, a mid-sentence pause (closes unit 1), then the rest.
        let audio = speech(200) + silence(100) + speech(200)
        let result = try await provider.replay(audio: audio, stepBytes: 100)

        #expect(result.lowercased().contains("the plan is to ship on friday"))
        #expect(!result.contains(". To ship"),
            "split sentence was not stitched: \(result.debugDescription)")
        #expect(!result.contains("is. "),
            "spurious mid-sentence period: \(result.debugDescription)")
    }

    @Test("a held sentence is committed when dictation ends at a pause")
    func carryCommittedAtFinish() async throws {
        let recognizer = ScriptRecognizer([
            "the plan is ready", "the plan is ready", "the plan is ready",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: recognizer,
            polishChatClient: SentenceFinalizingClient(),
            unitPolicy: LocalUnitPolicy(
                minimumSpeechBytes: 100, softPauseSilenceBytes: 40,
                hardPauseSilenceBytes: 100_000, maximumUnitBytes: 1_000_000),
            silenceThreshold: 0.01)
        // The pause closes the unit; finish has no further audio and must
        // still commit the held sentence.
        let audio = speech(200) + silence(100)
        let result = try await provider.replay(audio: audio, stepBytes: 100)

        #expect(result.lowercased().contains("the plan is ready"))
    }

    @Test("a break command split across a unit boundary still converts")
    func breakCommandSplitAcrossBoundaryConverts() async throws {
        // The unit closes just after "new" is recognized but before "line";
        // the model drops the orphaned "new," so unless the boundary holds it
        // back, "new line" ships as a literal "line" with no break.
        let recognizer = ScriptRecognizer([
            "finalize the pricing page new",
            "finalize the pricing page new",
            "finalize the pricing page new",
            "finalize the pricing page new line set up the dashboards",
            "finalize the pricing page new line set up the dashboards",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: recognizer,
            polishChatClient: DropTrailingNewClient(),
            unitPolicy: LocalUnitPolicy(
                minimumSpeechBytes: 100, softPauseSilenceBytes: 40,
                hardPauseSilenceBytes: 100_000, maximumUnitBytes: 1_000_000),
            silenceThreshold: 0.01)
        // Speech, a pause right after "new" (closes unit 1), then the rest.
        let audio = speech(200) + silence(100) + speech(200)
        let result = try await provider.replay(audio: audio, stepBytes: 100)

        #expect(result.contains("\n"),
            "the break command produced no line break: \(result.debugDescription)")
        #expect(!result.lowercased().contains("line"),
            "the command word leaked as literal text: \(result.debugDescription)")
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

/// Finalizes its input as one sentence — capitalize the first letter, end with
/// a period — the way the real model terminates whatever fragment it is given.
private final class SentenceFinalizingClient: PolishChatClient, @unchecked Sendable {
    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        let trimmed = userPrompt
            .replacingOccurrences(
                of: #"[.!?]+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + String(trimmed.dropFirst()) + "."
    }
}

/// Drops a trailing bare "new" the way the real model discards a dangling
/// incomplete word at a unit boundary — the behavior that split a "new line"
/// command across two units in real dictation.
private final class DropTrailingNewClient: PolishChatClient, @unchecked Sendable {
    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        userPrompt.replacingOccurrences(
            of: #"\s*\bnew\s*$"#, with: "",
            options: [.regularExpression, .caseInsensitive])
    }
}

/// Hands each fresh session the next scripted transcript, so a test can see
/// how many sessions were created and that content continues across resets.
private final class MultiSessionRecognizer: LocalStreamingRecognizer, @unchecked Sendable {
    let name = "MultiSessionRecognizer"
    var isReady = true

    private let lock = NSLock()
    private let scripts: [String]
    private var created = 0

    init(_ scripts: [String]) { self.scripts = scripts }

    var sessionCount: Int { lock.withLock { created } }

    func load() async throws {}
    func makeRecognitionSession() throws -> any LocalRecognitionSession {
        let script = lock.withLock { () -> String in
            let index = min(created, scripts.count - 1)
            created += 1
            return scripts.isEmpty ? "" : scripts[index]
        }
        return FixedSession(transcript: script)
    }
}

/// A session that returns one fixed transcript once it has been fed.
private final class FixedSession: LocalRecognitionSession {
    private let text: String
    private var fed = false

    init(transcript: String) { self.text = transcript }

    func feed(_ samples: [Float]) throws { fed = true }
    func transcript() -> String { fed ? text : "" }
    func finish() throws -> String { fed ? text : "" }
}
