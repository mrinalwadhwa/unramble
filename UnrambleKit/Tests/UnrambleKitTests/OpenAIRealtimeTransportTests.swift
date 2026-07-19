import Foundation
import Testing

@testable import UnrambleKit

/// Unit tests for the URLSession-backed Realtime transport. A fake socket seam
/// stands in for `URLSessionWebSocketTask`/`URLSession`, so the close-code
/// mapping, frame decoding, and receive-failure wrapping are covered without a
/// live connection.
@Suite("OpenAI Realtime transport")
struct OpenAIRealtimeTransportTests {

    @Test("resume resumes the socket task")
    func resumeForwardsToTask() {
        let task = FakeRealtimeSocketTask()
        let transport = URLSessionRealtimeTransport(
            task: task, session: FakeRealtimeSocketSession())

        transport.resume()

        #expect(task.resumeCount == 1)
    }

    @Test("send forwards text as a string frame")
    func sendForwardsStringFrame() async throws {
        let task = FakeRealtimeSocketTask()
        let transport = URLSessionRealtimeTransport(
            task: task, session: FakeRealtimeSocketSession())

        try await transport.send("hello")

        #expect(task.sentMessages.count == 1)
        guard case .string(let text) = task.sentMessages.first else {
            Issue.record("expected a string frame")
            return
        }
        #expect(text == "hello")
    }

    @Test("receiveText returns a string frame verbatim")
    func receiveReturnsStringFrame() async throws {
        let task = FakeRealtimeSocketTask()
        task.receiveResult = .success(.string("frame"))
        let transport = URLSessionRealtimeTransport(
            task: task, session: FakeRealtimeSocketSession())

        #expect(try await transport.receiveText() == "frame")
    }

    @Test("receiveText decodes a UTF-8 data frame")
    func receiveDecodesUTF8DataFrame() async throws {
        let task = FakeRealtimeSocketTask()
        task.receiveResult = .success(.data(Data("bytes".utf8)))
        let transport = URLSessionRealtimeTransport(
            task: task, session: FakeRealtimeSocketSession())

        #expect(try await transport.receiveText() == "bytes")
    }

    @Test("receiveText yields an empty string for a non-UTF-8 data frame")
    func receiveYieldsEmptyForNonUTF8() async throws {
        let task = FakeRealtimeSocketTask()
        task.receiveResult = .success(.data(Data([0xFF, 0xFE])))
        let transport = URLSessionRealtimeTransport(
            task: task, session: FakeRealtimeSocketSession())

        #expect(try await transport.receiveText() == "")
    }

    @Test("receiveText wraps a receive failure as a network error")
    func receiveWrapsFailure() async {
        let task = FakeRealtimeSocketTask()
        task.receiveResult = .failure(FakeSocketFailure.dropped)
        let transport = URLSessionRealtimeTransport(
            task: task, session: FakeRealtimeSocketSession())

        await #expect(throws: DictationError.self) {
            _ = try await transport.receiveText()
        }
    }

    @Test("close maps each reason to its close code and tears down the session")
    func closeMapsReasonAndTearsDown() {
        let cases: [(OpenAIRealtimeTransportCloseReason, URLSessionWebSocketTask.CloseCode)] = [
            (.normal, .normalClosure),
            (.goingAway, .goingAway),
            (.abnormal, .abnormalClosure),
        ]

        for (reason, expected) in cases {
            let task = FakeRealtimeSocketTask()
            let session = FakeRealtimeSocketSession()
            let transport = URLSessionRealtimeTransport(task: task, session: session)

            transport.close(reason)

            #expect(task.closeCalls.count == 1)
            #expect(task.closeCalls.first?.code == expected)
            #expect(task.closeCalls.first?.reason == nil)
            #expect(session.invalidateCount == 1)
        }
    }
}

private enum FakeSocketFailure: Error {
    case dropped
}

private final class FakeRealtimeSocketTask: RealtimeSocketTask, @unchecked Sendable {
    struct CloseCall {
        let code: URLSessionWebSocketTask.CloseCode
        let reason: Data?
    }

    private let lock = NSLock()
    private var _resumeCount = 0
    private var _sentMessages: [URLSessionWebSocketTask.Message] = []
    private var _closeCalls: [CloseCall] = []
    private var _receiveResult: Result<URLSessionWebSocketTask.Message, Error> = .success(
        .string(""))

    var resumeCount: Int { lock.withLock { _resumeCount } }
    var sentMessages: [URLSessionWebSocketTask.Message] { lock.withLock { _sentMessages } }
    var closeCalls: [CloseCall] { lock.withLock { _closeCalls } }
    var receiveResult: Result<URLSessionWebSocketTask.Message, Error> {
        get { lock.withLock { _receiveResult } }
        set { lock.withLock { _receiveResult = newValue } }
    }

    func resume() {
        lock.withLock { _resumeCount += 1 }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { _sentMessages.append(message) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try lock.withLock { try _receiveResult.get() }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { _closeCalls.append(CloseCall(code: closeCode, reason: reason)) }
    }
}

private final class FakeRealtimeSocketSession: RealtimeSocketSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _invalidateCount = 0

    var invalidateCount: Int { lock.withLock { _invalidateCount } }

    func invalidateAndCancel() {
        lock.withLock { _invalidateCount += 1 }
    }
}
