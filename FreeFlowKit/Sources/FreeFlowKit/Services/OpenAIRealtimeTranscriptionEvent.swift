struct OpenAIRealtimeErrorDetails: Equatable, Sendable {
    let type: String?
    let code: String?
    let message: String?
    let parameter: String?

    var ledgerMessage: String {
        let base = message.flatMap { $0.isEmpty ? nil : $0 }
            ?? "input audio transcription failed"
        let metadata = [
            type.flatMap { $0.isEmpty ? nil : "type=\($0)" },
            code.flatMap { $0.isEmpty ? nil : "code=\($0)" },
            parameter.flatMap { $0.isEmpty ? nil : "param=\($0)" },
        ].compactMap { $0 }
        guard !metadata.isEmpty else { return base }
        return "\(base) [\(metadata.joined(separator: ", "))]"
    }
}

struct OpenAIRealtimeServerError: Equatable, Sendable {
    let serverEventID: String
    let type: String
    let code: String?
    let message: String
    let parameter: String?
    let clientEventID: String?

    var diagnosticMessage: String {
        var metadata = [
            "type=\(type)",
            "server_event_id=\(serverEventID)",
        ]
        if let code { metadata.append("code=\(code)") }
        if let parameter { metadata.append("param=\(parameter)") }
        if let clientEventID {
            metadata.append("client_event_id=\(clientEventID)")
        }
        return "\(message) [\(metadata.joined(separator: ", "))]"
    }
}

/// The committed event may omit `previous_item_id`, explicitly report no
/// predecessor, or identify one. Keeping those states distinct lets the ledger
/// validate information the server supplied without rejecting an omitted
/// optional field.
enum RealtimeItemPredecessor: Equatable, Sendable {
    case unspecified
    case root
    case item(String)

    var itemID: String? {
        guard case .item(let itemID) = self else { return nil }
        return itemID
    }
}

/// Correlation-focused projection of Realtime transcription server events.
/// The parser validates fields that identify and resolve committed audio, while
/// intentionally ignoring unrelated metadata such as usage and log probabilities.
enum OpenAIRealtimeTranscriptionEvent: Equatable, Sendable {
    case commitAcknowledged(
        serverEventID: String,
        itemID: String,
        predecessor: RealtimeItemPredecessor)
    case completed(
        serverEventID: String,
        itemID: String,
        contentIndex: Int,
        transcript: String)
    case failed(
        serverEventID: String,
        itemID: String,
        contentIndex: Int,
        error: OpenAIRealtimeErrorDetails)

    var serverEventID: String {
        switch self {
        case .commitAcknowledged(let serverEventID, _, _):
            return serverEventID
        case .completed(let serverEventID, _, _, _):
            return serverEventID
        case .failed(let serverEventID, _, _, _):
            return serverEventID
        }
    }
}
