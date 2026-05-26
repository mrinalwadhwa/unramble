import Foundation
import Testing

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Tests for the OpenAI Realtime API streaming dictation provider.
//
// Message-construction tests exercise the pure functions that build
// session.update, input_audio_buffer.append, and commit messages. Live
// integration tests (gated by FREEFLOW_TEST_OPENAI=1) open a real
// WebSocket to api.openai.com and run through the full streaming cycle.
// ---------------------------------------------------------------------------

// MARK: - Helpers

/// Build a short WAV containing a 1 kHz tone at 16 kHz mono.
private func toneWAV(seconds: Double = 1.0, sampleRate: Int = 16000) -> Data {
    let sampleCount = Int(seconds * Double(sampleRate))
    var pcm = Data(capacity: sampleCount * 2)
    for i in 0..<sampleCount {
        let t = Double(i) / Double(sampleRate)
        let value = Int16(3000.0 * sin(2.0 * .pi * 1000.0 * t))
        pcm.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }
    return pcm  // Raw PCM, not WAV — matches what AudioCaptureProvider emits.
}

/// Build a silent 16-bit mono PCM buffer at 16 kHz.
private func silentPCM(seconds: Double = 0.5, sampleRate: Int = 16000) -> Data {
    let sampleCount = Int(seconds * Double(sampleRate))
    return Data(count: sampleCount * 2)
}

// MARK: - Message Construction

@Suite("OpenAIStreamingProvider – message construction")
struct OpenAIRealtimeMessageTests {

    @Test("session.update has required transcription fields")
    func sessionUpdate() throws {
        let json = OpenAIStreamingProvider.buildSessionUpdate(
            sttModel: "gpt-realtime-whisper",
            language: "en",
            micProximity: .nearField)
        let data = json.data(using: .utf8)!
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["type"] as? String == "session.update")

        let session = try #require(obj["session"] as? [String: Any])
        #expect(session["type"] as? String == "realtime")

        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24000)

        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-realtime-whisper")
        #expect(transcription["language"] as? String == "en")

        // turn_detection must be NSNull so the server does not auto-commit.
        #expect(input["turn_detection"] is NSNull)
    }

    @Test("session.update omits language when nil")
    func sessionUpdateNoLanguage() throws {
        let json = OpenAIStreamingProvider.buildSessionUpdate(
            sttModel: "gpt-realtime-whisper",
            language: nil,
            micProximity: .farField)
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        let session = obj["session"] as! [String: Any]
        let audio = session["audio"] as! [String: Any]
        let input = audio["input"] as! [String: Any]
        let transcription = input["transcription"] as! [String: Any]
        #expect(transcription["language"] == nil)
    }

    @Test("session.update sets realtime type for far-field mic")
    func sessionUpdateFarField() throws {
        let json = OpenAIStreamingProvider.buildSessionUpdate(
            sttModel: "m", language: nil, micProximity: .farField)
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        let session = obj["session"] as! [String: Any]
        #expect(session["type"] as? String == "realtime")
    }

    @Test("audio append message contains base64 audio")
    func audioAppend() throws {
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        let json = OpenAIStreamingProvider.buildAudioAppend(pcm24k: pcm)
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        #expect(obj["type"] as? String == "input_audio_buffer.append")
        let audio = obj["audio"] as! String
        // Verify it decodes back to the original PCM.
        let decoded = try #require(Data(base64Encoded: audio))
        #expect(decoded == pcm)
    }

    @Test("commit message has correct type")
    func commit() throws {
        let json = OpenAIStreamingProvider.buildCommit()
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        #expect(obj["type"] as? String == "input_audio_buffer.commit")
    }

    @Test("websocket URL has model parameter")
    func websocketURL() {
        let url = OpenAIStreamingProvider.buildWebSocketURL(model: "gpt-realtime")
        #expect(url.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime")
    }

    @Test("websocket URL scheme is wss")
    func websocketURLScheme() {
        let url = OpenAIStreamingProvider.buildWebSocketURL(model: "m")
        #expect(url.scheme == "wss")
    }
}

// MARK: - Session Summary Formatting

@Suite("OpenAIStreamingProvider – session summary")
struct OpenAIRealtimeSessionSummaryTests {

    private func makeTiming(
        id: Int = 1,
        setupKind: OpenAIStreamingProvider.SessionTiming.SetupKind = .adoptedBackup
    ) -> OpenAIStreamingProvider.SessionTiming {
        OpenAIStreamingProvider.SessionTiming(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1000),
            setupKind: setupKind)
    }

    @Test("summary includes id and setup kind")
    func idAndSetup() {
        var t = makeTiming()
        t.endedAt = Date(timeIntervalSince1970: 1000.5)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("[RealtimeSession] id=1"))
        #expect(line.contains("setup=backup"))
        #expect(line.contains("total=0.500"))
    }

    @Test("fresh connection setup prints setup=fresh")
    func freshConnection() {
        var t = makeTiming(setupKind: .freshConnection)
        t.endedAt = Date(timeIntervalSince1970: 1000.1)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("setup=fresh"))
    }

    @Test("setup wait reported when setup completes")
    func setupWait() {
        var t = makeTiming()
        t.setupCompletedAt = Date(timeIntervalSince1970: 1000.050)
        t.endedAt = Date(timeIntervalSince1970: 1000.8)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("setup_wait=0.050"))
    }

    @Test("bytes and chunks reported when audio was sent")
    func bytesAndChunks() {
        var t = makeTiming()
        t.audioBytesSent = 96000
        t.audioChunksSent = 12
        t.endedAt = Date(timeIntervalSince1970: 1000.5)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("bytes=96000"))
        #expect(line.contains("chunks=12"))
    }

    @Test("commit-relative first_delta and transcript timings")
    func commitRelativeTimings() {
        var t = makeTiming()
        t.commitSentAt = Date(timeIntervalSince1970: 1001.000)
        t.firstDeltaAt = Date(timeIntervalSince1970: 1001.080)
        t.transcriptCompletedAt = Date(timeIntervalSince1970: 1001.350)
        t.endedAt = Date(timeIntervalSince1970: 1001.700)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("first_delta=0.080"))
        #expect(line.contains("transcript=0.350"))
    }

    @Test("polish field shows kind and duration")
    func polishField() {
        var t = makeTiming()
        t.polishStartedAt = Date(timeIntervalSince1970: 1001.000)
        t.polishKind = .llmOK
        t.polishFinishedAt = Date(timeIntervalSince1970: 1001.320)
        t.endedAt = Date(timeIntervalSince1970: 1001.500)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("polish=llm-ok(0.320)"))
    }

    @Test("polish=skip shown without duration when no LLM ran")
    func polishSkip() {
        var t = makeTiming()
        t.polishKind = .skip
        t.endedAt = Date(timeIntervalSince1970: 1000.5)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("polish=skip"))
        // Skip path does not record polishStartedAt/FinishedAt.
        #expect(!line.contains("polish=skip("))
    }

    @Test("error field escapes embedded quotes")
    func errorField() {
        var t = makeTiming()
        t.endedAt = Date(timeIntervalSince1970: 1000.5)
        t.error = "connection \"lost\" mid-session"
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("error=\"connection 'lost' mid-session\""))
    }
}

// MARK: - Transcript Timeout

@Suite("OpenAIStreamingProvider – transcript timeout")
struct OpenAIRealtimeTranscriptTimeoutTests {

    @Test("zero bytes uses the 15 s floor")
    func zeroBytes() {
        let t = OpenAIStreamingProvider.transcriptTimeout(forAudioBytes: 0)
        #expect(t == 15.0)
    }

    @Test("short dictation returns floor + scaled budget")
    func shortDictation() {
        // 5 seconds of 24 kHz 16-bit mono = 240_000 bytes.
        // Budget is max(15, 15 + 5 * 0.5) = 17.5 s.
        let t = OpenAIStreamingProvider.transcriptTimeout(forAudioBytes: 240_000)
        #expect(t == 17.5)
    }

    @Test("30 second dictation gets 30 second budget")
    func mediumDictation() {
        let t = OpenAIStreamingProvider.transcriptTimeout(forAudioBytes: 30 * 48_000)
        #expect(t == 30.0)
    }

    @Test("130 second dictation gets 80 second budget")
    func longDictation() {
        let t = OpenAIStreamingProvider.transcriptTimeout(forAudioBytes: 130 * 48_000)
        #expect(t == 80.0)
    }

    @Test("budget is capped at 300 seconds")
    func veryLongDictationCapped() {
        // 20 minute audio buffer, way beyond any realistic use.
        let t = OpenAIStreamingProvider.transcriptTimeout(
            forAudioBytes: 20 * 60 * 48_000)
        #expect(t == 300.0)
    }
}

// MARK: - Event Parsing

@Suite("OpenAIStreamingProvider – event parsing")
struct OpenAIRealtimeEventTests {

    @Test("parses transcription.completed event")
    func transcriptionCompleted() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.completed",
             "transcript":"hello world"}
            """
        let parsed = OpenAIStreamingProvider.parseEvent(event)
        if case .transcriptionCompleted(let transcript) = parsed {
            #expect(transcript == "hello world")
        } else {
            Issue.record("expected transcriptionCompleted, got \(parsed)")
        }
    }

    @Test("parses transcription.delta event")
    func transcriptionDelta() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.delta",
             "delta":"hel"}
            """
        let parsed = OpenAIStreamingProvider.parseEvent(event)
        if case .transcriptionDelta(let delta) = parsed {
            #expect(delta == "hel")
        } else {
            Issue.record("expected transcriptionDelta, got \(parsed)")
        }
    }

    @Test("parses error event")
    func errorEvent() {
        let event = """
            {"type":"error","error":{"message":"bad audio","code":"invalid_audio"}}
            """
        let parsed = OpenAIStreamingProvider.parseEvent(event)
        if case .error(let message) = parsed {
            #expect(message.contains("bad audio"))
        } else {
            Issue.record("expected error, got \(parsed)")
        }
    }

    @Test("ignores unknown event types")
    func ignoresUnknown() {
        let event = #"{"type":"session.created","session":{}}"#
        let parsed = OpenAIStreamingProvider.parseEvent(event)
        if case .other = parsed {
            // Expected.
        } else {
            Issue.record("expected other, got \(parsed)")
        }
    }

    @Test("returns other for malformed JSON")
    func malformedJSON() {
        let parsed = OpenAIStreamingProvider.parseEvent("not json")
        if case .other = parsed {
            // Expected.
        } else {
            Issue.record("expected other, got \(parsed)")
        }
    }

    @Test("transcription.completed with empty transcript")
    func emptyTranscript() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.completed",
             "transcript":""}
            """
        let parsed = OpenAIStreamingProvider.parseEvent(event)
        if case .transcriptionCompleted(let transcript) = parsed {
            #expect(transcript == "")
        } else {
            Issue.record("expected transcriptionCompleted, got \(parsed)")
        }
    }
}

// MARK: - Live Integration (gated)

@Suite(
    "OpenAIStreamingProvider – live",
    .disabled(if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI"] != "1"))
struct OpenAIRealtimeLiveTests {

    private var apiKey: String {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    @Test("live: open, send silent audio, commit, close")
    func liveSilentSession() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let provider = OpenAIStreamingProvider(
            apiKey: apiKey, polishChatClient: nil)
        try await provider.startStreaming(
            context: AppContext.empty,
            language: "en",
            micProximity: .nearField)
        // Feed half a second of silent audio.
        let pcm = silentPCM(seconds: 0.5)
        try await provider.sendAudio(pcm)
        // finishStreaming commits and returns the transcript (likely empty).
        _ = try await provider.finishStreaming()
        await provider.cancelStreaming()
    }

    @Test("live: tone signal returns a response")
    func liveToneSession() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let provider = OpenAIStreamingProvider(
            apiKey: apiKey, polishChatClient: nil)
        try await provider.startStreaming(
            context: AppContext.empty,
            language: "en",
            micProximity: .farField)
        let pcm = toneWAV(seconds: 1.0)
        try await provider.sendAudio(pcm)
        _ = try await provider.finishStreaming()
        await provider.cancelStreaming()
    }
}

// MARK: - Concurrent cancel safety (H3/H4)

@Suite("OpenAIStreamingProvider – concurrent cancel safety")
struct ConcurrentCancelSafetyTests {

    @Test("concurrent cancelStreaming calls do not crash")
    func concurrentCancel() async {
        let provider = OpenAIStreamingProvider(
            apiKey: "sk-test", polishChatClient: nil)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await provider.cancelStreaming() }
            }
        }
        // If we get here without crashing, the lock discipline is correct.
    }

    @Test("concurrent disconnect calls do not crash")
    func concurrentDisconnect() async {
        let provider = OpenAIStreamingProvider(
            apiKey: "sk-test", polishChatClient: nil)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await provider.disconnect() }
            }
        }
    }
}
