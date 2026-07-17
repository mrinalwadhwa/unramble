import Foundation
import Testing

@testable import UnrambleKit

@Suite("Mock streaming provider contract")
struct MockStreamingProviderContractTests {
    @Test("A concurrent start cannot replace the active session")
    func concurrentStartIsRejected() async throws {
        let provider = MockStreamingProvider(stubbedText: "first")
        let first = DictationSessionID()
        let second = DictationSessionID()

        try await provider.startStreaming(
            sessionID: first,
            context: .empty,
            language: nil,
            micProximity: .farField)
        await #expect(throws: CancellationError.self) {
            try await provider.startStreaming(
                sessionID: second,
                context: .empty,
                language: nil,
                micProximity: .farField)
        }

        #expect(try await provider.finishStreaming(sessionID: first) == "first")
        try await provider.startStreaming(
            sessionID: second,
            context: .empty,
            language: nil,
            micProximity: .farField)
        await provider.cancelStreaming(sessionID: second)
    }

    @Test("A failed finish releases its session")
    func failedFinishReleasesSession() async throws {
        let provider = MockStreamingProvider()
        provider.stubbedFinishError = DictationError.networkError("offline")
        let failed = DictationSessionID()

        try await provider.startStreaming(
            sessionID: failed,
            context: .empty,
            language: nil,
            micProximity: .farField)
        await #expect(throws: DictationError.self) {
            _ = try await provider.finishStreaming(sessionID: failed)
        }

        provider.stubbedFinishError = nil
        let replacement = DictationSessionID()
        try await provider.startStreaming(
            sessionID: replacement,
            context: .empty,
            language: nil,
            micProximity: .farField)
        await provider.cancelStreaming(sessionID: replacement)
    }

    @Test("Replay cannot replace an active streaming session")
    func replayCannotReplaceActiveSession() async throws {
        let provider = MockStreamingProvider(stubbedText: "streaming")
        let streaming = DictationSessionID()

        try await provider.startStreaming(
            sessionID: streaming,
            context: .empty,
            language: nil,
            micProximity: .farField)
        await #expect(throws: CancellationError.self) {
            _ = try await provider.replayCapturedAudio(
                Data([0, 0]),
                sessionID: DictationSessionID(),
                context: .empty,
                language: nil,
                micProximity: .farField,
                silenceThreshold: 0)
        }

        #expect(
            try await provider.finishStreaming(sessionID: streaming)
                == "streaming")
    }

    @Test("A failed replay releases its session")
    func failedReplayReleasesSession() async throws {
        let provider = MockStreamingProvider()
        provider.stubbedReplayError = DictationError.networkError("offline")

        await #expect(throws: DictationError.self) {
            _ = try await provider.replayCapturedAudio(
                Data([0, 0]),
                sessionID: DictationSessionID(),
                context: .empty,
                language: nil,
                micProximity: .farField,
                silenceThreshold: 0)
        }

        provider.stubbedReplayError = nil
        let replacement = DictationSessionID()
        try await provider.startStreaming(
            sessionID: replacement,
            context: .empty,
            language: nil,
            micProximity: .farField)
        await provider.cancelStreaming(sessionID: replacement)
    }
}
