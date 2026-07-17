/// Tracks the captured-audio source ranges and server transcription item for
/// every Realtime commit. Ranges use byte offsets in the original 16 kHz mono
/// PCM16 stream, before provider resampling. Unique coverage never overlaps or
/// leaves gaps. A commit scheduler may resend an already covered suffix as
/// context; `submittedRange` retains the exact source slice used for that item.
/// The scheduler remains responsible for PCM-frame-aligned range boundaries.
///
/// The item-chain check assumes a fresh Realtime conversation with no text or
/// response items inserted between audio commits. Polish starts only after all
/// audio items resolve. The ledger is a value type so one session owner can
/// serialize mutations without mixing ordering logic with WebSocket I/O.
struct RealtimeTranscriptLedger: Sendable {

    struct Commit: Equatable, Sendable {
        let sequence: Int
        let coverageRange: Range<Int>
        let submittedRange: Range<Int>
    }

    struct ResolvedItem: Equatable, Sendable {
        let commit: Commit
        let itemID: String
        let previousItemID: String?
        let transcript: String

        var coverageRange: Range<Int> { commit.coverageRange }
        var submittedRange: Range<Int> { commit.submittedRange }
    }

    enum Failure: Error, Equatable {
        case emptyCoverageRange
        case noncontiguousCoverage(expectedStart: Int, actualStart: Int)
        case invalidSubmittedRange(
            coverageRange: Range<Int>,
            submittedRange: Range<Int>)
        case acknowledgementPending
        case unexpectedAcknowledgement(String)
        case invalidItemID
        case conflictingAcknowledgement(String)
        case invalidItemChain(
            sequence: Int,
            expectedPreviousItemID: String?,
            actualPreviousItemID: String?)
        case unknownItemID(String)
        case conflictingTerminal(String)
        case transcriptionFailed(itemID: String, message: String)
        case alreadySealed
        case coverageEndMismatch(expected: Int, actual: Int)
        case notSealed
        case incomplete
    }

    private struct Entry: Sendable {
        let commit: Commit
        var itemID: String?
        var predecessor: RealtimeItemPredecessor?
        var terminal: Terminal?
    }

    private enum Terminal: Equatable, Sendable {
        case completed(String)
        case failed(String)
    }

    private struct PendingTerminal: Equatable, Sendable {
        let itemID: String
        let terminal: Terminal
    }

    private var entries: [Entry] = []
    private var pendingAcknowledgement: Int?
    private var pendingTerminal: PendingTerminal?
    private var sealedCoverageEnd: Int?

    mutating func recordCommit(
        coverageRange: Range<Int>,
        submittedRange: Range<Int>
    ) throws -> Commit {
        guard sealedCoverageEnd == nil else { throw Failure.alreadySealed }
        guard !coverageRange.isEmpty else { throw Failure.emptyCoverageRange }
        guard pendingAcknowledgement == nil else {
            throw Failure.acknowledgementPending
        }

        let expectedStart = entries.last?.commit.coverageRange.upperBound ?? 0
        guard coverageRange.lowerBound == expectedStart else {
            throw Failure.noncontiguousCoverage(
                expectedStart: expectedStart,
                actualStart: coverageRange.lowerBound)
        }
        guard submittedRange.lowerBound >= 0,
            submittedRange.lowerBound <= coverageRange.lowerBound,
            submittedRange.upperBound == coverageRange.upperBound
        else {
            throw Failure.invalidSubmittedRange(
                coverageRange: coverageRange,
                submittedRange: submittedRange)
        }

        let commit = Commit(
            sequence: entries.count,
            coverageRange: coverageRange,
            submittedRange: submittedRange)
        entries.append(
            Entry(
                commit: commit,
                itemID: nil,
                predecessor: nil,
                terminal: nil))
        pendingAcknowledgement = commit.sequence
        return commit
    }

    @discardableResult
    mutating func acknowledgeCommit(
        itemID: String,
        previousItemID: String?
    ) throws -> Commit {
        try acknowledgeCommit(
            itemID: itemID,
            predecessor: previousItemID.map(RealtimeItemPredecessor.item)
                ?? .root)
    }

    @discardableResult
    mutating func acknowledgeCommit(
        itemID: String,
        predecessor: RealtimeItemPredecessor
    ) throws -> Commit {
        guard !itemID.isEmpty else { throw Failure.invalidItemID }

        if let existingIndex = entries.firstIndex(where: { $0.itemID == itemID }) {
            guard entries[existingIndex].predecessor == predecessor
            else {
                throw Failure.conflictingAcknowledgement(itemID)
            }
            return entries[existingIndex].commit
        }

        guard let sequence = pendingAcknowledgement else {
            throw Failure.unexpectedAcknowledgement(itemID)
        }
        if let pendingTerminal, pendingTerminal.itemID != itemID {
            throw Failure.unknownItemID(pendingTerminal.itemID)
        }

        let expectedPreviousItemID = sequence == 0
            ? nil
            : entries[sequence - 1].itemID
        let predecessorMatches: Bool
        switch predecessor {
        case .unspecified:
            predecessorMatches = true
        case .root:
            predecessorMatches = expectedPreviousItemID == nil
        case .item(let actualPreviousItemID):
            predecessorMatches = actualPreviousItemID == expectedPreviousItemID
        }
        guard predecessorMatches else {
            throw Failure.invalidItemChain(
                sequence: sequence,
                expectedPreviousItemID: expectedPreviousItemID,
                actualPreviousItemID: predecessor.itemID)
        }

        entries[sequence].itemID = itemID
        entries[sequence].predecessor = predecessor
        if let pendingTerminal {
            entries[sequence].terminal = pendingTerminal.terminal
            self.pendingTerminal = nil
        }
        pendingAcknowledgement = nil
        return entries[sequence].commit
    }

    mutating func completeTranscription(
        itemID: String,
        transcript: String
    ) throws {
        try recordTerminal(
            itemID: itemID,
            terminal: .completed(transcript))
    }

    mutating func failTranscription(
        itemID: String,
        message: String
    ) throws {
        try recordTerminal(
            itemID: itemID,
            terminal: .failed(message))
    }

    mutating func seal(expectedCoverageEnd: Int) throws {
        guard sealedCoverageEnd == nil else { throw Failure.alreadySealed }
        let actualEnd = entries.last?.commit.coverageRange.upperBound ?? 0
        guard actualEnd == expectedCoverageEnd else {
            throw Failure.coverageEndMismatch(
                expected: expectedCoverageEnd,
                actual: actualEnd)
        }
        sealedCoverageEnd = expectedCoverageEnd
    }

    func resolvedItems() throws -> [ResolvedItem] {
        guard sealedCoverageEnd != nil else { throw Failure.notSealed }

        for entry in entries {
            if case .failed(let message)? = entry.terminal,
                let itemID = entry.itemID
            {
                throw Failure.transcriptionFailed(
                    itemID: itemID,
                    message: message)
            }
        }
        if let pendingTerminal,
            case .failed(let message) = pendingTerminal.terminal
        {
            throw Failure.transcriptionFailed(
                itemID: pendingTerminal.itemID,
                message: message)
        }

        guard pendingAcknowledgement == nil else { throw Failure.incomplete }

        return try entries.map { entry in
            guard let itemID = entry.itemID, let terminal = entry.terminal else {
                throw Failure.incomplete
            }
            let transcript: String
            switch terminal {
            case .completed(let value):
                transcript = value
            case .failed(let message):
                throw Failure.transcriptionFailed(
                    itemID: itemID,
                    message: message)
            }
            return ResolvedItem(
                commit: entry.commit,
                itemID: itemID,
                previousItemID: entry.predecessor?.itemID,
                transcript: transcript)
        }
    }

    private mutating func recordTerminal(
        itemID: String,
        terminal: Terminal
    ) throws {
        if let index = entries.firstIndex(where: { $0.itemID == itemID }) {
            if let existing = entries[index].terminal {
                guard existing == terminal else {
                    throw Failure.conflictingTerminal(itemID)
                }
                return
            }
            entries[index].terminal = terminal
            return
        }

        guard pendingAcknowledgement != nil else {
            throw Failure.unknownItemID(itemID)
        }
        if let pendingTerminal {
            guard pendingTerminal == PendingTerminal(
                itemID: itemID,
                terminal: terminal)
            else {
                throw Failure.conflictingTerminal(itemID)
            }
            return
        }
        pendingTerminal = PendingTerminal(
            itemID: itemID,
            terminal: terminal)
    }
}
