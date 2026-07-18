import CoreFoundation
import Foundation

/// Typed codec for the OpenAI Realtime WebSocket wire protocol. Decode inbound
/// server events into `ParsedEvent` values and build outbound client messages.
/// These are pure functions with no session or transport state, so they
/// unit-test in isolation against JSON strings.
enum OpenAIRealtimeWireCodec {

    // MARK: - Outbound message builders

    /// Build the Realtime API WebSocket URL for the given model.
    static func buildWebSocketURL(model: String) -> URL {
        var components = URLComponents(
            string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url!
    }

    /// Build the `response.create` message to trigger a text response.
    static func buildResponseCreate(eventID: String? = nil) -> String {
        var event: [String: Any] = [
            "type": "response.create",
            "response": [
                "output_modalities": ["text"],
            ],
        ]
        if let eventID { event["event_id"] = eventID }
        return jsonString(event)
    }

    /// Build a `conversation.item.create` message to add a user text
    /// message containing the raw transcript for polishing.
    static func buildPolishRequest(
        transcript: String,
        eventID: String? = nil
    ) -> String {
        var event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": transcript,
                    ],
                ],
            ],
        ]
        if let eventID { event["event_id"] = eventID }
        return jsonString(event)
    }

    /// Build an `input_audio_buffer.append` message wrapping base64 PCM.
    static func buildAudioAppend(
        pcm24k: Data,
        eventID: String? = nil
    ) -> String {
        var event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm24k.base64EncodedString(),
        ]
        if let eventID { event["event_id"] = eventID }
        return jsonString(event)
    }

    /// Build the `input_audio_buffer.commit` message.
    static func buildCommit(eventID: String? = nil) -> String {
        var event: [String: Any] = ["type": "input_audio_buffer.commit"]
        if let eventID { event["event_id"] = eventID }
        return jsonString(event)
    }

    // MARK: - Inbound event parsing

    enum ParsedEvent: Equatable {
        case transcription(OpenAIRealtimeTranscriptionEvent)
        case transcriptionDelta(String)
        case responseTextDelta(
            outputIndex: Int,
            contentIndex: Int,
            delta: String)
        case responseTextDone(
            outputIndex: Int,
            contentIndex: Int,
            text: String)
        case responseDone
        case error(String)
        case serverError(OpenAIRealtimeServerError)
        case protocolError(String)
        case other
    }

    static func parseEvent(_ text: String) -> ParsedEvent {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let obj = object as? [String: Any]
        else {
            return .protocolError("Realtime event is not a JSON object")
        }
        guard let type = obj["type"] as? String, !type.isEmpty else {
            return .protocolError("Realtime event requires nonempty string type")
        }

        switch type {
        case "input_audio_buffer.committed":
            do {
                let serverEventID = try requiredNonemptyString(
                    in: obj,
                    field: "event_id",
                    eventType: type)
                let itemID = try requiredNonemptyString(
                    in: obj,
                    field: "item_id",
                    eventType: type)
                let predecessor = try itemPredecessor(
                    in: obj,
                    field: "previous_item_id",
                    eventType: type)
                return .transcription(
                    .commitAcknowledged(
                        serverEventID: serverEventID,
                        itemID: itemID,
                        predecessor: predecessor))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "conversation.item.input_audio_transcription.completed":
            do {
                return .transcription(
                    .completed(
                        serverEventID: try requiredNonemptyString(
                            in: obj,
                            field: "event_id",
                            eventType: type),
                        itemID: try requiredNonemptyString(
                            in: obj,
                            field: "item_id",
                            eventType: type),
                        contentIndex: try requiredNonnegativeInteger(
                            in: obj,
                            field: "content_index",
                            eventType: type),
                        transcript: try requiredString(
                            in: obj,
                            field: "transcript",
                            eventType: type)))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "conversation.item.input_audio_transcription.delta":
            let delta = obj["delta"] as? String ?? ""
            return .transcriptionDelta(delta)
        case "conversation.item.input_audio_transcription.failed":
            do {
                let error = try requiredObject(
                    in: obj,
                    field: "error",
                    eventType: type)
                let details = OpenAIRealtimeErrorDetails(
                    type: try optionalString(
                        in: error,
                        field: "type",
                        eventType: type),
                    code: try optionalString(
                        in: error,
                        field: "code",
                        eventType: type),
                    message: try optionalString(
                        in: error,
                        field: "message",
                        eventType: type),
                    parameter: try optionalString(
                        in: error,
                        field: "param",
                        eventType: type))
                return .transcription(
                    .failed(
                        serverEventID: try requiredNonemptyString(
                            in: obj,
                            field: "event_id",
                            eventType: type),
                        itemID: try requiredNonemptyString(
                            in: obj,
                            field: "item_id",
                            eventType: type),
                        contentIndex: try requiredNonnegativeInteger(
                            in: obj,
                            field: "content_index",
                            eventType: type),
                        error: details))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "response.text.delta", "response.output_text.delta":
            do {
                return .responseTextDelta(
                    outputIndex: try responseTextIndex(
                        in: obj,
                        field: "output_index",
                        eventType: type),
                    contentIndex: try responseTextIndex(
                        in: obj,
                        field: "content_index",
                        eventType: type),
                    delta: try requiredString(
                        in: obj,
                        field: "delta",
                        eventType: type))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "response.text.done", "response.output_text.done":
            do {
                return .responseTextDone(
                    outputIndex: try responseTextIndex(
                        in: obj,
                        field: "output_index",
                        eventType: type),
                    contentIndex: try responseTextIndex(
                        in: obj,
                        field: "content_index",
                        eventType: type),
                    text: try requiredString(
                        in: obj,
                        field: "text",
                        eventType: type))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        case "response.done":
            Log.debug("[RealtimeResponse] response.done received")
            guard let response = obj["response"] as? [String: Any] else {
                return .error("response.done missing response")
            }
            guard let status = response["status"] as? String else {
                return .error("response.done missing status")
            }
            if status != "completed" {
                let message = errorMessage(in: response)
                    ?? "response ended with status \(status)"
                return .error(message)
            }
            return .responseDone
        case "error":
            do {
                let error = try requiredObject(
                    in: obj,
                    field: "error",
                    eventType: type)
                return .serverError(
                    OpenAIRealtimeServerError(
                        serverEventID: try requiredNonemptyString(
                            in: obj,
                            field: "event_id",
                            eventType: type),
                        type: try requiredNonemptyString(
                            in: error,
                            field: "type",
                            eventType: type),
                        code: try optionalString(
                            in: error,
                            field: "code",
                            eventType: type),
                        message: try requiredNonemptyString(
                            in: error,
                            field: "message",
                            eventType: type),
                        parameter: try optionalString(
                            in: error,
                            field: "param",
                            eventType: type),
                        clientEventID: try optionalString(
                            in: error,
                            field: "event_id",
                            eventType: type)))
            } catch let failure as EventFieldFailure {
                return .protocolError(failure.message)
            } catch {
                return .protocolError("Malformed \(type) event")
            }
        default:
            Log.debug("[RealtimeResponse] ignored unknown event")
            return .other
        }
    }

    private struct EventFieldFailure: Error {
        let message: String
    }

    private static func requiredNonemptyString(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> String {
        guard let value = object[field] as? String, !value.isEmpty else {
            throw EventFieldFailure(
                message: "\(eventType) requires nonempty string \(field)")
        }
        return value
    }

    private static func requiredString(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> String {
        guard let value = object[field] as? String else {
            throw EventFieldFailure(
                message: "\(eventType) requires string \(field)")
        }
        return value
    }

    private static func optionalString(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> String? {
        guard let raw = object[field] else { return nil }
        if raw is NSNull { return nil }
        guard let value = raw as? String else {
            throw EventFieldFailure(
                message: "\(eventType) requires \(field) to be null or a string")
        }
        return value
    }

    private static func requiredObject(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> [String: Any] {
        guard let value = object[field] as? [String: Any] else {
            throw EventFieldFailure(
                message: "\(eventType) requires object \(field)")
        }
        return value
    }

    private static func requiredNonnegativeInteger(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> Int {
        guard let number = object[field] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            throw EventFieldFailure(
                message: "\(eventType) requires nonnegative integer \(field)")
        }
        let int64Value = number.int64Value
        guard int64Value >= 0,
            number.compare(NSNumber(value: int64Value)) == .orderedSame,
            let value = Int(exactly: int64Value)
        else {
            throw EventFieldFailure(
                message: "\(eventType) requires nonnegative integer \(field)")
        }
        return value
    }

    private static func responseTextIndex(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> Int {
        guard object[field] != nil else { return 0 }
        return try requiredNonnegativeInteger(
            in: object,
            field: field,
            eventType: eventType)
    }

    private static func itemPredecessor(
        in object: [String: Any],
        field: String,
        eventType: String
    ) throws -> RealtimeItemPredecessor {
        guard let raw = object[field] else { return .unspecified }
        if raw is NSNull { return .root }
        guard let value = raw as? String, !value.isEmpty else {
            throw EventFieldFailure(
                message: "\(eventType) requires \(field) to be null or a nonempty string")
        }
        return .item(value)
    }

    private static func errorMessage(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }
        if let details = object["status_details"] as? [String: Any] {
            return errorMessage(in: details)
        }
        return nil
    }

    // MARK: - JSON encoding

    static func jsonString(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
