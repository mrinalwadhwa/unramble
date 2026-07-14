import Foundation
import Testing

@testable import FreeFlowKit

@Suite("OpenAI Realtime commit policy")
struct OpenAIRealtimeCommitPolicyTests {

    private let policy = RealtimeCommitPolicy(
        maximumUniqueBytes: 8,
        minimumUniqueBytesBeforeSilence: 6,
        trailingSilenceBytesRequired: 2)

    @Test("hard boundary is measured in source audio bytes")
    func hardBoundary() {
        #expect(
            !policy.shouldCommit(
                uniqueByteCount: 6,
                trailingSilenceByteCount: 0))
        #expect(
            policy.shouldCommit(
                uniqueByteCount: 8,
                trailingSilenceByteCount: 0))
    }

    @Test("extended silence commits only after the minimum coverage")
    func silenceBoundary() {
        #expect(
            !policy.shouldCommit(
                uniqueByteCount: 4,
                trailingSilenceByteCount: 2))
        #expect(
            !policy.shouldCommit(
                uniqueByteCount: 6,
                trailingSilenceByteCount: 0))
        #expect(
            policy.shouldCommit(
                uniqueByteCount: 6,
                trailingSilenceByteCount: 2))
    }

    @Test("one append remains below a conservative event-size ceiling")
    func appendEventSizeLimit() async throws {
        let maximumSourceBytes = 7 * 1_024 * 1_024
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 20 * 1_024 * 1_024,
                minimumUniqueBytesBeforeSilence: 20 * 1_024 * 1_024,
                trailingSilenceBytesRequired: 0))

        #expect(
            try await session.maximumAppendByteCount(
                requested: 20 * 1_024 * 1_024)
                == maximumSourceBytes)

        let maximumResampledBytes = maximumSourceBytes * 3 / 2
        let message = OpenAIStreamingProvider.buildAudioAppend(
            pcm24k: Data(repeating: 0xFF, count: maximumResampledBytes),
            eventID: "event-id")
        #expect(message.utf8.count < 15_000_000)
    }
}

@Suite("OpenAI Realtime commit session")
struct OpenAIRealtimeCommitSessionTests {

    private func makeSession(
        maximumUniqueBytes: Int = 8,
        maxUnresolvedItems: Int = 2
    ) -> OpenAIRealtimeCommitSession {
        OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: maximumUniqueBytes,
                minimumUniqueBytesBeforeSilence: maximumUniqueBytes,
                trailingSilenceBytesRequired: 2),
            maxUnresolvedItems: maxUnresolvedItems)
    }

    @Test("commit ranges cover the original PCM exactly once")
    func exactSourceCoverage() async throws {
        let source = Data((0..<20).map(UInt8.init))
        let session = makeSession(maxUnresolvedItems: 3)
        var offset = 0
        var commits: [RealtimeTranscriptLedger.Commit] = []

        while offset < source.count {
            let count = try await session.maximumAppendByteCount(
                requested: source.count - offset)
            #expect(count > 0)
            let shouldCommit = try await session.appendSucceeded(
                byteCount: count,
                containsSpeech: true)
            offset += count

            if shouldCommit {
                let commit = try #require(
                    try await session.prepareCommit(force: false).commit)
                commits.append(commit)
                try await acknowledgeAndComplete(
                    commit,
                    session: session,
                    previousItemID: commit.sequence == 0
                        ? nil
                        : "item-\(commit.sequence - 1)")
            }
        }

        if let final = try await session.prepareCommit(force: true).commit {
            commits.append(final)
            try await acknowledgeAndComplete(
                final,
                session: session,
                previousItemID: final.sequence == 0
                    ? nil
                    : "item-\(final.sequence - 1)")
        }

        #expect(commits.map(\.coverageRange) == [0..<8, 8..<16, 16..<20])
        #expect(commits.map(\.submittedRange) == commits.map(\.coverageRange))
        #expect(commits.allSatisfy { $0.coverageRange.count.isMultiple(of: 2) })

        let reconstructed = commits.reduce(into: Data()) { result, commit in
            result.append(source.subdata(in: commit.coverageRange))
        }
        #expect(reconstructed == source)
    }

    @Test("finishing on a committed boundary creates no empty commit")
    func exactBoundaryFinish() async throws {
        let session = makeSession()
        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        let commit = try #require(
            try await session.prepareCommit(force: false).commit)
        try await acknowledgeAndComplete(
            commit,
            session: session,
            previousItemID: nil)

        #expect(try await session.prepareCommit(force: true) == .noAudio)
        try await session.sealCapture()
        #expect(try await session.waitForRawTranscript() == "segment-0")
    }

    @Test("odd PCM byte counts fail explicitly")
    func rejectsUnalignedPCM() async {
        let session = makeSession()
        await #expect(
            throws: OpenAIRealtimeCommitSession.Failure.unalignedAudioByteCount(3)
        ) {
            _ = try await session.appendSucceeded(
                byteCount: 3,
                containsSpeech: true)
        }
    }

    @Test("a terminal before acknowledgement does not open the commit slot")
    func acknowledgementBackpressure() async throws {
        let session = makeSession(maxUnresolvedItems: 3)
        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        let first = try #require(
            try await session.prepareCommit(force: false).commit)

        try await session.apply(
            .completed(
                serverEventID: "terminal-0",
                itemID: "item-0",
                contentIndex: 0,
                transcript: "first"))

        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        #expect(try await session.prepareCommit(force: false) == .blocked)

        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-0",
                itemID: "item-0",
                predecessor: .root))
        #expect(try await session.prepareCommit(force: false).commit?.sequence == 1)
        #expect(first.sequence == 0)
    }

    @Test("unresolved item capacity bounds admitted commits")
    func unresolvedCapacity() async throws {
        let session = makeSession(maxUnresolvedItems: 2)
        for sequence in 0..<2 {
            _ = try await session.appendSucceeded(
                byteCount: 8,
                containsSpeech: true)
            let commit = try #require(
                try await session.prepareCommit(force: false).commit)
            try await session.apply(
                .commitAcknowledged(
                    serverEventID: "ack-\(sequence)",
                    itemID: "item-\(sequence)",
                    predecessor: sequence == 0 ? .root : .item("item-0")))
            #expect(commit.sequence == sequence)
        }

        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        #expect(try await session.prepareCommit(force: false) == .blocked)

        try await session.apply(
            .completed(
                serverEventID: "terminal-1",
                itemID: "item-1",
                contentIndex: 0,
                transcript: "second"))
        #expect(try await session.prepareCommit(force: false).commit?.sequence == 2)
    }

    @Test("an omitted predecessor is accepted but explicit root is not")
    func optionalPredecessor() async throws {
        let session = makeSession(maxUnresolvedItems: 2)
        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        _ = try #require(
            try await session.prepareCommit(force: false).commit)
        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-0",
                itemID: "item-0",
                predecessor: .root))
        try await session.apply(
            .completed(
                serverEventID: "terminal-0",
                itemID: "item-0",
                contentIndex: 0,
                transcript: "first"))

        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        _ = try #require(
            try await session.prepareCommit(force: false).commit)
        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-1",
                itemID: "item-1",
                predecessor: .unspecified))

        try await session.waitForAcknowledgement(sequence: 1)

        let invalidSession = makeSession(maxUnresolvedItems: 2)
        _ = try await invalidSession.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        let first = try #require(
            try await invalidSession.prepareCommit(force: false).commit)
        try await acknowledgeAndComplete(
            first,
            session: invalidSession,
            previousItemID: nil)
        _ = try await invalidSession.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        _ = try #require(
            try await invalidSession.prepareCommit(force: false).commit)
        await #expect(throws: RealtimeTranscriptLedger.Failure.self) {
            try await invalidSession.apply(
                .commitAcknowledged(
                    serverEventID: "ack-invalid-root",
                    itemID: "item-invalid-root",
                    predecessor: .root))
        }
    }

    @Test("a duplicate old acknowledgement cannot release a newer commit")
    func lateAcknowledgementReplay() async throws {
        let session = makeSession(maxUnresolvedItems: 3)
        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        _ = try #require(
            try await session.prepareCommit(force: false).commit)
        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-0",
                itemID: "item-0",
                predecessor: .root))

        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        _ = try #require(
            try await session.prepareCommit(force: false).commit)
        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)

        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-0-replay",
                itemID: "item-0",
                predecessor: .root))
        #expect(try await session.prepareCommit(force: false) == .blocked)

        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-1",
                itemID: "item-1",
                predecessor: .item("item-0")))
        #expect(try await session.prepareCommit(force: false).commit?.sequence == 2)
    }

    @Test("all empty segments resolve without invented text")
    func allEmptyAssembly() async throws {
        let session = makeSession(maxUnresolvedItems: 2)
        for sequence in 0..<2 {
            _ = try await session.appendSucceeded(
                byteCount: 8,
                containsSpeech: true)
            let commit = try #require(
                try await session.prepareCommit(force: false).commit)
            try await session.apply(
                .commitAcknowledged(
                    serverEventID: "ack-\(sequence)",
                    itemID: "item-\(sequence)",
                    predecessor: sequence == 0 ? .root : .item("item-0")))
            try await session.apply(
                .completed(
                    serverEventID: "terminal-\(sequence)",
                    itemID: "item-\(sequence)",
                    contentIndex: 0,
                    transcript: ""))
            #expect(commit.sequence == sequence)
        }
        try await session.sealCapture()
        #expect(try await session.resolvedSegments() == ["", ""])
        #expect(try await session.waitForRawTranscript().isEmpty)
    }

    @Test("assembly preserves empty segments and genuine repetition")
    func orderedLosslessAssembly() async throws {
        let session = makeSession(maxUnresolvedItems: 3)

        for sequence in 0..<3 {
            _ = try await session.appendSucceeded(
                byteCount: sequence == 2 ? 4 : 8,
                containsSpeech: true)
            let commit = try #require(
                try await session.prepareCommit(force: sequence == 2).commit)

            if sequence < 2 {
                try await session.apply(
                    .commitAcknowledged(
                        serverEventID: "ack-\(sequence)",
                        itemID: "item-\(sequence)",
                        predecessor: sequence == 0 ? .root : .item("item-0")))
            } else {
                try await session.apply(
                    .completed(
                        serverEventID: "terminal-2",
                        itemID: "item-2",
                        contentIndex: 0,
                        transcript: "go go now"))
                try await session.apply(
                    .commitAcknowledged(
                        serverEventID: "ack-2",
                        itemID: "item-2",
                        predecessor: .item("item-1")))
            }
            #expect(commit.sequence == sequence)
        }

        try await session.apply(
            .completed(
                serverEventID: "terminal-1",
                itemID: "item-1",
                contentIndex: 0,
                transcript: ""))
        try await session.apply(
            .completed(
                serverEventID: "terminal-0",
                itemID: "item-0",
                contentIndex: 0,
                transcript: "we should go"))
        try await session.sealCapture()

        #expect(
            try await session.resolvedSegments()
                == ["we should go", "", "go go now"])
        #expect(
            try await session.waitForRawTranscript()
                == "we should go  go go now")
    }

    @Test("completed response text overrides preceding deltas")
    func completedResponseTextIsAuthoritative() async throws {
        let session = makeSession()
        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        let commit = try #require(
            try await session.prepareCommit(force: false).commit)
        try await acknowledgeAndComplete(
            commit,
            session: session,
            previousItemID: nil)
        try await session.sealCapture()
        _ = try await session.waitForRawTranscript()
        try await session.beginPolish()
        _ = try await session.appendResponseDelta("Partial")
        try await session.completeResponseText("Final text.")
        try await session.completeResponse()

        #expect(try await session.waitForPolishedResponse() == "Final text.")
    }

    @Test("empty completed response text overrides preceding deltas")
    func emptyCompletedResponseTextIsAuthoritative() async throws {
        let session = makeSession()
        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        let commit = try #require(
            try await session.prepareCommit(force: false).commit)
        try await acknowledgeAndComplete(
            commit,
            session: session,
            previousItemID: nil)
        try await session.sealCapture()
        _ = try await session.waitForRawTranscript()
        try await session.beginPolish()
        _ = try await session.appendResponseDelta("Partial")
        try await session.completeResponseText("")
        try await session.completeResponse()

        #expect(try await session.waitForPolishedResponse().isEmpty)
    }

    private func acknowledgeAndComplete(
        _ commit: RealtimeTranscriptLedger.Commit,
        session: OpenAIRealtimeCommitSession,
        previousItemID: String?
    ) async throws {
        let itemID = "item-\(commit.sequence)"
        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-\(commit.sequence)",
                itemID: itemID,
                predecessor: previousItemID.map(RealtimeItemPredecessor.item)
                    ?? .root))
        try await session.apply(
            .completed(
                serverEventID: "terminal-\(commit.sequence)",
                itemID: itemID,
                contentIndex: 0,
                transcript: "segment-\(commit.sequence)"))
    }
}

@Suite("OpenAI Realtime multi-commit orchestration")
struct OpenAIRealtimeMultiCommitOrchestrationTests {

    @Test("waits for every item then polishes one ordered aggregate")
    func orderedAggregate() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 8,
                minimumUniqueBytesBeforeSilence: 8,
                trailingSilenceBytesRequired: 2),
            maxUnresolvedItems: 2)
        let exchange = InteractiveRealtimeExchange()
        let reader = Task {
            try await OpenAIStreamingProvider.readRealtimeSessionEvents(
                session: session,
                receive: { try await exchange.receive() })
        }

        let audio = Data((0..<20).map(UInt8.init))
        let audioTask = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                audio,
                session: session,
                send: { await exchange.send($0) })
        }

        await exchange.waitForCommitCount(1)
        await exchange.yield(
            #"{"type":"input_audio_buffer.committed","event_id":"ack-0","item_id":"item-0","previous_item_id":null}"#)
        await exchange.waitForCommitCount(2)
        await exchange.yield(
            #"{"type":"input_audio_buffer.committed","event_id":"ack-1","item_id":"item-1","previous_item_id":"item-0"}"#)
        try await audioTask.value

        let finishTask = Task {
            try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { await exchange.send($0) })
        }

        await exchange.yield(
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"terminal-1","item_id":"item-1","content_index":0,"transcript":""}"#)
        await exchange.waitForCommitCount(3)
        await exchange.yield(
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"terminal-2","item_id":"item-2","content_index":0,"transcript":"go go now"}"#)
        await exchange.yield(
            #"{"type":"input_audio_buffer.committed","event_id":"ack-2","item_id":"item-2","previous_item_id":"item-1"}"#)
        try await session.waitForAcknowledgement(sequence: 2)

        #expect(await exchange.sent().count == 9)
        await exchange.yield(
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"terminal-0","item_id":"item-0","content_index":0,"transcript":"we should go"}"#)
        await exchange.waitForSentCount(11)

        let sent = await exchange.sent()
        #expect(try sent.map(messageType) == [
            "input_audio_buffer.append",
            "input_audio_buffer.append",
            "input_audio_buffer.commit",
            "input_audio_buffer.append",
            "input_audio_buffer.append",
            "input_audio_buffer.commit",
            "input_audio_buffer.append",
            "input_audio_buffer.append",
            "input_audio_buffer.commit",
            "conversation.item.create",
            "response.create",
        ])
        #expect(try polishText(sent[9]) == "we should go  go go now")
        let clientEventIDs = try sent.map(eventID)
        #expect(clientEventIDs.allSatisfy { !$0.isEmpty })
        #expect(Set(clientEventIDs).count == sent.count)

        await exchange.yield(
            #"{"type":"response.output_text.delta","delta":"Polished "}"#)
        await exchange.yield(
            #"{"type":"response.output_text.delta","delta":"words."}"#)
        await exchange.yield(
            #"{"type":"response.done","response":{"status":"completed"}}"#)

        #expect(try await finishTask.value == "Polished words.")
        try await reader.value
    }

    @Test("an item failure rejects the whole aggregate before polish")
    func itemFailure() async throws {
        let session = makeOrchestrationSession()
        let exchange = InteractiveRealtimeExchange()
        let reader = Task {
            try await OpenAIStreamingProvider.readRealtimeSessionEvents(
                session: session,
                receive: { try await exchange.receive() })
        }
        let audioTask = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data(repeating: 1, count: 8),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForCommitCount(1)
        await exchange.yield(
            #"{"type":"input_audio_buffer.committed","event_id":"ack-0","item_id":"item-0","previous_item_id":null}"#)
        try await audioTask.value

        let finishTask = Task {
            try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.yield(
            #"{"type":"conversation.item.input_audio_transcription.failed","event_id":"failed-0","item_id":"item-0","content_index":0,"error":{"message":"audio rejected"}}"#)

        await #expect(throws: RealtimeTranscriptLedger.Failure.self) {
            _ = try await finishTask.value
        }
        await #expect(throws: RealtimeTranscriptLedger.Failure.self) {
            try await reader.value
        }
        #expect(await exchange.sent().count == 3)
    }

    @Test("all-empty committed items skip the polish transaction")
    func emptyAggregate() async throws {
        let session = makeOrchestrationSession()
        let exchange = InteractiveRealtimeExchange()
        let reader = Task {
            try await OpenAIStreamingProvider.readRealtimeSessionEvents(
                session: session,
                receive: { try await exchange.receive() })
        }
        let audioTask = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data(repeating: 0, count: 8),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForCommitCount(1)
        await exchange.yield(
            #"{"type":"input_audio_buffer.committed","event_id":"ack-0","item_id":"item-0","previous_item_id":null}"#)
        try await audioTask.value

        let finishTask = Task {
            try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.yield(
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"terminal-0","item_id":"item-0","content_index":0,"transcript":""}"#)

        #expect(try await finishTask.value.isEmpty)
        #expect(await exchange.sent().count == 3)
        await exchange.close()
        await #expect(throws: InteractiveRealtimeExchange.ExchangeFailure.self) {
            try await reader.value
        }
    }

    @Test("append send failure invalidates the complete candidate")
    func appendSendFailure() async {
        enum SendFailure: Error { case rejected }
        let session = makeOrchestrationSession()
        await #expect(throws: SendFailure.self) {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data(repeating: 1, count: 8),
                session: session,
                send: { _ in throw SendFailure.rejected })
        }
        await #expect(throws: SendFailure.self) {
            _ = try await session.waitForRawTranscript()
        }
    }

    @Test("commit send failure invalidates the complete candidate")
    func commitSendFailure() async {
        let session = makeOrchestrationSession()
        let transport = SelectiveFailingRealtimeSend(
            rejectedType: "input_audio_buffer.commit")

        await #expect(throws: SelectiveFailingRealtimeSend.SendFailure.self) {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data(repeating: 1, count: 8),
                session: session,
                send: { try await transport.send($0) })
        }
        await #expect(throws: SelectiveFailingRealtimeSend.SendFailure.self) {
            _ = try await session.waitForRawTranscript()
        }
        #expect(await transport.messageTypes().last == "input_audio_buffer.commit")
    }

    @Test("polish item send failure invalidates the complete candidate")
    func polishItemSendFailure() async throws {
        let session = try await resolvedSession()
        let transport = SelectiveFailingRealtimeSend(
            rejectedType: "conversation.item.create")

        await #expect(throws: SelectiveFailingRealtimeSend.SendFailure.self) {
            _ = try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { try await transport.send($0) })
        }
        await #expect(throws: SelectiveFailingRealtimeSend.SendFailure.self) {
            _ = try await session.waitForPolishedResponse()
        }
        #expect(
            await transport.messageTypes() == ["conversation.item.create"])
    }

    @Test("response request send failure invalidates the complete candidate")
    func responseCreateSendFailure() async throws {
        let session = try await resolvedSession()
        let transport = SelectiveFailingRealtimeSend(
            rejectedType: "response.create")

        await #expect(throws: SelectiveFailingRealtimeSend.SendFailure.self) {
            _ = try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { try await transport.send($0) })
        }
        await #expect(throws: SelectiveFailingRealtimeSend.SendFailure.self) {
            _ = try await session.waitForPolishedResponse()
        }
        #expect(
            await transport.messageTypes()
                == ["conversation.item.create", "response.create"])
    }

    @Test("structured server error invalidates every waiter before polish")
    func serverErrorInvalidatesSession() async throws {
        let session = makeOrchestrationSession()
        let exchange = InteractiveRealtimeExchange()
        let reader = Task {
            try await OpenAIStreamingProvider.readRealtimeSessionEvents(
                session: session,
                receive: { try await exchange.receive() })
        }
        let audio = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data(repeating: 1, count: 8),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForCommitCount(1)
        await exchange.yield(
            #"{"type":"error","event_id":"server-error-1","error":{"type":"invalid_request_error","code":"bad_audio","message":"commit rejected","event_id":"client-commit-1"}}"#)

        await #expect(throws: DictationError.self) {
            try await audio.value
        }
        await #expect(throws: DictationError.self) {
            try await reader.value
        }
        #expect(await exchange.sent().count == 3)
    }

    @Test("malformed terminal invalidates the aggregate before polish")
    func malformedTerminalInvalidatesSession() async throws {
        let session = makeOrchestrationSession()
        let exchange = InteractiveRealtimeExchange()
        let reader = Task {
            try await OpenAIStreamingProvider.readRealtimeSessionEvents(
                session: session,
                receive: { try await exchange.receive() })
        }
        let audio = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data(repeating: 1, count: 8),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForCommitCount(1)
        await exchange.yield(
            #"{"type":"input_audio_buffer.committed","event_id":"ack-0","item_id":"item-0","previous_item_id":null}"#)
        try await audio.value

        let finish = Task {
            try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.yield(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-0","content_index":0,"transcript":"raw"}"#)

        await #expect(throws: DictationError.self) {
            _ = try await finish.value
        }
        await #expect(throws: DictationError.self) {
            try await reader.value
        }
        #expect(await exchange.sent().count == 3)
    }

    @Test("failed response cannot return preceding polished text")
    func failedResponseInvalidatesPartialText() async throws {
        let session = makeOrchestrationSession()
        let exchange = InteractiveRealtimeExchange()
        let reader = Task {
            try await OpenAIStreamingProvider.readRealtimeSessionEvents(
                session: session,
                receive: { try await exchange.receive() })
        }
        let audio = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data(repeating: 1, count: 8),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForCommitCount(1)
        await exchange.yield(
            #"{"type":"input_audio_buffer.committed","event_id":"ack-0","item_id":"item-0","previous_item_id":null}"#)
        await exchange.yield(
            #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"terminal-0","item_id":"item-0","content_index":0,"transcript":"raw"}"#)
        try await audio.value

        let finish = Task {
            try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForSentCount(5)
        await exchange.yield(
            #"{"type":"response.output_text.delta","delta":"Partial"}"#)
        await exchange.yield(
            #"{"type":"response.output_text.done","text":"Final text."}"#)
        await exchange.yield(
            #"{"type":"response.done","response":{"status":"failed"}}"#)

        await #expect(throws: DictationError.self) {
            _ = try await finish.value
        }
        await #expect(throws: DictationError.self) {
            try await reader.value
        }
        #expect(await exchange.sent().count == 5)
    }

    @Test("unaligned audio invalidates the complete candidate")
    func unalignedAudioFailure() async {
        let session = makeOrchestrationSession()
        await #expect(
            throws: OpenAIRealtimeCommitSession.Failure
                .unalignedAudioByteCount(3)
        ) {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data(repeating: 1, count: 3),
                session: session,
                send: { _ in
                    Issue.record("unaligned audio must not be sent")
                })
        }
        await #expect(
            throws: OpenAIRealtimeCommitSession.Failure
                .unalignedAudioByteCount(3)
        ) {
            _ = try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { _ in
                    Issue.record("an invalid candidate must not be polished")
                })
        }
    }

    @Test("concurrent audio calls serialize transport writes")
    func concurrentAudioSerialization() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 100,
                minimumUniqueBytesBeforeSilence: 100,
                trailingSilenceBytesRequired: 2),
            maxUnresolvedItems: 2)
        let exchange = BlockingRealtimeSend()
        let secondStart = AsyncStartProbe()

        let first = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data([1, 0]),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForSentCount(1)

        let second = Task {
            await secondStart.markStarted()
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data([2, 0]),
                session: session,
                send: { await exchange.send($0) })
        }
        await secondStart.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await exchange.sentCount() == 1)
        await exchange.releaseFirst()
        try await first.value
        try await second.value
        #expect(await exchange.sentCount() == 2)
    }

    @Test("cancelled queued audio never reaches the transport")
    func cancelledQueuedAudio() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 100,
                minimumUniqueBytesBeforeSilence: 100,
                trailingSilenceBytesRequired: 2),
            maxUnresolvedItems: 2)
        let exchange = BlockingRealtimeSend()

        let first = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data([1, 0]),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForSentCount(1)

        let cancelled = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data([2, 0]),
                session: session,
                send: { await exchange.send($0) })
        }
        cancelled.cancel()
        await exchange.releaseFirst()

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        do {
            try await first.value
        } catch is CancellationError {
            // The queued cancellation may invalidate the current owner first.
        }
        #expect(await exchange.sentCount() == 1)
    }

    @Test("cancellation during an append cannot report success")
    func cancelledInFlightAppend() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 100,
                minimumUniqueBytesBeforeSilence: 100,
                trailingSilenceBytesRequired: 2),
            maxUnresolvedItems: 2)
        let exchange = BlockingRealtimeSend()
        let audio = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data([1, 0]),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForSentCount(1)

        audio.cancel()
        await exchange.releaseFirst()

        await #expect(throws: CancellationError.self) {
            try await audio.value
        }
        await #expect(throws: CancellationError.self) {
            _ = try await session.maximumAppendByteCount(requested: 2)
        }
    }

    @Test("cancelled acknowledgement wait cannot report send success")
    func cancelledAcknowledgementWait() async throws {
        let session = makeOrchestrationSession()
        let exchange = InteractiveRealtimeExchange()
        let audio = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data(repeating: 1, count: 8),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForCommitCount(1)

        audio.cancel()
        do {
            try await session.apply(
                .commitAcknowledged(
                    serverEventID: "ack-after-cancel",
                    itemID: "item-0",
                    predecessor: .root))
        } catch is CancellationError {
            // Cancellation may invalidate the session before this rescue event.
        }

        await #expect(throws: CancellationError.self) {
            try await audio.value
        }
    }

    @Test("finish waits for an in-flight append transaction")
    func finishSerializesWithAudio() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 100,
                minimumUniqueBytesBeforeSilence: 100,
                trailingSilenceBytesRequired: 2),
            maxUnresolvedItems: 2)
        let exchange = BlockingRealtimeSend()
        let finishCompletion = AsyncStartProbe()

        let audio = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                Data([1, 0]),
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForSentCount(1)

        let finish = Task {
            let result = try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { await exchange.send($0) })
            await finishCompletion.markStarted()
            return result
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!(await finishCompletion.hasStarted()))

        await exchange.releaseFirst()
        try await audio.value
        await exchange.waitForSentCount(2)
        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-0",
                itemID: "item-0",
                predecessor: .root))
        try await session.apply(
            .completed(
                serverEventID: "terminal-0",
                itemID: "item-0",
                contentIndex: 0,
                transcript: ""))

        #expect(try await finish.value.isEmpty)
        #expect(await finishCompletion.hasStarted())
    }

    @Test("wire audio is invariant to capture callback fragmentation")
    func fragmentationInvariantAudio() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 100,
                minimumUniqueBytesBeforeSilence: 100,
                trailingSilenceBytesRequired: 2),
            maxUnresolvedItems: 2)
        let exchange = InteractiveRealtimeExchange()
        let first = pcm16([0, 300, 600])
        let second = pcm16([900, 1_200, 1_500])

        try await OpenAIStreamingProvider.sendRealtimeAudio(
            first,
            session: session,
            send: { await exchange.send($0) })
        try await OpenAIStreamingProvider.sendRealtimeAudio(
            second,
            session: session,
            send: { await exchange.send($0) })

        let finish = Task {
            try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForCommitCount(1)
        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-0",
                itemID: "item-0",
                predecessor: .root))
        try await session.apply(
            .completed(
                serverEventID: "terminal-0",
                itemID: "item-0",
                contentIndex: 0,
                transcript: ""))
        #expect(try await finish.value.isEmpty)

        let appendPayloads = try await exchange.sent()
            .filter { try messageType($0) == "input_audio_buffer.append" }
            .map(audioPayload)
        let wireAudio = appendPayloads.reduce(into: Data()) { result, payload in
            result.append(payload)
        }
        #expect(
            wireAudio
                == AudioResampler.resample16kTo24k(first + second))
    }

    @Test("hard boundaries preserve each source slice on the wire")
    func hardBoundaryWireCoverage() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 8,
                minimumUniqueBytesBeforeSilence: 8,
                trailingSilenceBytesRequired: 2),
            maxUnresolvedItems: 3)
        let exchange = InteractiveRealtimeExchange()
        let source = Data((0..<20).map(UInt8.init))

        let audio = Task {
            try await OpenAIStreamingProvider.sendRealtimeAudio(
                source,
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForCommitCount(1)
        try await acknowledge(sequence: 0, session: session)
        await exchange.waitForCommitCount(2)
        try await acknowledge(sequence: 1, session: session)
        try await audio.value

        let finish = Task {
            try await OpenAIStreamingProvider.finishRealtimeSession(
                session: session,
                send: { await exchange.send($0) })
        }
        await exchange.waitForCommitCount(3)
        try await acknowledge(sequence: 2, session: session)
        for sequence in [2, 0, 1] {
            try await session.apply(
                .completed(
                    serverEventID: "terminal-\(sequence)",
                    itemID: "item-\(sequence)",
                    contentIndex: 0,
                    transcript: ""))
        }
        #expect(try await finish.value.isEmpty)

        let items = try await committedAudioItems(in: exchange.sent())
        let ranges = [0..<8, 8..<16, 16..<20]
        #expect(items.count == ranges.count)
        for (item, range) in zip(items, ranges) {
            #expect(
                item
                    == AudioResampler.resample16kTo24k(
                        source.subdata(in: range)))
        }
    }

    @Test("a missing server event fails the session at its deadline")
    func serverEventTimeout() async throws {
        let session = makeOrchestrationSession()
        let probe = TimeoutProbe()
        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        let commit = try #require(
            try await session.prepareCommit(force: false).commit)

        await #expect(throws: DictationError.self) {
            try await OpenAIStreamingProvider.withRealtimeSessionTimeout(
                seconds: 0.01,
                waitingFor: "commit acknowledgement",
                session: session,
                onTimeout: { await probe.markTimedOut() },
                operation: {
                    try await session.waitForAcknowledgement(
                        sequence: commit.sequence)
                })
        }
        #expect(await probe.didTimeOut())
        await #expect(throws: DictationError.self) {
            _ = try await session.waitForRawTranscript()
        }
    }

    private func makeOrchestrationSession() -> OpenAIRealtimeCommitSession {
        OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 8,
                minimumUniqueBytesBeforeSilence: 8,
                trailingSilenceBytesRequired: 2),
            maxUnresolvedItems: 2)
    }

    private func resolvedSession() async throws -> OpenAIRealtimeCommitSession {
        let session = makeOrchestrationSession()
        _ = try await session.appendSucceeded(
            byteCount: 8,
            containsSpeech: true)
        _ = try #require(
            try await session.prepareCommit(force: false).commit)
        try await acknowledge(sequence: 0, session: session)
        try await session.apply(
            .completed(
                serverEventID: "terminal-0",
                itemID: "item-0",
                contentIndex: 0,
                transcript: "raw words"))
        return session
    }

    private func acknowledge(
        sequence: Int,
        session: OpenAIRealtimeCommitSession
    ) async throws {
        try await session.apply(
            .commitAcknowledged(
                serverEventID: "ack-\(sequence)",
                itemID: "item-\(sequence)",
                predecessor: sequence == 0
                    ? .root
                    : .item("item-\(sequence - 1)")))
    }

    private func committedAudioItems(
        in messages: [String]
    ) throws -> [Data] {
        var items: [Data] = []
        var current = Data()
        for message in messages {
            switch try messageType(message) {
            case "input_audio_buffer.append":
                current.append(try audioPayload(message))
            case "input_audio_buffer.commit":
                items.append(current)
                current = Data()
            default:
                break
            }
        }
        #expect(current.isEmpty)
        return items
    }

    private func messageType(_ text: String) throws -> String {
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(text.utf8)) as? [String: Any])
        return try #require(object["type"] as? String)
    }

    private func polishText(_ text: String) throws -> String {
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(text.utf8)) as? [String: Any])
        let item = try #require(object["item"] as? [String: Any])
        let content = try #require(item["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    private func audioPayload(_ text: String) throws -> Data {
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(text.utf8)) as? [String: Any])
        let encoded = try #require(object["audio"] as? String)
        return try #require(Data(base64Encoded: encoded))
    }

    private func eventID(_ text: String) throws -> String {
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(text.utf8)) as? [String: Any])
        return try #require(object["event_id"] as? String)
    }

    private func pcm16(_ samples: [Int16]) -> Data {
        samples.reduce(into: Data()) { result, sample in
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                result.append(contentsOf: $0)
            }
        }
    }
}

private actor TimeoutProbe {
    private var timedOut = false

    func markTimedOut() {
        timedOut = true
    }

    func didTimeOut() -> Bool {
        timedOut
    }
}

private actor InteractiveRealtimeExchange {
    enum ExchangeFailure: Error {
        case closed
    }

    private var inbound: [String] = []
    private var receivers: [CheckedContinuation<String, any Error>] = []
    private var outbound: [String] = []
    private var isClosed = false
    private var sentCountWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var commitCountWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func receive() async throws -> String {
        if isClosed { throw ExchangeFailure.closed }
        if !inbound.isEmpty {
            return inbound.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receivers.append(continuation)
        }
    }

    func yield(_ event: String) {
        if !receivers.isEmpty {
            receivers.removeFirst().resume(returning: event)
        } else {
            inbound.append(event)
        }
    }

    func send(_ message: String) {
        outbound.append(message)
        let ready = sentCountWaiters.filter { outbound.count >= $0.count }
        sentCountWaiters.removeAll { outbound.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
        if message.contains(#""type":"input_audio_buffer.commit""#) {
            let count = outbound.filter {
                $0.contains(#""type":"input_audio_buffer.commit""#)
            }.count
            let ready = commitCountWaiters.filter { count >= $0.count }
            commitCountWaiters.removeAll { count >= $0.count }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func sent() -> [String] {
        outbound
    }

    func waitForSentCount(_ count: Int) async {
        if outbound.count >= count { return }
        await withCheckedContinuation { continuation in
            sentCountWaiters.append((count, continuation))
        }
    }

    func waitForCommitCount(_ count: Int) async {
        let existing = outbound.filter {
            $0.contains(#""type":"input_audio_buffer.commit""#)
        }.count
        if existing >= count { return }
        await withCheckedContinuation { continuation in
            commitCountWaiters.append((count, continuation))
        }
    }

    func close() {
        isClosed = true
        let receivers = self.receivers
        self.receivers.removeAll()
        for receiver in receivers {
            receiver.resume(throwing: ExchangeFailure.closed)
        }
    }
}

private actor AsyncStartProbe {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func hasStarted() -> Bool {
        started
    }
}

private actor BlockingRealtimeSend {
    private var messages: [String] = []
    private var sentCountWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var firstSendContinuation: CheckedContinuation<Void, Never>?
    private var firstSendReleased = false

    func send(_ message: String) async {
        messages.append(message)
        let ready = sentCountWaiters.filter { messages.count >= $0.count }
        sentCountWaiters.removeAll { messages.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }

        if messages.count == 1, !firstSendReleased {
            await withCheckedContinuation { continuation in
                firstSendContinuation = continuation
            }
        }
    }

    func waitForSentCount(_ count: Int) async {
        if messages.count >= count { return }
        await withCheckedContinuation { continuation in
            sentCountWaiters.append((count, continuation))
        }
    }

    func sentCount() -> Int {
        messages.count
    }

    func releaseFirst() {
        firstSendReleased = true
        firstSendContinuation?.resume()
        firstSendContinuation = nil
    }
}

private actor SelectiveFailingRealtimeSend {
    enum SendFailure: Error {
        case rejected
    }

    private let rejectedType: String
    private var types: [String] = []

    init(rejectedType: String) {
        self.rejectedType = rejectedType
    }

    func send(_ message: String) throws {
        let data = Data(message.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        let type = (object as? [String: Any])?["type"] as? String ?? ""
        types.append(type)
        if type == rejectedType { throw SendFailure.rejected }
    }

    func messageTypes() -> [String] {
        types
    }
}

private extension OpenAIRealtimeCommitSession.CommitPreparation {
    var commit: RealtimeTranscriptLedger.Commit? {
        guard case .ready(let commit) = self else { return nil }
        return commit
    }
}
