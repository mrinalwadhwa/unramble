import Testing

@testable import FreeFlowKit

@Suite("RealtimeTranscriptLedger")
struct RealtimeTranscriptLedgerTests {

    @Test("Resolves out-of-order completions in commit order")
    func resolvesOutOfOrderCompletions() throws {
        var ledger = RealtimeTranscriptLedger()

        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)

        _ = try ledger.recordCommit(coverageRange: 100..<200)
        try ledger.acknowledgeCommit(
            itemID: "item-2",
            previousItemID: "item-1")

        try ledger.completeTranscription(
            itemID: "item-2",
            transcript: "second")
        try ledger.completeTranscription(
            itemID: "item-1",
            transcript: "first")
        try ledger.seal(expectedCoverageEnd: 200)

        let resolved = try ledger.resolvedItems()
        #expect(resolved.map(\.itemID) == ["item-1", "item-2"])
        #expect(resolved.map(\.coverageRange) == [0..<100, 100..<200])
        #expect(resolved.map(\.transcript) == ["first", "second"])
    }

    @Test("Buffers a completion that arrives before its commit acknowledgement")
    func completionBeforeAcknowledgement() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)

        try ledger.completeTranscription(
            itemID: "item-1",
            transcript: "early completion")
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)
        try ledger.seal(expectedCoverageEnd: 100)

        #expect(try ledger.resolvedItems().map(\.transcript) == ["early completion"])
    }

    @Test("A failed item prevents the ledger from resolving a prefix")
    func failedItemPreventsResolution() throws {
        var ledger = RealtimeTranscriptLedger()

        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)
        try ledger.completeTranscription(
            itemID: "item-1",
            transcript: "completed prefix")

        _ = try ledger.recordCommit(coverageRange: 100..<200)
        try ledger.acknowledgeCommit(
            itemID: "item-2",
            previousItemID: "item-1")
        try ledger.failTranscription(
            itemID: "item-2",
            message: "audio rejected")
        try ledger.seal(expectedCoverageEnd: 200)

        do {
            _ = try ledger.resolvedItems()
            Issue.record("Expected the failed item to prevent resolution")
        } catch let failure as RealtimeTranscriptLedger.Failure {
            #expect(
                failure == .transcriptionFailed(
                    itemID: "item-2",
                    message: "audio rejected"))
        }
    }

    @Test("A known later failure outranks an earlier incomplete item")
    func laterFailureOutranksIncompleteItem() throws {
        var ledger = RealtimeTranscriptLedger()

        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)

        _ = try ledger.recordCommit(coverageRange: 100..<200)
        try ledger.acknowledgeCommit(
            itemID: "item-2",
            previousItemID: "item-1")
        try ledger.failTranscription(
            itemID: "item-2",
            message: "later item failed")
        try ledger.seal(expectedCoverageEnd: 200)

        #expect(
            capturedFailure {
                try ledger.resolvedItems()
            } == .transcriptionFailed(
                itemID: "item-2",
                message: "later item failed"))
    }

    @Test("Rejects gaps and overlaps in unique captured coverage")
    func rejectsNoncontiguousAudio() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)

        #expect(
            capturedFailure {
                try ledger.recordCommit(coverageRange: 120..<200)
            } == .noncontiguousCoverage(expectedStart: 100, actualStart: 120))
        #expect(
            capturedFailure {
                try ledger.recordCommit(coverageRange: 80..<200)
            } == .noncontiguousCoverage(expectedStart: 100, actualStart: 80))
    }

    @Test("Retains replayed audio separately from unique coverage")
    func retainsSubmittedAudioRange() throws {
        var ledger = RealtimeTranscriptLedger()

        _ = try ledger.recordCommit(
            coverageRange: 0..<100,
            submittedRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)
        try ledger.completeTranscription(
            itemID: "item-1",
            transcript: "first")

        _ = try ledger.recordCommit(
            coverageRange: 100..<200,
            submittedRange: 80..<200)
        try ledger.acknowledgeCommit(
            itemID: "item-2",
            previousItemID: "item-1")
        try ledger.completeTranscription(
            itemID: "item-2",
            transcript: "second")
        try ledger.seal(expectedCoverageEnd: 200)

        let resolved = try ledger.resolvedItems()
        #expect(resolved.map(\.coverageRange) == [0..<100, 100..<200])
        #expect(resolved.map(\.submittedRange) == [0..<100, 80..<200])
    }

    @Test("Rejects submitted audio that does not contain exactly its coverage")
    func rejectsInvalidSubmittedAudioRange() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(
            coverageRange: 0..<100,
            submittedRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)

        #expect(
            capturedFailure {
                try ledger.recordCommit(
                    coverageRange: 100..<200,
                    submittedRange: 120..<200)
            } == .invalidSubmittedRange(
                coverageRange: 100..<200,
                submittedRange: 120..<200))
        #expect(
            capturedFailure {
                try ledger.recordCommit(
                    coverageRange: 100..<200,
                    submittedRange: 80..<190)
            } == .invalidSubmittedRange(
                coverageRange: 100..<200,
                submittedRange: 80..<190))
        #expect(
            capturedFailure {
                try ledger.recordCommit(
                    coverageRange: 100..<200,
                    submittedRange: 80..<220)
            } == .invalidSubmittedRange(
                coverageRange: 100..<200,
                submittedRange: 80..<220))
        #expect(
            capturedFailure {
                try ledger.recordCommit(
                    coverageRange: 100..<200,
                    submittedRange: -20..<200)
            } == .invalidSubmittedRange(
                coverageRange: 100..<200,
                submittedRange: -20..<200))
    }

    @Test("Rejects an empty captured coverage range")
    func rejectsEmptyCoverage() {
        var ledger = RealtimeTranscriptLedger()

        #expect(
            capturedFailure {
                try ledger.recordCommit(coverageRange: 0..<0)
            } == .emptyCoverageRange)
    }

    @Test("Allows only one unacknowledged commit")
    func allowsOneUnacknowledgedCommit() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)

        #expect(
            capturedFailure {
                try ledger.recordCommit(coverageRange: 100..<200)
            } == .acknowledgementPending)
    }

    @Test("Rejects an acknowledgement when no commit is pending")
    func rejectsUnexpectedAcknowledgement() {
        var ledger = RealtimeTranscriptLedger()

        #expect(
            capturedFailure {
                try ledger.acknowledgeCommit(
                    itemID: "item-1",
                    previousItemID: nil)
            } == .unexpectedAcknowledgement("item-1"))
    }

    @Test("Rejects conversation items interleaved between audio commits")
    func rejectsBrokenItemChain() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)
        _ = try ledger.recordCommit(coverageRange: 100..<200)

        #expect(
            capturedFailure {
                try ledger.acknowledgeCommit(
                    itemID: "item-2",
                    previousItemID: "wrong-item")
            } == .invalidItemChain(
                sequence: 1,
                expectedPreviousItemID: "item-1",
                actualPreviousItemID: "wrong-item"))
    }

    @Test("Requires a fresh conversation for the first audio commit")
    func requiresFreshConversation() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)

        #expect(
            capturedFailure {
                try ledger.acknowledgeCommit(
                    itemID: "item-1",
                    previousItemID: "existing-item")
            } == .invalidItemChain(
                sequence: 0,
                expectedPreviousItemID: nil,
                actualPreviousItemID: "existing-item"))
    }

    @Test("Final commit resolves when seal precedes its server events")
    func sealBeforeFinalServerEvents() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)

        try ledger.seal(expectedCoverageEnd: 100)
        #expect(capturedFailure { try ledger.resolvedItems() } == .incomplete)

        try ledger.acknowledgeCommit(
            itemID: "item-final",
            previousItemID: nil)
        try ledger.completeTranscription(
            itemID: "item-final",
            transcript: "final words")

        #expect(try ledger.resolvedItems().map(\.transcript) == ["final words"])
    }

    @Test("Never resolves a completed prefix while another item is pending")
    func doesNotResolvePrefix() throws {
        var ledger = RealtimeTranscriptLedger()

        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)
        try ledger.completeTranscription(
            itemID: "item-1",
            transcript: "completed prefix")

        _ = try ledger.recordCommit(coverageRange: 100..<200)
        try ledger.acknowledgeCommit(
            itemID: "item-2",
            previousItemID: "item-1")
        try ledger.seal(expectedCoverageEnd: 200)

        #expect(capturedFailure { try ledger.resolvedItems() } == .incomplete)
    }

    @Test("Preserves empty segments and repeated words exactly")
    func preservesExactSegments() throws {
        var ledger = RealtimeTranscriptLedger()
        let transcripts = ["repeat", "", "repeat"]
        var previousItemID: String?

        for index in transcripts.indices {
            let start = index * 100
            let itemID = "item-\(index + 1)"
            _ = try ledger.recordCommit(
                coverageRange: start..<(start + 100))
            try ledger.acknowledgeCommit(
                itemID: itemID,
                previousItemID: previousItemID)
            try ledger.completeTranscription(
                itemID: itemID,
                transcript: transcripts[index])
            previousItemID = itemID
        }
        try ledger.seal(expectedCoverageEnd: 300)

        #expect(try ledger.resolvedItems().map(\.transcript) == transcripts)
    }

    @Test("Treats identical acknowledgement and completion replays as no-ops")
    func exactReplaysAreIdempotent() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)

        for _ in 0..<2 {
            try ledger.acknowledgeCommit(
                itemID: "item-1",
                previousItemID: nil)
            try ledger.completeTranscription(
                itemID: "item-1",
                transcript: "same text")
        }
        try ledger.seal(expectedCoverageEnd: 100)

        #expect(try ledger.resolvedItems().map(\.transcript) == ["same text"])
    }

    @Test("A replayed old acknowledgement cannot consume the next commit")
    func oldAcknowledgementDoesNotConsumeNextCommit() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)

        _ = try ledger.recordCommit(coverageRange: 100..<200)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)
        try ledger.acknowledgeCommit(
            itemID: "item-2",
            previousItemID: "item-1")
        try ledger.completeTranscription(itemID: "item-1", transcript: "one")
        try ledger.completeTranscription(itemID: "item-2", transcript: "two")
        try ledger.seal(expectedCoverageEnd: 200)

        #expect(try ledger.resolvedItems().map(\.transcript) == ["one", "two"])
    }

    @Test("Rejects a conflicting replay of an acknowledged item")
    func rejectsConflictingAcknowledgementReplay() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)

        #expect(
            capturedFailure {
                try ledger.acknowledgeCommit(
                    itemID: "item-1",
                    previousItemID: "different-item")
            } == .conflictingAcknowledgement("item-1"))
    }

    @Test("Rejects an acknowledgement that cannot own an early terminal event")
    func rejectsMismatchedEarlyTerminal() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.completeTranscription(
            itemID: "item-early",
            transcript: "early")

        #expect(
            capturedFailure {
                try ledger.acknowledgeCommit(
                    itemID: "item-other",
                    previousItemID: nil)
            } == .unknownItemID("item-early"))
    }

    @Test("Rejects conflicting terminal events for one item")
    func rejectsConflictingTerminalEvents() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)
        try ledger.completeTranscription(
            itemID: "item-1",
            transcript: "first value")

        #expect(
            capturedFailure {
                try ledger.completeTranscription(
                    itemID: "item-1",
                    transcript: "different value")
            } == .conflictingTerminal("item-1"))
        #expect(
            capturedFailure {
                try ledger.failTranscription(
                    itemID: "item-1",
                    message: "late failure")
            } == .conflictingTerminal("item-1"))
    }

    @Test("Buffers a transcription failure that precedes acknowledgement")
    func failureBeforeAcknowledgement() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)

        try ledger.failTranscription(
            itemID: "item-1",
            message: "early failure")
        try ledger.seal(expectedCoverageEnd: 100)

        #expect(
            capturedFailure {
                try ledger.resolvedItems()
            } == .transcriptionFailed(
                itemID: "item-1",
                message: "early failure"))

        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)

        #expect(
            capturedFailure {
                try ledger.resolvedItems()
            } == .transcriptionFailed(
                itemID: "item-1",
                message: "early failure"))
    }

    @Test("Requires the sealed audio end to match committed coverage")
    func sealRequiresExactCoverage() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)

        #expect(
            capturedFailure {
                try ledger.seal(expectedCoverageEnd: 99)
            } == .coverageEndMismatch(expected: 99, actual: 100))
    }

    @Test("Does not resolve before unique coverage is sealed")
    func doesNotResolveBeforeSeal() throws {
        var ledger = RealtimeTranscriptLedger()
        _ = try ledger.recordCommit(coverageRange: 0..<100)
        try ledger.acknowledgeCommit(
            itemID: "item-1",
            previousItemID: nil)
        try ledger.completeTranscription(
            itemID: "item-1",
            transcript: "complete but unsealed")

        #expect(capturedFailure { try ledger.resolvedItems() } == .notSealed)
    }

    @Test("Rejects commits after the ledger is sealed")
    func rejectsCommitAfterSeal() throws {
        var ledger = RealtimeTranscriptLedger()
        try ledger.seal(expectedCoverageEnd: 0)

        #expect(
            capturedFailure {
                try ledger.recordCommit(coverageRange: 0..<100)
            } == .alreadySealed)
    }
}

private func capturedFailure<T>(
    _ operation: () throws -> T
) -> RealtimeTranscriptLedger.Failure? {
    do {
        _ = try operation()
        Issue.record("Expected RealtimeTranscriptLedger.Failure")
        return nil
    } catch let failure as RealtimeTranscriptLedger.Failure {
        return failure
    } catch {
        Issue.record("Expected ledger failure, got \(error)")
        return nil
    }
}

private extension RealtimeTranscriptLedger {
    mutating func recordCommit(
        coverageRange: Range<Int>
    ) throws -> Commit {
        try recordCommit(
            coverageRange: coverageRange,
            submittedRange: coverageRange)
    }
}
