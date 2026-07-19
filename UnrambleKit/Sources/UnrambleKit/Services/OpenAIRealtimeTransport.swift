import Foundation

/// Why the Realtime WebSocket is closing, mapped to a WebSocket close code by
/// the transport.
enum OpenAIRealtimeTransportCloseReason: Equatable, Sendable {
    case normal
    case goingAway
    case abnormal
}

/// The Realtime WebSocket boundary the provider drives a dictation through:
/// resume the connection, send text, receive text, and close. Keeping the
/// socket behind this narrow surface lets the provider inject a stub and the
/// concrete implementation change independently.
protocol OpenAIRealtimeTransport: Sendable {
    func resume()
    func send(_ text: String) async throws
    func receiveText() async throws -> String
    func close(_ reason: OpenAIRealtimeTransportCloseReason)
}

/// Narrow seam over `URLSessionWebSocketTask` so the transport's close-code
/// mapping and frame decoding unit-test without a live socket.
/// `URLSessionWebSocketTask` satisfies it as-is.
protocol RealtimeSocketTask {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

/// Narrow seam over `URLSession` for the transport's teardown call.
protocol RealtimeSocketSession {
    func invalidateAndCancel()
}

extension URLSessionWebSocketTask: RealtimeSocketTask {}
extension URLSession: RealtimeSocketSession {}

/// `URLSession`-backed Realtime transport. Maps the typed close reason to a
/// WebSocket close code and decodes received frames to text.
final class URLSessionRealtimeTransport:
    OpenAIRealtimeTransport, @unchecked Sendable
{
    private let task: any RealtimeSocketTask
    private let session: any RealtimeSocketSession

    init(task: any RealtimeSocketTask, session: any RealtimeSocketSession) {
        self.task = task
        self.session = session
    }

    func resume() {
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw DictationError.networkError(
                "WebSocket receive failed: \(error.localizedDescription)")
        }

        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return ""
        }
    }

    func close(_ reason: OpenAIRealtimeTransportCloseReason) {
        let code: URLSessionWebSocketTask.CloseCode = switch reason {
        case .normal: .normalClosure
        case .goingAway: .goingAway
        case .abnormal: .abnormalClosure
        }
        task.cancel(with: code, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Build the `URLSession`-backed Realtime transport for a dictation session.
enum OpenAIRealtimeTransportFactory {
    static func buildTransport(
        apiKey: String, model: String
    ) throws -> any OpenAIRealtimeTransport {
        try NetworkGuard.assertLiveNetworkAllowed("OpenAI Realtime WebSocket")
        let url = OpenAIRealtimeWireCodec.buildWebSocketURL(model: model)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // The URLSessionConfiguration's timeoutIntervalForRequest applies to the
        // interval between data packets on the WebSocket, not the total
        // connection lifetime. Set it to 300 s so that a long idle window during
        // transcription of a long audio buffer does not drop the connection
        // mid-session. Previously this was the default (60 s), which caused
        // `NSPOSIXErrorDomain Code=57 "Socket is not connected"` failures on
        // dictations longer than about a minute.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        let session = URLSession(configuration: config)
        return URLSessionRealtimeTransport(
            task: session.webSocketTask(with: request),
            session: session)
    }
}
