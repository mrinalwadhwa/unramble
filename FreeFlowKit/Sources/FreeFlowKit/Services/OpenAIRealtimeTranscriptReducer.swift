/// Applies typed OpenAI Realtime transcription events to one session ledger.
/// Local commit recording and wire-event parsing remain separate so one
/// serialized session owner can coordinate both operations.
/// Any thrown application error invalidates the reducer's session.
struct OpenAIRealtimeTranscriptReducer: Sendable {

    enum Failure: Error, Equatable {
        case unsupportedContentIndex(itemID: String, actual: Int)
        case conflictingServerEventID(String)
    }

    enum Application: Equatable, Sendable {
        case acknowledged(RealtimeTranscriptLedger.Commit)
        case terminal(itemID: String)
        case replay
    }

    private var ledger = RealtimeTranscriptLedger()
    private var appliedEventsByID: [String: OpenAIRealtimeTranscriptionEvent] = [:]

    @discardableResult
    mutating func recordCommit(
        coverageRange: Range<Int>,
        submittedRange: Range<Int>
    ) throws -> RealtimeTranscriptLedger.Commit {
        try ledger.recordCommit(
            coverageRange: coverageRange,
            submittedRange: submittedRange)
    }

    @discardableResult
    mutating func apply(
        _ event: OpenAIRealtimeTranscriptionEvent
    ) throws -> Application {
        switch event {
        case .commitAcknowledged:
            break
        case .completed(_, let itemID, let contentIndex, _),
             .failed(_, let itemID, let contentIndex, _):
            guard contentIndex == 0 else {
                throw Failure.unsupportedContentIndex(
                    itemID: itemID,
                    actual: contentIndex)
            }
        }

        let serverEventID = event.serverEventID
        if let applied = appliedEventsByID[serverEventID] {
            guard applied == event else {
                throw Failure.conflictingServerEventID(serverEventID)
            }
            return .replay
        }

        let application: Application
        switch event {
        case .commitAcknowledged(_, let itemID, let predecessor):
            application = .acknowledged(
                try ledger.acknowledgeCommit(
                    itemID: itemID,
                    predecessor: predecessor))
        case .completed(_, let itemID, _, let transcript):
            try ledger.completeTranscription(
                itemID: itemID,
                transcript: transcript)
            application = .terminal(itemID: itemID)
        case .failed(_, let itemID, _, let error):
            try ledger.failTranscription(
                itemID: itemID,
                message: error.ledgerMessage)
            application = .terminal(itemID: itemID)
        }

        appliedEventsByID[serverEventID] = event
        return application
    }

    mutating func seal(expectedCoverageEnd: Int) throws {
        try ledger.seal(expectedCoverageEnd: expectedCoverageEnd)
    }

    func resolvedItems() throws -> [RealtimeTranscriptLedger.ResolvedItem] {
        try ledger.resolvedItems()
    }
}
