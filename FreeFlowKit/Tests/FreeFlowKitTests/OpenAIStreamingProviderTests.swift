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

        let instructions = try #require(session["instructions"] as? String)
        #expect(
            instructions.hasPrefix(
                PolishPipeline.buildCloudSystemPrompt(
                    context: context, language: "en")))
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

    @Test("session.update preserves semantic discourse across committed items")
    func sessionUpdatePreservesCommittedDiscourse() throws {
        let json = OpenAIStreamingProvider.buildSessionUpdate(
            sttModel: "m", language: "en", context: .empty)
        let obj = try #require(
            try JSONSerialization.jsonObject(
                with: json.data(using: .utf8)!) as? [String: Any])
        let session = try #require(obj["session"] as? [String: Any])
        let instructions = try #require(session["instructions"] as? String)

        #expect(instructions.contains("complete ordered transcript"))
        #expect(instructions.contains("Never delete or summarize a complete sentence or clause"))
        #expect(instructions.contains("Just circling back on this"))
        #expect(instructions.contains("explicit self-corrections or restarts"))
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

    @Test("summary emits only a closed failure category")
    func failureField() {
        var t = makeTiming()
        t.endedAt = Date(timeIntervalSince1970: 1000.5)
        t.failure = .network
        let line = OpenAIStreamingProvider.formatSessionSummary(t)
        #expect(line.contains("failure=network"))
        #expect(!line.contains("error="))
    }

    @Test("arbitrary error descriptions map to closed failure categories")
    func failureClassification() {
        let secret = "dictated-secret-\(UUID().uuidString)"

        #expect(
            OpenAIStreamingProvider.failureKind(
                for: DictationError.networkError(secret)) == .network)
        #expect(
            OpenAIStreamingProvider.failureKind(
                for: DictationError.requestFailed(
                    statusCode: 500, message: secret)) == .request)
        #expect(
            OpenAIStreamingProvider.failureKind(for: CancellationError())
                == .cancelled)
    }
}

// MARK: - Transcript Timeout

@Suite("OpenAIStreamingProvider – transcript timeout")
struct OpenAIRealtimeTranscriptTimeoutTests {

    @Test("maximum finish watchdog covers supported capture plus accounting cushion")
    func maximumFinishWatchdog() {
        let provider = OpenAIStreamingProvider(apiKey: "sk-test")
        let watchdogBoundWireBytes =
            OpenAIStreamingProvider.finishWatchdogBoundWireAudioBytes
        let supportedSourceSamples = 300 * 16_000
        let firstItemSamples = 190 * 16_000 + 1
        let secondItemSamples = supportedSourceSamples - firstItemSamples
        let supportedWireBytesWithPerItemRounding =
            ((firstItemSamples * 3 + 1) / 2
                + (secondItemSamples * 3 + 1) / 2) * 2
        let requiredWatchdog = OpenAIStreamingProvider.transcriptTimeout(
            forAudioBytes: watchdogBoundWireBytes) + 5

        #expect(supportedWireBytesWithPerItemRounding == 300 * 48_000 + 2)
        #expect(
            watchdogBoundWireBytes > supportedWireBytesWithPerItemRounding)
        #expect(OpenAIStreamingProvider.finishWatchdogBoundSourceSeconds == 310)
        #expect(watchdogBoundWireBytes == 310 * 48_000)
        #expect(requiredWatchdog == 175)
        #expect(provider.finishStreamingWatchdog == 20)
        #expect(provider.maximumFinishStreamingWatchdog == requiredWatchdog)
    }

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
                        predecessor: .unspecified)))

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
                        predecessor: .root)))

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
                        predecessor: .item("item-2"))))
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
        let event = #"{"type":"response.output_text.delta","output_index":2,"content_index":3,"delta":"Pol"}"#
        #expect(
            OpenAIStreamingProvider.parseEvent(event)
                == .responseTextDelta(
                    outputIndex: 2,
                    contentIndex: 3,
                    delta: "Pol"))
    }

    @Test("parses GA response text done event")
    func responseOutputTextDone() {
        let event = #"{"type":"response.output_text.done","output_index":4,"content_index":5,"text":"Polished."}"#
        #expect(
            OpenAIStreamingProvider.parseEvent(event)
                == .responseTextDone(
                    outputIndex: 4,
                    contentIndex: 5,
                    text: "Polished."))
    }

    @Test("response text events require string payloads")
    func responseTextRequiresStringPayload() {
        #expect(
            OpenAIStreamingProvider.parseEvent(
                #"{"type":"response.output_text.delta"}"#)
                == .protocolError(
                    "response.output_text.delta requires string delta"))
        #expect(
            OpenAIStreamingProvider.parseEvent(
                #"{"type":"response.output_text.done","text":42}"#)
                == .protocolError(
                    "response.output_text.done requires string text"))
    }

    @Test("parses legacy response text event aliases")
    func responseTextAliases() {
        #expect(
            OpenAIStreamingProvider.parseEvent(
                #"{"type":"response.text.delta","delta":"Pol"}"#)
                == .responseTextDelta(
                    outputIndex: 0,
                    contentIndex: 0,
                    delta: "Pol"))
        #expect(
            OpenAIStreamingProvider.parseEvent(
                #"{"type":"response.text.done","text":"Polished."}"#)
                == .responseTextDone(
                    outputIndex: 0,
                    contentIndex: 0,
                    text: "Polished."))
    }

    @Test("response text events reject malformed indices")
    func responseTextRejectsMalformedIndices() {
        let events = [
            #"{"type":"response.output_text.delta","output_index":-1,"content_index":0,"delta":"Pol"}"#,
            #"{"type":"response.output_text.delta","output_index":0,"content_index":0.5,"delta":"Pol"}"#,
            #"{"type":"response.output_text.done","output_index":true,"content_index":0,"text":"Polished."}"#,
            #"{"type":"response.output_text.done","output_index":0,"content_index":null,"text":"Polished."}"#,
        ]

        for event in events {
            if case .protocolError = OpenAIStreamingProvider.parseEvent(event) {
                continue
            }
            Issue.record("expected protocolError for \(event)")
        }
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

// MARK: - Session Ownership

@Suite("OpenAIStreamingProvider - session ownership")
struct OpenAIRealtimeSessionOwnershipTests {

    @Test("second start fails without replacing the active session")
    func secondStartFailsWithoutReplacingActiveSession() async throws {
        let transportA = TestRealtimeTransport()
        let transportB = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory([transportA, transportB])
        let provider = makeProvider(factory: factory)
        let sessionA = DictationSessionID()
        let sessionB = DictationSessionID()

        try await start(provider, sessionID: sessionA, transport: transportA)

        await #expect(
            throws: DictationError.networkError(
                "A Realtime session is already active")
        ) {
            try await provider.startStreaming(
                sessionID: sessionB,
                context: .empty,
                language: "en",
                micProximity: .nearField)
        }
        #expect(factory.makeCount() == 1)

        try await provider.sendAudio(
            Data(repeating: 1, count: 2),
            sessionID: sessionA)
        #expect(transportA.messageCount() == 2)
        #expect(transportB.messageCount() == 0)

        await provider.cancelStreaming(sessionID: sessionA)
    }

    @Test("stale send cannot reach a replacement session")
    func staleSendCannotReachReplacementSession() async throws {
        let fixture = try await replacementFixture()

        await #expect(throws: CancellationError.self) {
            try await fixture.provider.sendAudio(
                Data(repeating: 1, count: 2),
                sessionID: fixture.sessionA)
        }
        #expect(fixture.transportB.messageCount() == 1)

        try await fixture.provider.sendAudio(
            Data(repeating: 1, count: 2),
            sessionID: fixture.sessionB)
        #expect(fixture.transportB.messageCount() == 2)

        await fixture.provider.cancelStreaming(sessionID: fixture.sessionB)
    }

    @Test("stale finish cannot tear down a replacement session")
    func staleFinishCannotTearDownReplacementSession() async throws {
        let fixture = try await replacementFixture()

        await #expect(throws: CancellationError.self) {
            _ = try await fixture.provider.finishStreaming(
                sessionID: fixture.sessionA)
        }
        #expect(fixture.transportB.closeReasons().isEmpty)

        try await fixture.provider.sendAudio(
            Data(repeating: 1, count: 2),
            sessionID: fixture.sessionB)
        #expect(fixture.transportB.messageCount() == 2)

        await fixture.provider.cancelStreaming(sessionID: fixture.sessionB)
    }

    @Test("stale cancel cannot tear down a replacement session")
    func staleCancelCannotTearDownReplacementSession() async throws {
        let fixture = try await replacementFixture()

        await fixture.provider.cancelStreaming(sessionID: fixture.sessionA)
        #expect(fixture.transportB.closeReasons().isEmpty)

        try await fixture.provider.sendAudio(
            Data(repeating: 1, count: 2),
            sessionID: fixture.sessionB)
        #expect(fixture.transportB.messageCount() == 2)

        await fixture.provider.cancelStreaming(sessionID: fixture.sessionB)
    }

    @Test("cancel drains setup before releasing ownership")
    func cancelDrainsSetupBeforeReleasingOwnership() async throws {
        let setupGate = TestBlockingSetupSend()
        let transportA = TestRealtimeTransport(setupGate: setupGate)
        let transportB = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory([transportA, transportB])
        let provider = makeProvider(factory: factory)
        let sessionA = DictationSessionID()
        let sessionB = DictationSessionID()

        try await provider.startStreaming(
            sessionID: sessionA,
            context: .empty,
            language: "en",
            micProximity: .nearField)
        await setupGate.waitUntilStarted()

        let cancellationCompleted = TestOwnershipProbe()
        let cancellation = Task {
            await provider.cancelStreaming(sessionID: sessionA)
            cancellationCompleted.mark()
        }
        await setupGate.waitUntilCancelled()

        #expect(!cancellationCompleted.isMarked())
        await #expect(
            throws: DictationError.networkError(
                "A Realtime session is already active")
        ) {
            try await provider.startStreaming(
                sessionID: sessionB,
                context: .empty,
                language: "en",
                micProximity: .nearField)
        }

        setupGate.release()
        await cancellation.value
        #expect(transportA.closeReasons() == [.goingAway])

        try await start(provider, sessionID: sessionB, transport: transportB)
        await provider.cancelStreaming(sessionID: sessionB)
    }

    @Test("replacement session reads the current API key")
    func replacementSessionReadsCurrentAPIKey() async throws {
        let transportA = TestRealtimeTransport()
        let transportB = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory([transportA, transportB])
        let apiKey = TestMutableAPIKey("sk-expired")
        let provider = OpenAIStreamingProvider(
            apiKeyProvider: { apiKey.value },
            realtimeModel: "realtime-test",
            sttModel: "transcribe-test",
            commitPolicy: RealtimeCommitPolicy(),
            maxUnresolvedItems: 2,
            evidenceObserver: nil,
            transportFactory: { try factory.make(apiKey: $0, model: $1) })
        let sessionA = DictationSessionID()
        let sessionB = DictationSessionID()

        try await start(provider, sessionID: sessionA, transport: transportA)
        await provider.cancelStreaming(sessionID: sessionA)
        apiKey.value = "sk-replacement"
        try await start(provider, sessionID: sessionB, transport: transportB)
        await provider.cancelStreaming(sessionID: sessionB)

        #expect(factory.apiKeys() == ["sk-expired", "sk-replacement"])
    }

    @Test("warm backup with a stale API key is closed instead of adopted")
    func staleKeyBackupIsNotAdopted() async throws {
        let activeA = TestRealtimeTransport()
        let staleBackup = TestRealtimeTransport()
        let activeB = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory([
            activeA, staleBackup, activeB,
        ])
        let apiKey = TestMutableAPIKey("sk-expired")
        let backupReady = TestOwnershipProbe()
        let provider = makeProvider(
            factory: factory,
            apiKey: { apiKey.value },
            backupReadyObserver: { backupReady.mark() })
        let sessionA = DictationSessionID()
        let sessionB = DictationSessionID()

        try await start(provider, sessionID: sessionA, transport: activeA)
        _ = try await provider.finishStreaming(sessionID: sessionA)
        await backupReady.waitUntilMarked()

        apiKey.value = "sk-current"
        try await provider.startStreaming(
            sessionID: sessionB,
            context: .empty,
            language: "en",
            micProximity: .nearField)
        try await provider.sendAudio(
            Data(repeating: 1, count: 2),
            sessionID: sessionB)

        #expect(factory.apiKeys() == ["sk-expired", "sk-expired", "sk-current"])
        #expect(staleBackup.closeReasons() == [.normal])
        #expect(staleBackup.messageCount() == 0)
        #expect(activeB.messageCount() == 2)

        await provider.cancelStreaming(sessionID: sessionB)
    }

    @Test("disconnect fences standby creation from a concurrent successful finish")
    func disconnectFencesConcurrentFinishStandby() async throws {
        let active = TestRealtimeTransport()
        let unexpectedBackup = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory([active, unexpectedBackup])
        let apiKey = TestBlockingSecondAPIKeyRead()
        let provider = makeProvider(
            factory: factory,
            apiKey: { apiKey.value })
        let sessionID = DictationSessionID()

        try await start(provider, sessionID: sessionID, transport: active)
        let finish = Task {
            try await provider.finishStreaming(sessionID: sessionID)
        }
        await apiKey.waitUntilSecondReadStarts()

        await provider.disconnect()
        apiKey.releaseSecondRead()
        _ = try await finish.value

        let retainedStandby = provider.hasStandbyOwnership
        await provider.disconnect()
        #expect(!retainedStandby)
    }

    @Test("an old refresh cannot discard a newer backup generation")
    func oldRefreshCannotDiscardNewBackup() async throws {
        let activeA = TestRealtimeTransport()
        let backupA = TestRealtimeTransport()
        let backupB = TestRealtimeTransport()
        let unexpectedBackup = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory([
            activeA, backupA, backupB, unexpectedBackup,
        ])
        let backupReady = TestCallCounter()
        let refreshGate = TestSequencedAdmission()
        let refreshFinished = TestTokenCompletionProbe()
        let provider = makeProvider(
            factory: factory,
            backupReadyObserver: { backupReady.mark() },
            backupRefreshDelay: 0,
            backupRefreshWillDiscard: { token in
                await refreshGate.suspend(token: token)
            },
            backupRefreshDidFinish: { token in
                refreshFinished.mark(token)
            })
        let sessionA = DictationSessionID()
        let sessionB = DictationSessionID()
        let sessionC = DictationSessionID()

        try await start(provider, sessionID: sessionA, transport: activeA)
        _ = try await provider.finishStreaming(sessionID: sessionA)
        await backupReady.waitForCount(1)
        let staleRefresh = await refreshGate.waitForCall(at: 0)

        try await provider.startStreaming(
            sessionID: sessionB,
            context: .empty,
            language: "en",
            micProximity: .nearField)
        await backupA.waitForMessageCount(1)
        _ = try await provider.finishStreaming(sessionID: sessionB)
        await backupReady.waitForCount(2)
        _ = await refreshGate.waitForCall(at: 1)

        await refreshGate.release(callAt: 0)
        await refreshFinished.wait(for: staleRefresh)

        try await provider.startStreaming(
            sessionID: sessionC,
            context: .empty,
            language: "en",
            micProximity: .nearField)
        try await provider.sendAudio(
            Data(repeating: 1, count: 2),
            sessionID: sessionC)

        #expect(backupB.closeReasons().isEmpty)
        #expect(backupB.messageCount() == 2)
        #expect(unexpectedBackup.messageCount() == 0)

        await provider.cancelStreaming(sessionID: sessionC)
        await refreshGate.releaseAll()
        await provider.disconnect()
    }

    @Test("an old backup open cannot overwrite a newer generation")
    func oldBackupOpenCannotOverwriteNewGeneration() async throws {
        let activeA = TestRealtimeTransport()
        let staleOpen = TestRealtimeTransport()
        let activeB = TestRealtimeTransport()
        let currentBackup = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory([
            activeA, staleOpen, activeB, currentBackup,
        ])
        let apiKey = TestMutableAPIKey("sk-expired")
        let openGate = TestSequencedAdmission()
        let openFinished = TestTokenCompletionProbe()
        let backupReady = TestCallCounter()
        let provider = makeProvider(
            factory: factory,
            apiKey: { apiKey.value },
            backupReadyObserver: { backupReady.mark() },
            backupOpenWillPublish: { token in
                await openGate.suspend(token: token)
            },
            backupOpenDidFinish: { token in
                openFinished.mark(token)
            })
        let sessionA = DictationSessionID()
        let sessionB = DictationSessionID()
        let sessionC = DictationSessionID()

        try await start(provider, sessionID: sessionA, transport: activeA)
        _ = try await provider.finishStreaming(sessionID: sessionA)
        let staleOpenToken = await openGate.waitForCall(at: 0)

        apiKey.value = "sk-current"
        try await start(provider, sessionID: sessionB, transport: activeB)
        _ = try await provider.finishStreaming(sessionID: sessionB)
        _ = await openGate.waitForCall(at: 1)

        await openGate.release(callAt: 1)
        await backupReady.waitForCount(1)
        await openGate.release(callAt: 0)
        await openFinished.wait(for: staleOpenToken)

        try await provider.startStreaming(
            sessionID: sessionC,
            context: .empty,
            language: "en",
            micProximity: .nearField)
        try await provider.sendAudio(
            Data(repeating: 1, count: 2),
            sessionID: sessionC)

        #expect(staleOpen.closeReasons() == [.normal])
        #expect(staleOpen.messageCount() == 0)
        #expect(currentBackup.messageCount() == 2)
        #expect(factory.apiKeys() == [
            "sk-expired", "sk-expired", "sk-current", "sk-current",
        ])

        await provider.cancelStreaming(sessionID: sessionC)
        await openGate.releaseAll()
        await provider.disconnect()
    }

    @Test("cancel before setup publication closes an adopted backup")
    func cancelBeforeSetupPublicationClosesAdoptedBackup() async throws {
        let activeA = TestRealtimeTransport()
        let adoptedBackup = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory([activeA, adoptedBackup])
        let backupReady = TestOwnershipProbe()
        let setupGate = TestAsyncAdmission()
        let admittedSession = TestLockedValue<DictationSessionID?>(nil)
        let provider = makeProvider(
            factory: factory,
            setupAdmission: { sessionID in
                guard admittedSession.value == sessionID else { return }
                await setupGate.suspend()
            },
            backupReadyObserver: { backupReady.mark() })
        let sessionA = DictationSessionID()
        let sessionB = DictationSessionID()

        try await start(provider, sessionID: sessionA, transport: activeA)
        _ = try await provider.finishStreaming(sessionID: sessionA)
        await backupReady.waitUntilMarked()

        admittedSession.value = sessionB
        try await provider.startStreaming(
            sessionID: sessionB,
            context: .empty,
            language: "en",
            micProximity: .nearField)
        await setupGate.waitUntilStarted()

        let cancellation = Task {
            await provider.cancelStreaming(sessionID: sessionB)
        }
        await setupGate.waitUntilCancelled()
        setupGate.release()
        await cancellation.value

        #expect(adoptedBackup.closeReasons() == [.normal])
    }

    private struct ReplacementFixture {
        let provider: OpenAIStreamingProvider
        let sessionA: DictationSessionID
        let sessionB: DictationSessionID
        let transportB: TestRealtimeTransport
    }

    private func replacementFixture() async throws -> ReplacementFixture {
        let transportA = TestRealtimeTransport()
        let transportB = TestRealtimeTransport()
        let factory = TestRealtimeTransportFactory([transportA, transportB])
        let provider = makeProvider(factory: factory)
        let sessionA = DictationSessionID()
        let sessionB = DictationSessionID()

        try await start(provider, sessionID: sessionA, transport: transportA)
        await provider.cancelStreaming(sessionID: sessionA)
        try await start(provider, sessionID: sessionB, transport: transportB)

        return ReplacementFixture(
            provider: provider,
            sessionA: sessionA,
            sessionB: sessionB,
            transportB: transportB)
    }

    private func makeProvider(
        factory: TestRealtimeTransportFactory,
        apiKey: @escaping @Sendable () -> String = { "sk-test" },
        setupAdmission: OpenAIStreamingProvider.SetupAdmission? = nil,
        backupReadyObserver: OpenAIStreamingProvider.BackupReadyObserver? = nil,
        backupOpenWillPublish: OpenAIStreamingProvider.BackupOpenObserver? = nil,
        backupOpenDidFinish: OpenAIStreamingProvider.BackupOpenCompletionObserver? = nil,
        backupRefreshDelay: TimeInterval = 35,
        backupRefreshWillDiscard: OpenAIStreamingProvider.BackupRefreshObserver? = nil,
        backupRefreshDidFinish: OpenAIStreamingProvider.BackupRefreshCompletionObserver? = nil
    ) -> OpenAIStreamingProvider {
        OpenAIStreamingProvider(
            apiKeyProvider: apiKey,
            realtimeModel: "realtime-test",
            sttModel: "transcribe-test",
            commitPolicy: RealtimeCommitPolicy(),
            maxUnresolvedItems: 2,
            evidenceObserver: nil,
            transportFactory: { try factory.make(apiKey: $0, model: $1) },
            setupAdmission: setupAdmission,
            backupReadyObserver: backupReadyObserver,
            backupOpenWillPublish: backupOpenWillPublish,
            backupOpenDidFinish: backupOpenDidFinish,
            backupRefreshDelay: backupRefreshDelay,
            backupRefreshWillDiscard: backupRefreshWillDiscard,
            backupRefreshDidFinish: backupRefreshDidFinish)
    }

    private func start(
        _ provider: OpenAIStreamingProvider,
        sessionID: DictationSessionID,
        transport: TestRealtimeTransport
    ) async throws {
        try await provider.startStreaming(
            sessionID: sessionID,
            context: .empty,
            language: "en",
            micProximity: .nearField)
        await transport.waitForMessageCount(1)
    }
}

private enum TestRealtimeTransportFailure: Error {
    case closed
    case noTransport
}

private final class TestRealtimeTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [TestRealtimeTransport]
    private var creationCount = 0
    private var recordedAPIKeys: [String] = []

    init(_ queued: [TestRealtimeTransport]) {
        self.queued = queued
    }

    func make(
        apiKey: String,
        model _: String
    ) throws -> any OpenAIRealtimeTransport {
        try lock.withLock {
            guard !queued.isEmpty else {
                throw TestRealtimeTransportFailure.noTransport
            }
            creationCount += 1
            recordedAPIKeys.append(apiKey)
            return queued.removeFirst()
        }
    }

    func makeCount() -> Int {
        lock.withLock { creationCount }
    }

    func apiKeys() -> [String] {
        lock.withLock { recordedAPIKeys }
    }
}

private final class TestMutableAPIKey: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(_ value: String) {
        storage = value
    }

    var value: String {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class TestBlockingSecondAPIKeyRead: @unchecked Sendable {
    private let lock = NSLock()
    private let secondReadStarted = TestOwnershipProbe()
    private let secondReadRelease = DispatchSemaphore(value: 0)
    private var readCount = 0

    var value: String {
        let shouldBlock = lock.withLock {
            readCount += 1
            return readCount == 2
        }
        if shouldBlock {
            secondReadStarted.mark()
            secondReadRelease.wait()
        }
        return "sk-test"
    }

    func waitUntilSecondReadStarts() async {
        await secondReadStarted.waitUntilMarked()
    }

    func releaseSecondRead() {
        secondReadRelease.signal()
    }
}

private final class TestRealtimeTransport:
    OpenAIRealtimeTransport, @unchecked Sendable
{
    private let lock = NSLock()
    private let setupGate: TestBlockingSetupSend?
    private var messages: [String] = []
    private var messageWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []
    private var receiveWaiters:
        [CheckedContinuation<String, any Error>] = []
    private var closes: [OpenAIRealtimeTransportCloseReason] = []
    private var isClosed = false
    private var resumeCount = 0

    init(setupGate: TestBlockingSetupSend? = nil) {
        self.setupGate = setupGate
    }

    func resume() {
        lock.withLock { resumeCount += 1 }
    }

    func send(_ text: String) async throws {
        let result: (messageNumber: Int, waiters: [CheckedContinuation<Void, Never>]) =
            try lock.withLock {
            guard !isClosed else { throw TestRealtimeTransportFailure.closed }
            messages.append(text)
            let count = messages.count
            let ready = messageWaiters.filter { count >= $0.0 }
            messageWaiters.removeAll { count >= $0.0 }
            return (count, ready.map(\.1))
        }
        for waiter in result.waiters { waiter.resume() }
        if result.messageNumber == 1, let setupGate {
            try await setupGate.suspend()
        }
    }

    func receiveText() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let closed = lock.withLock {
                if isClosed { return true }
                receiveWaiters.append(continuation)
                return false
            }
            if closed {
                continuation.resume(throwing: TestRealtimeTransportFailure.closed)
            }
        }
    }

    func close(_ reason: OpenAIRealtimeTransportCloseReason) {
        let waiters: [CheckedContinuation<String, any Error>] = lock.withLock {
            closes.append(reason)
            isClosed = true
            let waiters = receiveWaiters
            receiveWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: TestRealtimeTransportFailure.closed)
        }
    }

    func waitForMessageCount(_ count: Int) async {
        if lock.withLock({ messages.count >= count }) { return }
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if messages.count >= count { return true }
                messageWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func messageCount() -> Int {
        lock.withLock { messages.count }
    }

    func closeReasons() -> [OpenAIRealtimeTransportCloseReason] {
        lock.withLock { closes }
    }
}

private final class TestBlockingSetupSend: @unchecked Sendable {
    private let lock = NSLock()
    private let started = TestOwnershipProbe()
    private let cancelled = TestOwnershipProbe()
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async throws {
        started.mark()
        await withTaskCancellationHandler {
            if !lock.withLock({ isReleased }) {
                await withCheckedContinuation { continuation in
                    let released = lock.withLock {
                        if isReleased { return true }
                        releaseWaiters.append(continuation)
                        return false
                    }
                    if released { continuation.resume() }
                }
            }
        } onCancel: {
            cancelled.mark()
        }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async {
        await started.waitUntilMarked()
    }

    func waitUntilCancelled() async {
        await cancelled.waitUntilMarked()
    }

    func release() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !isReleased else { return [] }
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

private final class TestOwnershipProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !marked else { return [] }
            marked = true
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilMarked() async {
        if isMarked() { return }
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if marked { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func isMarked() -> Bool {
        lock.withLock { marked }
    }
}

private final class TestCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func mark() {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            count += 1
            let ready = waiters.filter { count >= $0.0 }
            waiters.removeAll { count >= $0.0 }
            return ready.map(\.1)
        }
        for waiter in ready { waiter.resume() }
    }

    func waitForCount(_ expected: Int) async {
        if lock.withLock({ count >= expected }) { return }
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if count >= expected { return true }
                waiters.append((expected, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private actor TestSequencedAdmission {
    private struct Call {
        let token: UUID
        var continuation: CheckedContinuation<Void, Never>?
    }

    private var calls: [Call] = []
    private var arrivalWaiters:
        [(Int, CheckedContinuation<UUID, Never>)] = []

    func suspend(token: UUID) async {
        await withCheckedContinuation { continuation in
            calls.append(Call(token: token, continuation: continuation))
            let ready = arrivalWaiters.filter { calls.count > $0.0 }
            arrivalWaiters.removeAll { calls.count > $0.0 }
            for (index, waiter) in ready {
                waiter.resume(returning: calls[index].token)
            }
        }
    }

    func waitForCall(at index: Int) async -> UUID {
        if calls.count > index { return calls[index].token }
        return await withCheckedContinuation { continuation in
            if calls.count > index {
                continuation.resume(returning: calls[index].token)
            } else {
                arrivalWaiters.append((index, continuation))
            }
        }
    }

    func release(callAt index: Int) {
        guard calls.indices.contains(index) else { return }
        let continuation = calls[index].continuation
        calls[index].continuation = nil
        continuation?.resume()
    }

    func releaseAll() {
        for index in calls.indices {
            let continuation = calls[index].continuation
            calls[index].continuation = nil
            continuation?.resume()
        }
    }
}

private final class TestTokenCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Set<UUID> = []
    private var waiters:
        [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func mark(_ token: UUID) {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            completed.insert(token)
            return waiters.removeValue(forKey: token) ?? []
        }
        for waiter in ready { waiter.resume() }
    }

    func wait(for token: UUID) async {
        if lock.withLock({ completed.contains(token) }) { return }
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if completed.contains(token) { return true }
                waiters[token, default: []].append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private final class TestAsyncAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let started = TestOwnershipProbe()
    private let cancelled = TestOwnershipProbe()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        started.mark()
        await withTaskCancellationHandler {
            if !lock.withLock({ released }) {
                await withCheckedContinuation { continuation in
                    let ready = lock.withLock {
                        if released { return true }
                        waiters.append(continuation)
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
        } onCancel: {
            cancelled.mark()
        }
    }

    func waitUntilStarted() async {
        await started.waitUntilMarked()
    }

    func waitUntilCancelled() async {
        await cancelled.waitUntilMarked()
    }

    func release() {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !released else { return [] }
            released = true
            let ready = waiters
            waiters.removeAll()
            return ready
        }
        for waiter in ready { waiter.resume() }
    }
}

private final class TestLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
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
        let sessionID = DictationSessionID()
        try await provider.startStreaming(
            sessionID: sessionID,
            context: AppContext.empty,
            language: "en",
            micProximity: .nearField)
        // Feed half a second of silent audio.
        let pcm = silentPCM(seconds: 0.5)
        try await provider.sendAudio(pcm, sessionID: sessionID)
        // finishStreaming commits and returns the transcript (likely empty).
        _ = try await provider.finishStreaming(sessionID: sessionID)
    }

    @Test("live: tone signal returns a response")
    func liveToneSession() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let provider = OpenAIStreamingProvider(apiKey: apiKey)
        let sessionID = DictationSessionID()
        try await provider.startStreaming(
            sessionID: sessionID,
            context: AppContext.empty,
            language: "en",
            micProximity: .farField)
        let pcm = toneWAV(seconds: 1.0)
        try await provider.sendAudio(pcm, sessionID: sessionID)
        _ = try await provider.finishStreaming(sessionID: sessionID)
    }
}

// MARK: - Concurrent cancel safety (H3/H4)

@Suite("OpenAIStreamingProvider – concurrent cancel safety")
struct ConcurrentCancelSafetyTests {

    @Test("concurrent active-session cancellation calls do not crash")
    func concurrentCancel() async {
        let provider = OpenAIStreamingProvider(apiKey: "sk-test")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await provider.cancelActiveStreaming() }
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
