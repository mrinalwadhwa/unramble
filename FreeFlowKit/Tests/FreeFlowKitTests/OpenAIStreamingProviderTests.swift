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

    private var context: AppContext {
        AppContext(
            bundleID: "com.apple.mail",
            appName: "Mail",
            windowTitle: "Reply",
            focusedFieldContent: "Thanks for sending the draft.")
    }

    @Test("session.update configures transcription and response polish")
    func sessionUpdate() throws {
        let json = OpenAIStreamingProvider.buildSessionUpdate(
            sttModel: "gpt-4o-mini-transcribe",
            language: "en",
            context: context)
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
        #expect(transcription["model"] as? String == "gpt-4o-mini-transcribe")
        #expect(transcription["language"] as? String == "en")

        // turn_detection must be NSNull so the server does not auto-commit.
        #expect(input["turn_detection"] is NSNull)

        #expect(
            session["instructions"] as? String
                == PolishPipeline.buildCloudSystemPrompt(
                    context: context, language: "en"))
        let reasoning = try #require(session["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "minimal")
    }

    @Test("session.update omits language when nil")
    func sessionUpdateNoLanguage() throws {
        let json = OpenAIStreamingProvider.buildSessionUpdate(
            sttModel: "gpt-4o-mini-transcribe",
            language: nil,
            context: .empty)
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        let session = obj["session"] as! [String: Any]
        let audio = session["audio"] as! [String: Any]
        let input = audio["input"] as! [String: Any]
        let transcription = input["transcription"] as! [String: Any]
        #expect(transcription["language"] == nil)
    }

    @Test("session.update carries preceding text into instructions")
    func sessionUpdateContext() throws {
        let json = OpenAIStreamingProvider.buildSessionUpdate(
            sttModel: "m", language: "en", context: context)
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        let session = obj["session"] as! [String: Any]
        let instructions = try #require(session["instructions"] as? String)
        #expect(instructions.contains("Preceding text: Thanks for sending the draft."))
    }

    @Test("polish request preserves the transcript exactly")
    func polishRequest() throws {
        let transcript = "hello, quote \"this\"\nthen continue"
        let json = OpenAIStreamingProvider.buildPolishRequest(
            transcript: transcript)
        let obj = try #require(
            try JSONSerialization.jsonObject(
                with: json.data(using: .utf8)!) as? [String: Any])
        #expect(obj["type"] as? String == "conversation.item.create")

        let item = try #require(obj["item"] as? [String: Any])
        #expect(item["type"] as? String == "message")
        #expect(item["role"] as? String == "user")
        let content = try #require(item["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == transcript)
    }

    @Test("response.create requests text output")
    func responseCreate() throws {
        let json = OpenAIStreamingProvider.buildResponseCreate()
        let obj = try #require(
            try JSONSerialization.jsonObject(
                with: json.data(using: .utf8)!) as? [String: Any])
        #expect(obj["type"] as? String == "response.create")
        let response = try #require(obj["response"] as? [String: Any])
        #expect(response["output_modalities"] as? [String] == ["text"])
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
        let url = OpenAIStreamingProvider.buildWebSocketURL(
            model: OpenAIStreamingProvider.defaultRealtimeModel)
        #expect(
            url.absoluteString
                == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
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

    @Test("commit-relative transcript and response timings")
    func commitRelativeTimings() {
        var t = makeTiming()
        t.commitSentAt = Date(timeIntervalSince1970: 1001.000)
        t.transcriptCompletedAt = Date(timeIntervalSince1970: 1001.350)
        t.firstDeltaAt = Date(timeIntervalSince1970: 1001.500)
        t.endedAt = Date(timeIntervalSince1970: 1001.700)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("first_delta=0.500"))
        #expect(line.contains("transcript=0.350"))
    }

    @Test("polish field shows realtime outcome")
    func polishField() {
        var t = makeTiming()
        t.polishKind = .realtimeOK
        t.endedAt = Date(timeIntervalSince1970: 1001.500)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("polish=realtime-ok"))
    }

    @Test("polish=skip shown without duration when no LLM ran")
    func polishSkip() {
        var t = makeTiming()
        t.polishKind = .skip
        t.endedAt = Date(timeIntervalSince1970: 1000.5)
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("polish=skip"))
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

    @Test("parses committed audio item correlation")
    func inputAudioBufferCommitted() {
        let withoutPredecessor = """
            {"type":"input_audio_buffer.committed",
             "event_id":"event-1","item_id":"item-1"}
            """
        #expect(
            OpenAIStreamingProvider.parseEvent(withoutPredecessor)
                == .transcription(
                    .commitAcknowledged(
                        serverEventID: "event-1",
                        itemID: "item-1",
                        previousItemID: nil)))

        let nullPredecessor = """
            {"type":"input_audio_buffer.committed",
             "event_id":"event-2","item_id":"item-2",
             "previous_item_id":null}
            """
        #expect(
            OpenAIStreamingProvider.parseEvent(nullPredecessor)
                == .transcription(
                    .commitAcknowledged(
                        serverEventID: "event-2",
                        itemID: "item-2",
                        previousItemID: nil)))

        let priorItem = """
            {"type":"input_audio_buffer.committed",
             "event_id":"event-3","item_id":"item-3",
             "previous_item_id":"item-2"}
            """
        #expect(
            OpenAIStreamingProvider.parseEvent(priorItem)
                == .transcription(
                    .commitAcknowledged(
                        serverEventID: "event-3",
                        itemID: "item-3",
                        previousItemID: "item-2")))
    }

    @Test("rejects malformed committed audio item correlation")
    func malformedInputAudioBufferCommitted() {
        let malformedEvents = [
            #"{"type":"input_audio_buffer.committed","item_id":"item-1"}"#,
            #"{"type":"input_audio_buffer.committed","event_id":"","item_id":"item-1"}"#,
            #"{"type":"input_audio_buffer.committed","event_id":"event-1"}"#,
            #"{"type":"input_audio_buffer.committed","event_id":"event-1","item_id":""}"#,
            #"{"type":"input_audio_buffer.committed","event_id":"event-1","item_id":"item-1","previous_item_id":""}"#,
            #"{"type":"input_audio_buffer.committed","event_id":"event-1","item_id":"item-1","previous_item_id":42}"#,
        ]

        for event in malformedEvents {
            if case .protocolError = OpenAIStreamingProvider.parseEvent(event) {
                continue
            }
            Issue.record("expected protocolError for \(event)")
        }
    }

    @Test("parses transcription.completed event")
    func transcriptionCompleted() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.completed",
             "event_id":"event-completed","item_id":"item-1",
             "content_index":0,
             "transcript":"hello world",
             "usage":{"type":"tokens","input_tokens":10,
                      "output_tokens":2,"total_tokens":12,
                      "input_token_details":{"audio_tokens":10,"text_tokens":0}}}
            """
        #expect(
            OpenAIStreamingProvider.parseEvent(event)
                == .transcription(
                    .completed(
                        serverEventID: "event-completed",
                        itemID: "item-1",
                        contentIndex: 0,
                        transcript: "hello world")))
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

    @Test("parses GA response text delta event")
    func responseOutputTextDelta() {
        let event = #"{"type":"response.output_text.delta","delta":"Pol"}"#
        #expect(
            OpenAIStreamingProvider.parseEvent(event)
                == .responseTextDelta("Pol"))
    }

    @Test("parses GA response text done event")
    func responseOutputTextDone() {
        let event = #"{"type":"response.output_text.done","text":"Polished."}"#
        #expect(
            OpenAIStreamingProvider.parseEvent(event)
                == .responseTextDone("Polished."))
    }

    @Test("parses legacy response text event aliases")
    func responseTextAliases() {
        #expect(
            OpenAIStreamingProvider.parseEvent(
                #"{"type":"response.text.delta","delta":"Pol"}"#)
                == .responseTextDelta("Pol"))
        #expect(
            OpenAIStreamingProvider.parseEvent(
                #"{"type":"response.text.done","text":"Polished."}"#)
                == .responseTextDone("Polished."))
    }

    @Test("parses completed response.done event")
    func responseDone() {
        let event = #"{"type":"response.done","response":{"status":"completed"}}"#
        #expect(OpenAIStreamingProvider.parseEvent(event) == .responseDone)
    }

    @Test("failed response.done becomes an error")
    func failedResponseDone() {
        let event = """
            {"type":"response.done","response":{
              "status":"failed",
              "status_details":{"error":{"message":"model failed"}}
            }}
            """
        let parsed = OpenAIStreamingProvider.parseEvent(event)
        if case .error(let message) = parsed {
            #expect(message.contains("model failed"))
        } else {
            Issue.record("expected error, got \(parsed)")
        }
    }

    @Test("response.done requires an explicit completed status")
    func responseDoneRequiresStatus() {
        #expect(
            OpenAIStreamingProvider.parseEvent(
                #"{"type":"response.done","response":{}}"#)
                == .error("response.done missing status"))
        #expect(
            OpenAIStreamingProvider.parseEvent(
                #"{"type":"response.done"}"#)
                == .error("response.done missing response"))
    }

    @Test("transcription failure retains item correlation and details")
    func transcriptionFailed() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.failed",
             "event_id":"event-failed","item_id":"item-2",
             "content_index":0,
             "error":{"type":"transcription_error",
                      "code":"audio_rejected",
                      "message":"audio rejected","param":"audio"}}
            """
        #expect(
            OpenAIStreamingProvider.parseEvent(event)
                == .transcription(
                    .failed(
                        serverEventID: "event-failed",
                        itemID: "item-2",
                        contentIndex: 0,
                        error: OpenAIRealtimeErrorDetails(
                            type: "transcription_error",
                            code: "audio_rejected",
                            message: "audio rejected",
                            parameter: "audio"))))
    }

    @Test("transcription failure accepts empty optional details")
    func transcriptionFailureWithoutDetails() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.failed",
             "event_id":"event-failed","item_id":"item-1",
             "content_index":0,
             "error":{"type":null,"code":null,
                      "message":null,"param":null}}
            """
        let details = OpenAIRealtimeErrorDetails(
            type: nil,
            code: nil,
            message: nil,
            parameter: nil)

        #expect(
            OpenAIStreamingProvider.parseEvent(event)
                == .transcription(
                    .failed(
                        serverEventID: "event-failed",
                        itemID: "item-1",
                        contentIndex: 0,
                        error: details)))
        #expect(details.ledgerMessage == "input audio transcription failed")
    }

    @Test("parses error event")
    func errorEvent() {
        let event = """
            {"type":"error","event_id":"server-error-1",
             "error":{"type":"invalid_request_error",
                      "code":"invalid_audio","message":"bad audio",
                      "param":"audio","event_id":"client-commit-1"}}
            """
        #expect(
            OpenAIStreamingProvider.parseEvent(event)
                == .serverError(
                    OpenAIRealtimeServerError(
                        serverEventID: "server-error-1",
                        type: "invalid_request_error",
                        code: "invalid_audio",
                        message: "bad audio",
                        parameter: "audio",
                        clientEventID: "client-commit-1")))
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

    @Test("rejects malformed event envelopes")
    func malformedJSON() {
        let malformedEvents = [
            "not json",
            "[]",
            #"{"event_id":"event-1"}"#,
            #"{"type":42}"#,
        ]
        for event in malformedEvents {
            if case .protocolError = OpenAIStreamingProvider.parseEvent(event) {
                continue
            }
            Issue.record("expected protocolError for \(event)")
        }
    }

    @Test("transcription.completed with empty transcript")
    func emptyTranscript() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.completed",
             "event_id":"event-completed","item_id":"item-1",
             "content_index":0,
             "transcript":""}
            """
        #expect(
            OpenAIStreamingProvider.parseEvent(event)
                == .transcription(
                    .completed(
                        serverEventID: "event-completed",
                        itemID: "item-1",
                        contentIndex: 0,
                        transcript: "")))
    }

    @Test("rejects malformed transcription terminal events")
    func malformedTranscriptionTerminalEvents() {
        let malformedEvents = [
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","content_index":0,"transcript":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"event-1","content_index":0,"transcript":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"event-1","item_id":"item-1","transcript":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"event-1","item_id":"item-1","content_index":-1,"transcript":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"event-1","item_id":"item-1","content_index":0.5,"transcript":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"event-1","item_id":"item-1","content_index":true,"transcript":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"event-1","item_id":"item-1","content_index":9223372036854775808,"transcript":"text"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"event-1","item_id":"item-1","content_index":0}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"event-1","item_id":"item-1","content_index":0,"transcript":42}"#,
            #"{"type":"conversation.item.input_audio_transcription.failed","event_id":"event-1","item_id":"item-1","content_index":0}"#,
            #"{"type":"conversation.item.input_audio_transcription.failed","event_id":"event-1","item_id":"item-1","content_index":0,"error":[]}"#,
            #"{"type":"conversation.item.input_audio_transcription.failed","event_id":"event-1","item_id":"item-1","content_index":0,"error":{"message":42}}"#,
        ]
        for event in malformedEvents {
            if case .protocolError = OpenAIStreamingProvider.parseEvent(event) {
                continue
            }
            Issue.record("expected protocolError for \(event)")
        }
    }

    @Test("rejects malformed generic error events")
    func malformedGenericErrors() {
        let malformedEvents = [
            #"{"type":"error","error":{"type":"server_error","message":"failed"}}"#,
            #"{"type":"error","event_id":"event-1"}"#,
            #"{"type":"error","event_id":"event-1","error":[]}"#,
            #"{"type":"error","event_id":"event-1","error":{"message":"failed"}}"#,
            #"{"type":"error","event_id":"event-1","error":{"type":"server_error"}}"#,
            #"{"type":"error","event_id":"event-1","error":{"type":"","message":"failed"}}"#,
            #"{"type":"error","event_id":"event-1","error":{"type":"server_error","message":""}}"#,
            #"{"type":"error","event_id":"event-1","error":{"type":"server_error","message":"failed","code":42}}"#,
        ]
        for event in malformedEvents {
            if case .protocolError = OpenAIStreamingProvider.parseEvent(event) {
                continue
            }
            Issue.record("expected protocolError for \(event)")
        }
    }
}

@Suite("OpenAI Realtime transcript event reducer")
struct OpenAIRealtimeTranscriptReducerTests {

    @Test("correlates a terminal event that precedes acknowledgement")
    func terminalBeforeAcknowledgement() throws {
        var reducer = OpenAIRealtimeTranscriptReducer()
        _ = try reducer.recordCommit(
            coverageRange: 0..<100,
            submittedRange: 0..<100)

        try reducer.apply(try transcriptionEvent("""
            {"type":"conversation.item.input_audio_transcription.completed",
             "event_id":"completed-1","item_id":"item-1",
             "content_index":0,"transcript":"early text"}
            """))
        try reducer.apply(try transcriptionEvent("""
            {"type":"input_audio_buffer.committed",
             "event_id":"ack-1","item_id":"item-1",
             "previous_item_id":null}
            """))
        try reducer.seal(expectedCoverageEnd: 100)

        let resolved = try reducer.resolvedItems()
        #expect(resolved.map(\.itemID) == ["item-1"])
        #expect(resolved.map(\.transcript) == ["early text"])
    }

    @Test("correlates reversed terminal order by item ID")
    func reversedTerminalOrder() throws {
        var reducer = OpenAIRealtimeTranscriptReducer()
        _ = try reducer.recordCommit(
            coverageRange: 0..<100,
            submittedRange: 0..<100)
        try reducer.apply(try transcriptionEvent("""
            {"type":"input_audio_buffer.committed",
             "event_id":"ack-1","item_id":"item-1",
             "previous_item_id":null}
            """))

        _ = try reducer.recordCommit(
            coverageRange: 100..<200,
            submittedRange: 100..<200)
        try reducer.apply(try transcriptionEvent("""
            {"type":"input_audio_buffer.committed",
             "event_id":"ack-2","item_id":"item-2",
             "previous_item_id":"item-1"}
            """))

        try reducer.apply(try transcriptionEvent("""
            {"type":"conversation.item.input_audio_transcription.completed",
             "event_id":"completed-2","item_id":"item-2",
             "content_index":0,"transcript":"second"}
            """))
        try reducer.apply(try transcriptionEvent("""
            {"type":"conversation.item.input_audio_transcription.completed",
             "event_id":"completed-1","item_id":"item-1",
             "content_index":0,"transcript":"first"}
            """))
        try reducer.seal(expectedCoverageEnd: 200)

        let resolved = try reducer.resolvedItems()
        #expect(resolved.map(\.itemID) == ["item-1", "item-2"])
        #expect(resolved.map(\.transcript) == ["first", "second"])
    }

    @Test("correlates item-scoped transcription failure")
    func itemScopedFailure() throws {
        var reducer = OpenAIRealtimeTranscriptReducer()
        _ = try reducer.recordCommit(
            coverageRange: 0..<100,
            submittedRange: 0..<100)
        try reducer.apply(try transcriptionEvent("""
            {"type":"input_audio_buffer.committed",
             "event_id":"ack-1","item_id":"item-1"}
            """))
        try reducer.apply(try transcriptionEvent("""
            {"type":"conversation.item.input_audio_transcription.failed",
             "event_id":"failed-1","item_id":"item-1",
             "content_index":0,"error":{"message":"audio rejected"}}
            """))
        try reducer.seal(expectedCoverageEnd: 100)

        do {
            _ = try reducer.resolvedItems()
            Issue.record("expected item-scoped transcription failure")
        } catch let failure as RealtimeTranscriptLedger.Failure {
            #expect(
                failure == .transcriptionFailed(
                    itemID: "item-1",
                    message: "audio rejected"))
        }
    }

    @Test("rejects unsupported content index")
    func unsupportedContentIndex() throws {
        var reducer = OpenAIRealtimeTranscriptReducer()
        _ = try reducer.recordCommit(
            coverageRange: 0..<100,
            submittedRange: 0..<100)

        do {
            try reducer.apply(try transcriptionEvent("""
                {"type":"conversation.item.input_audio_transcription.completed",
                 "event_id":"completed-wrong","item_id":"item-1",
                 "content_index":1,"transcript":"wrong part"}
                """))
            Issue.record("expected unsupported content index")
        } catch let failure as OpenAIRealtimeTranscriptReducer.Failure {
            #expect(
                failure == .unsupportedContentIndex(
                    itemID: "item-1",
                    actual: 1))
        }

    }

    @Test("deduplicates exact server event replay")
    func duplicateServerEventReplay() throws {
        var reducer = OpenAIRealtimeTranscriptReducer()
        _ = try reducer.recordCommit(
            coverageRange: 0..<100,
            submittedRange: 0..<100)
        let acknowledgement = try transcriptionEvent("""
            {"type":"input_audio_buffer.committed",
             "event_id":"ack-1","item_id":"item-1"}
            """)
        try reducer.apply(acknowledgement)
        try reducer.apply(acknowledgement)

        let completion = try transcriptionEvent("""
            {"type":"conversation.item.input_audio_transcription.completed",
             "event_id":"terminal-1","item_id":"item-1",
             "content_index":0,"transcript":"same"}
            """)
        try reducer.apply(completion)
        try reducer.apply(completion)
        try reducer.seal(expectedCoverageEnd: 100)
        #expect(try reducer.resolvedItems().map(\.transcript) == ["same"])
    }

    @Test("rejects a server event ID reused for another payload")
    func conflictingServerEventID() throws {
        var reducer = OpenAIRealtimeTranscriptReducer()
        _ = try reducer.recordCommit(
            coverageRange: 0..<100,
            submittedRange: 0..<100)
        try reducer.apply(try transcriptionEvent("""
            {"type":"input_audio_buffer.committed",
             "event_id":"ack-1","item_id":"item-1"}
            """))
        try reducer.apply(try transcriptionEvent("""
            {"type":"conversation.item.input_audio_transcription.completed",
             "event_id":"terminal-1","item_id":"item-1",
             "content_index":0,"transcript":"same"}
            """))

        do {
            try reducer.apply(try transcriptionEvent("""
                {"type":"conversation.item.input_audio_transcription.failed",
                 "event_id":"terminal-1","item_id":"item-1",
                 "content_index":0,"error":{}}
                """))
            Issue.record("expected reused server event ID failure")
        } catch let failure as OpenAIRealtimeTranscriptReducer.Failure {
            #expect(failure == .conflictingServerEventID("terminal-1"))
        }
    }
}

private enum OpenAIRealtimeFixtureError: Error {
    case expectedTranscriptionEvent
}

private func transcriptionEvent(
    _ text: String
) throws -> OpenAIRealtimeTranscriptionEvent {
    let parsed = OpenAIStreamingProvider.parseEvent(text)
    guard case .transcription(let event) = parsed else {
        Issue.record("expected transcription event, got \(parsed)")
        throw OpenAIRealtimeFixtureError.expectedTranscriptionEvent
    }
    return event
}

// MARK: - Production response flow

private actor ScriptedRealtimeExchange {
    enum ScriptError: Error {
        case exhausted
    }

    private var events: [String]
    private var sentMessages: [String] = []

    init(events: [String]) {
        self.events = events
    }

    func receive() throws -> String {
        guard !events.isEmpty else { throw ScriptError.exhausted }
        return events.removeFirst()
    }

    func send(_ message: String) {
        sentMessages.append(message)
    }

    func sent() -> [String] {
        sentMessages
    }
}

@Suite("OpenAIStreamingProvider – production response flow")
struct OpenAIRealtimeResponseFlowTests {

    @Test("transcript is polished on the same connection")
    func completeFlow() async throws {
        let exchange = ScriptedRealtimeExchange(events: [
            #"{"type":"input_audio_buffer.committed","event_id":"ack-1","item_id":"item-1","previous_item_id":null}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","event_id":"delta-1","item_id":"item-1","content_index":0,"delta":"raw"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"completed-1","item_id":"item-1","content_index":0,"transcript":"raw words"}"#,
            #"{"type":"response.output_text.delta","delta":"Polished "}"#,
            #"{"type":"response.output_text.delta","delta":"words."}"#,
            #"{"type":"response.done","response":{"status":"completed"}}"#,
        ])

        let result = try await OpenAIStreamingProvider.runRealtimeResponse(
            receive: { try await exchange.receive() },
            send: { await exchange.send($0) })

        #expect(result == "Polished words.")
        let sent = await exchange.sent()
        #expect(sent.count == 2)

        let item = try JSONSerialization.jsonObject(
            with: sent[0].data(using: .utf8)!) as! [String: Any]
        #expect(item["type"] as? String == "conversation.item.create")
        let message = item["item"] as! [String: Any]
        let content = message["content"] as! [[String: Any]]
        #expect(content[0]["text"] as? String == "raw words")

        let create = try JSONSerialization.jsonObject(
            with: sent[1].data(using: .utf8)!) as! [String: Any]
        #expect(create["type"] as? String == "response.create")
    }

    @Test("empty transcript sends no response request")
    func emptyTranscript() async throws {
        let exchange = ScriptedRealtimeExchange(events: [
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"completed-1","item_id":"item-1","content_index":0,"transcript":""}"#
        ])

        let result = try await OpenAIStreamingProvider.runRealtimeResponse(
            receive: { try await exchange.receive() },
            send: { await exchange.send($0) })

        #expect(result.isEmpty)
        #expect(await exchange.sent().isEmpty)
    }

    @Test("text-done result is authoritative over preceding deltas")
    func textDoneResult() async throws {
        let exchange = ScriptedRealtimeExchange(events: [
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"completed-1","item_id":"item-1","content_index":0,"transcript":"raw"}"#,
            #"{"type":"response.output_text.delta","delta":"Partial"}"#,
            #"{"type":"response.output_text.done","text":"Final text."}"#,
            #"{"type":"response.done","response":{"status":"completed"}}"#,
        ])

        let result = try await OpenAIStreamingProvider.runRealtimeResponse(
            receive: { try await exchange.receive() },
            send: { await exchange.send($0) })

        #expect(result == "Final text.")
    }

    @Test("terminal failure overrides a preceding text-done event")
    func failureAfterTextDone() async {
        let exchange = ScriptedRealtimeExchange(events: [
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"completed-1","item_id":"item-1","content_index":0,"transcript":"raw"}"#,
            #"{"type":"response.output_text.delta","delta":"Partial"}"#,
            #"{"type":"response.output_text.done","text":"Final text."}"#,
            #"{"type":"response.done","response":{"status":"failed"}}"#,
        ])

        await #expect(throws: DictationError.self) {
            try await OpenAIStreamingProvider.runRealtimeResponse(
                receive: { try await exchange.receive() },
                send: { await exchange.send($0) })
        }
    }

    @Test("nonzero transcript content index is rejected before polish")
    func rejectsUnsupportedTranscriptContentIndex() async {
        let exchange = ScriptedRealtimeExchange(events: [
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"completed-1","item_id":"item-1","content_index":1,"transcript":"wrong part"}"#
        ])

        do {
            _ = try await OpenAIStreamingProvider.runRealtimeResponse(
                receive: { try await exchange.receive() },
                send: { await exchange.send($0) })
            Issue.record("expected unsupported content index failure")
        } catch DictationError.networkError(let message) {
            #expect(message.contains("content_index"))
        } catch {
            Issue.record("expected DictationError.networkError, got \(error)")
        }
        #expect(await exchange.sent().isEmpty)
    }

    @Test("item-scoped transcription failure sends no polish request")
    func transcriptionFailureBeforeCompletion() async {
        let exchange = ScriptedRealtimeExchange(events: [
            #"{"type":"conversation.item.input_audio_transcription.failed","event_id":"failed-1","item_id":"item-1","content_index":0,"error":{"message":"audio rejected"}}"#
        ])

        await #expect(throws: DictationError.self) {
            try await OpenAIStreamingProvider.runRealtimeResponse(
                receive: { try await exchange.receive() },
                send: { await exchange.send($0) })
        }
        #expect(await exchange.sent().isEmpty)
    }

    @Test("malformed terminal event sends no polish request")
    func protocolFailureBeforeCompletion() async {
        let exchange = ScriptedRealtimeExchange(events: [
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","content_index":0,"transcript":"raw"}"#
        ])

        await #expect(throws: DictationError.self) {
            try await OpenAIStreamingProvider.runRealtimeResponse(
                receive: { try await exchange.receive() },
                send: { await exchange.send($0) })
        }
        #expect(await exchange.sent().isEmpty)
    }

    @Test("server error before transcript sends no polish request")
    func serverErrorBeforeCompletion() async {
        let exchange = ScriptedRealtimeExchange(events: [
            #"{"type":"error","event_id":"server-error-1","error":{"type":"invalid_request_error","code":"bad_audio","message":"commit rejected","event_id":"commit-1"}}"#
        ])

        do {
            _ = try await OpenAIStreamingProvider.runRealtimeResponse(
                receive: { try await exchange.receive() },
                send: { await exchange.send($0) })
            Issue.record("expected server error")
        } catch DictationError.networkError(let message) {
            #expect(message.contains("commit rejected"))
            #expect(message.contains("server-error-1"))
            #expect(message.contains("commit-1"))
            #expect(message.contains("bad_audio"))
        } catch {
            Issue.record("expected DictationError.networkError, got \(error)")
        }
        #expect(await exchange.sent().isEmpty)
    }

    @Test("response errors are surfaced")
    func responseError() async {
        let exchange = ScriptedRealtimeExchange(events: [
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"completed-1","item_id":"item-1","content_index":0,"transcript":"raw"}"#,
            #"{"type":"error","event_id":"server-error-1","error":{"type":"invalid_request_error","code":"bad_request","message":"response rejected","event_id":"response-create-1"}}"#,
        ])

        do {
            _ = try await OpenAIStreamingProvider.runRealtimeResponse(
                receive: { try await exchange.receive() },
                send: { await exchange.send($0) })
            Issue.record("expected server error")
        } catch DictationError.networkError(let message) {
            #expect(message.contains("response rejected"))
            #expect(message.contains("server-error-1"))
            #expect(message.contains("response-create-1"))
            #expect(message.contains("bad_request"))
        } catch {
            Issue.record("expected DictationError.networkError, got \(error)")
        }
        #expect(await exchange.sent().count == 2)
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
        let provider = OpenAIStreamingProvider(apiKey: apiKey)
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
        let provider = OpenAIStreamingProvider(apiKey: apiKey)
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
        let provider = OpenAIStreamingProvider(apiKey: "sk-test")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await provider.cancelStreaming() }
            }
        }
        // If we get here without crashing, the lock discipline is correct.
    }

    @Test("concurrent disconnect calls do not crash")
    func concurrentDisconnect() async {
        let provider = OpenAIStreamingProvider(apiKey: "sk-test")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await provider.disconnect() }
            }
        }
    }
}
