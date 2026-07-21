import Foundation
import Testing

@testable import UnrambleKit

@Suite("LocalStreamingProvider")
struct LocalStreamingProviderTests {

    // MARK: - Helpers

    private func makeProvider(
        sttEngine: ScriptedRecognizer = ScriptedRecognizer(),
        polishClient: StreamingMockPolishClient? = nil
    ) -> (LocalStreamingProvider, ScriptedRecognizer, StreamingMockPolishClient?) {
        let provider = LocalStreamingProvider(
            sttEngine: sttEngine,
            polishChatClient: polishClient)
        return (provider, sttEngine, polishClient)
    }

    /// Build a PCM chunk of the given byte count.
    private func makePCM(bytes: Int = 64) -> Data {
        Data(repeating: 0x42, count: bytes)
    }

    private func makePCM(samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func startSession(
        _ provider: LocalStreamingProvider,
        context: AppContext = .empty
    ) async throws -> DictationSessionID {
        let sessionID = DictationSessionID()
        try await provider.startStreaming(
            sessionID: sessionID,
            context: context,
            language: nil,
            micProximity: .farField)
        return sessionID
    }

    // MARK: - Audio accumulation

    @Test("Feeds all accumulated PCM to one incremental session")
    func accumulatesAudio() async throws {
        let engine = ScriptedRecognizer()
        engine.stubbedTranscription = "accumulated"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        let sessionID = try await startSession(provider)
        try await provider.sendAudio(
            makePCM(samples: [-32_768, 0]), sessionID: sessionID)
        try await provider.sendAudio(
            makePCM(samples: [16_384, 32_767]), sessionID: sessionID)
        _ = try await provider.finishStreaming(sessionID: sessionID)

        #expect(engine.finishCallCount == 1)
        #expect(engine.fedSampleCounts == [4])
        let samples = try #require(engine.fedSamples.first)
        #expect(samples[0] == -1)
        #expect(samples[1] == 0)
        #expect(samples[2] == 0.5)
        #expect(abs(samples[3] - (32_767.0 / 32_768.0)) < 0.000_001)
    }

    @Test("Feeds replay slices exactly once and in order")
    func replayFeedsSlicesInOrder() async throws {
        let engine = ScriptedRecognizer(transcription: "ordered")
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            cycleInterval: 4 / Double(LocalUnitPolicy.sourceBytesPerSecond))
        let audio = makePCM(samples: [-32_768, -16_384, 0, 16_384, 32_767])

        _ = try await provider.replayForTesting(audio)

        #expect(engine.fedSampleCounts == [2, 2, 1])
        #expect(engine.fedSamples.flatMap { $0 } == [
            -1, -0.5, 0, 0.5, Float(32_767.0 / 32_768.0),
        ])
    }

    @Test("Creates a fresh recognition session for each dictation")
    func createsFreshRecognitionSession() async throws {
        let engine = ScriptedRecognizer(transcripts: ["First.", "Second."])
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: nil)

        let firstSessionID = try await startSession(provider)
        try await provider.sendAudio(makePCM(), sessionID: firstSessionID)
        let first = try await provider.finishStreaming(sessionID: firstSessionID)

        let secondSessionID = try await startSession(provider)
        try await provider.sendAudio(makePCM(), sessionID: secondSessionID)
        let second = try await provider.finishStreaming(sessionID: secondSessionID)

        #expect(engine.sessionCreationCount == 2)
        #expect(first == "First.")
        #expect(second == "First.")
    }

    @Test("Successful finish clears prior session content")
    func finishClearsSessionContent() async throws {
        let engine = ScriptedRecognizer(transcription: "private words")
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: nil)

        let firstSessionID = try await startSession(provider)
        try await provider.sendAudio(makePCM(), sessionID: firstSessionID)
        let first = try await provider.finishStreaming(sessionID: firstSessionID)
        #expect(first.lowercased().contains("private words"))

        let secondSessionID = try await startSession(provider)
        #expect(
            try await provider.finishStreaming(sessionID: secondSessionID)
                == "")
    }

    // MARK: - Cancel clears buffer

    @Test("Cancel clears accumulated audio")
    func cancelClearsBuffer() async throws {
        let engine = ScriptedRecognizer()
        engine.stubbedTranscription = "should not appear"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        let cancelledSessionID = try await startSession(provider)
        try await provider.sendAudio(
            makePCM(bytes: 100), sessionID: cancelledSessionID)
        await provider.cancelStreaming(sessionID: cancelledSessionID)

        // Start a new session — buffer should be empty from the cancel.
        let replacementSessionID = try await startSession(provider)
        let result = try await provider.finishStreaming(
            sessionID: replacementSessionID)

        // No audio to transcribe — should return empty.
        #expect(result == "")
        #expect(engine.finishCallCount == 0)
    }

    @Test("Stale session calls cannot mutate a replacement")
    func staleSessionCannotMutateReplacement() async throws {
        let engine = ScriptedRecognizer(transcription: "replacement")
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: nil)
        let firstSession = DictationSessionID()
        let replacementSession = DictationSessionID()

        try await provider.startStreaming(
            sessionID: firstSession,
            context: .empty,
            language: nil,
            micProximity: .farField)
        await provider.cancelStreaming(sessionID: firstSession)

        try await provider.startStreaming(
            sessionID: replacementSession,
            context: .empty,
            language: nil,
            micProximity: .farField)
        await provider.cancelStreaming(sessionID: firstSession)
        await #expect(throws: CancellationError.self) {
            try await provider.sendAudio(
                self.makePCM(),
                sessionID: firstSession)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await provider.finishStreaming(
                sessionID: firstSession)
        }
        #expect(engine.finishCallCount == 0)

        try await provider.sendAudio(
            makePCM(),
            sessionID: replacementSession)
        let result = try await provider.finishStreaming(
            sessionID: replacementSession)

        #expect(result == "Replacement.")
        #expect(engine.finishCallCount == 1)
    }

    // MARK: - Empty buffer returns empty

    @Test("Returns empty string when no audio was sent")
    func emptyBufferReturnsEmpty() async throws {
        let engine = ScriptedRecognizer()
        let (provider, _, _) = makeProvider(sttEngine: engine)

        let sessionID = try await startSession(provider)
        let result = try await provider.finishStreaming(sessionID: sessionID)

        #expect(result == "")
        #expect(engine.finishCallCount == 0)
    }

    // MARK: - Engine load on first use

    @Test("Loads engine on first streaming session")
    func loadsEngineOnFirstUse() async throws {
        let engine = ScriptedRecognizer()
        engine.stubbedIsReady = false
        engine.stubbedTranscription = "loaded"
        let (provider, _, _) = makeProvider(sttEngine: engine)

        _ = try await startSession(provider)

        #expect(engine.loadCallCount == 1)
    }

    @Test("Cancellation during model load cannot publish a session")
    func cancellationDuringLoadDoesNotPublishSession() async throws {
        let engine = ScriptedRecognizer(isReady: false)
        let load = ControlledLoad()
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            loadSTT: { await load.run() })

        let cancelledSessionID = DictationSessionID()
        let startTask = Task {
            try await provider.startStreaming(
                sessionID: cancelledSessionID,
                context: .empty,
                language: nil,
                micProximity: .farField)
        }
        await load.waitUntilStarted()

        let cancelFinished = LockedFlag()
        let cancel = Task {
            await provider.cancelStreaming(sessionID: cancelledSessionID)
            cancelFinished.set()
        }
        for _ in 0..<100 where !cancelFinished.value {
            await Task.yield()
        }
        #expect(!cancelFinished.value)

        await load.release()
        await cancel.value

        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        await #expect(throws: CancellationError.self) {
            try await provider.sendAudio(
                makePCM(), sessionID: cancelledSessionID)
        }
        #expect(engine.sessionCreationCount == 0)

        engine.stubbedIsReady = true
        let replacementSessionID = try await startSession(provider)
        #expect(engine.sessionCreationCount == 1)
        await provider.cancelStreaming(sessionID: replacementSessionID)
    }

    @Test("Concurrent scoped start is rejected while model load is pending")
    func concurrentScopedStartDuringLoadIsRejected() async throws {
        let engine = ScriptedRecognizer(isReady: false)
        let load = ControlledLoad()
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            loadSTT: { await load.run() })
        let firstSession = DictationSessionID()
        let secondSession = DictationSessionID()

        let firstStart = Task {
            try await provider.startStreaming(
                sessionID: firstSession,
                context: .empty,
                language: nil,
                micProximity: .farField)
        }
        await load.waitUntilStarted()

        await #expect(throws: CancellationError.self) {
            try await provider.startStreaming(
                sessionID: secondSession,
                context: .empty,
                language: nil,
                micProximity: .farField)
        }
        #expect(await load.callCount() == 1)

        await load.release()
        try await firstStart.value
        await provider.cancelStreaming(sessionID: firstSession)
    }

    @Test("Cancel drains a pending load without creating a stale session")
    func cancelDuringLoadDrainsWithoutCreatingSession() async throws {
        let engine = ScriptedRecognizer(isReady: false)
        let load = ControlledLoad()
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            loadSTT: { await load.run() })
        let sessionID = DictationSessionID()

        let start = Task {
            try await provider.startStreaming(
                sessionID: sessionID,
                context: .empty,
                language: nil,
                micProximity: .farField)
        }
        await load.waitUntilStarted()

        let cancelFinished = LockedFlag()
        let cancel = Task {
            await provider.cancelStreaming(sessionID: sessionID)
            cancelFinished.set()
        }
        for _ in 0..<100 where !cancelFinished.value {
            await Task.yield()
        }
        #expect(!cancelFinished.value)

        await load.release()
        await cancel.value
        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(engine.sessionCreationCount == 0)
    }

    @Test("Surfaces an incremental feed failure without retrying the session")
    func backgroundFeedFailureIsTerminal() async throws {
        let engine = ScriptedRecognizer(
            feedError: LocalModelError.transcriptionFailed("feed failed"))
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            cycleInterval: 1)

        await #expect(throws: LocalModelError.self) {
            _ = try await provider.replayForTesting(makePCM(bytes: 32_000))
        }
        #expect(engine.feedCallCount == 1)
        #expect(engine.finishCallCount == 0)
    }

    @Test("Surfaces recognition session creation failure")
    func sessionCreationFailureIsSurfaced() async {
        let engine = ScriptedRecognizer(
            makeSessionError: LocalModelError.modelNotLoaded)
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: nil)
        let sessionID = DictationSessionID()

        await #expect(throws: LocalModelError.self) {
            try await provider.startStreaming(
                sessionID: sessionID,
                context: .empty,
                language: nil,
                micProximity: .farField)
        }
        #expect(engine.sessionCreationCount == 1)
    }

    @Test("Surfaces final recognition flush failure")
    func finalFlushFailureIsSurfaced() async throws {
        let engine = ScriptedRecognizer(
            finishError: LocalModelError.transcriptionFailed("flush failed"))
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: nil)

        let sessionID = try await startSession(provider)
        try await provider.sendAudio(makePCM(), sessionID: sessionID)
        await #expect(throws: LocalModelError.self) {
            _ = try await provider.finishStreaming(sessionID: sessionID)
        }
        #expect(engine.finishCallCount == 1)

        let replacementSessionID = try await startSession(provider)
        #expect(
            try await provider.finishStreaming(sessionID: replacementSessionID)
                == "")
    }

    @Test("Cancellation during polish does not publish or inject text")
    func cancellationDuringPolishDoesNotPublish() async throws {
        let engine = ScriptedRecognizer(transcripts: ["Alpha. Beta."])
        let polishClient = CancellationControlledPolishClient()
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: polishClient,
            cycleInterval: 0.001,
            // A small cap closes a unit on the sent audio so the background
            // cycle starts polishing, which this test then cancels mid-flight.
            unitPolicy: LocalUnitPolicy(
                minimumSpeechBytes: 2, softPauseSilenceBytes: 2,
                hardPauseSilenceBytes: 4, maximumUnitBytes: 1000))
        let sessionID = try await startSession(provider)
        try await provider.sendAudio(
            makePCM(bytes: 32_000), sessionID: sessionID)
        await polishClient.waitUntilStarted()
        await provider.cancelStreaming(sessionID: sessionID)

        await #expect(throws: CancellationError.self) {
            _ = try await provider.finishStreaming(sessionID: sessionID)
        }
    }

    @Test("Cancellation drains final polish and rejects another finish")
    func cancellationDuringFinalPolishDoesNotPublish() async throws {
        let engine = ScriptedRecognizer(transcription: "Alpha.")
        let polishClient = CancellationControlledPolishClient(
            releaseOnCancel: false)
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: polishClient)

        let sessionID = try await startSession(provider)
        try await provider.sendAudio(makePCM(), sessionID: sessionID)
        let finishTask = Task {
            try await provider.finishStreaming(sessionID: sessionID)
        }
        await polishClient.waitUntilStarted()

        let cancelReturned = LockedFlag()
        let cancelTask = Task {
            await provider.cancelStreaming(sessionID: sessionID)
            cancelReturned.set()
        }
        await polishClient.waitUntilCancelled()

        // The finalization is still held, so cancellation must still be
        // draining and a second finish must not adopt the stale session.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!cancelReturned.value)
        await #expect(throws: CancellationError.self) {
            _ = try await provider.finishStreaming(sessionID: sessionID)
        }

        await polishClient.release()
        await cancelTask.value

        await #expect(throws: CancellationError.self) {
            _ = try await finishTask.value
        }
        #expect(cancelReturned.value)
        await #expect(throws: CancellationError.self) {
            _ = try await provider.finishStreaming(sessionID: sessionID)
        }
    }

    @Test("Cancelling the finish caller cancels finalization")
    func callerCancellationCancelsFinalization() async throws {
        let engine = ScriptedRecognizer(transcription: "Alpha.")
        let polishClient = CancellationControlledPolishClient()
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: polishClient)

        let sessionID = try await startSession(provider)
        try await provider.sendAudio(makePCM(), sessionID: sessionID)
        let finishTask = Task {
            try await provider.finishStreaming(sessionID: sessionID)
        }
        await polishClient.waitUntilStarted()

        finishTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await finishTask.value
        }
        await provider.cancelStreaming(sessionID: sessionID)
    }

    // MARK: - Polish integration

    @Test("Polishes transcription through pipeline")
    func polishesResult() async throws {
        let engine = ScriptedRecognizer()
        engine.stubbedTranscription = "hello world"
        let polishClient = StreamingMockPolishClient()
        polishClient.stubbedResult = "Hello, world."
        let (provider, _, _) = makeProvider(
            sttEngine: engine, polishClient: polishClient)

        let sessionID = try await startSession(provider)
        try await provider.sendAudio(
            makePCM(bytes: 64), sessionID: sessionID)
        let result = try await provider.finishStreaming(sessionID: sessionID)

        #expect(result == "Hello, world.")
        #expect(polishClient.completeCallCount == 1)
    }

    // MARK: - One final transcript

    @Test("Returns the whole transcript as one final result")
    func returnsFullTranscript() async throws {
        let engine = ScriptedRecognizer(transcripts: [
            "Hi there.",
            "Hi there. This is a test.",
            "Hi there. This is a test. Almost done.",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            cycleInterval: 1)

        let result = try await provider.replayForTesting(
            makePCM(bytes: 96_000))

        // The whole transcript comes back at once, nothing dropped.
        #expect(result.contains("Hi there"))
        #expect(result.contains("This is a test"))
        #expect(result.contains("Almost done"))
    }

    // MARK: - Paragraph breaks

    @Test("The final result carries a paragraph break")
    func paragraphBreakInChunk() async throws {
        let engine = ScriptedRecognizer(transcripts: [
            "Alpha bravo.",
            "Alpha bravo. new paragraph charlie delta.",
            "Alpha bravo. new paragraph charlie delta. Echo foxtrot.",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: nil, cycleInterval: 1)

        let result = try await provider.replayForTesting(
            makePCM(bytes: 96_000))

        #expect(result.contains("\n\n"),
            "the result should carry the paragraph break: \(result)")
        #expect(!result.contains(" \n\n"),
            "no stray space before the break: \(result)")
    }

    // MARK: - Polish failure fallback

    @Test("Falls back to deterministic polish when client throws")
    func fallsBackOnPolishError() async throws {
        let engine = ScriptedRecognizer()
        engine.stubbedTranscription = "hello world"
        let polishClient = StreamingMockPolishClient()
        polishClient.stubbedError = LocalModelError.completionFailed("fail")
        let (provider, _, _) = makeProvider(
            sttEngine: engine, polishClient: polishClient)

        let sessionID = try await startSession(provider)
        try await provider.sendAudio(
            makePCM(bytes: 64), sessionID: sessionID)
        let result = try await provider.finishStreaming(sessionID: sessionID)

        #expect(result == "Hello world.")
    }
}

// MARK: - StreamingMockPolishClient

/// Minimal mock for PolishChatClient used by streaming provider tests.
private final class StreamingMockPolishClient: PolishChatClient, @unchecked Sendable {

    private let lock = NSLock()
    private var _completeCallCount = 0

    var stubbedResult = ""
    var stubbedError: (any Error)?

    var completeCallCount: Int {
        lock.withLock { _completeCallCount }
    }

    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        lock.withLock { _completeCallCount += 1 }
        if let error = stubbedError { throw error }
        return stubbedResult
    }
}

/// A polish client that echoes back its input unchanged.
/// Simulates a model that doesn't improve the text.
private final class EchoPolishClient: PolishChatClient, @unchecked Sendable {
    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        return userPrompt
    }
}

/// Holds a polish call until its task is cancelled. This puts the provider at
/// the publication boundary without relying on a wall-clock test delay.
private actor CancellationControlledPolishClient: PolishChatClient {
    private let releaseOnCancel: Bool
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(releaseOnCancel: Bool = true) {
        self.releaseOnCancel = releaseOnCancel
    }

    func complete(
        model: String, systemPrompt: String, userPrompt: String
    ) async throws -> String {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.handleCancellation() }
        }
        return "Alpha."
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func handleCancellation() {
        cancelled = true
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if releaseOnCancel { release() }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private actor ControlledLoad {
    private var started = false
    private var runs = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async {
        runs += 1
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func callCount() -> Int {
        runs
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Incremental recognizer with transcripts scripted by successful feed count.
private final class ScriptedRecognizer: LocalStreamingRecognizer,
    @unchecked Sendable
{
    let name = "ScriptedSTT"

    private let lock = NSLock()
    private var ready: Bool
    private var transcription: String
    private let transcripts: [String]
    private let feedError: (any Error)?
    private let makeSessionError: (any Error)?
    private let finishError: (any Error)?
    private var _feedCallCount = 0
    private var _finishCallCount = 0
    private var _loadCallCount = 0
    private var _sessionCreationCount = 0
    private var _fedSampleCounts: [Int] = []
    private var _fedSamples: [[Float]] = []

    init(
        transcription: String = "hello world",
        transcripts: [String] = [],
        isReady: Bool = true,
        feedError: (any Error)? = nil,
        makeSessionError: (any Error)? = nil,
        finishError: (any Error)? = nil
    ) {
        self.transcription = transcription
        self.transcripts = transcripts
        self.ready = isReady
        self.feedError = feedError
        self.makeSessionError = makeSessionError
        self.finishError = finishError
    }

    var isReady: Bool { lock.withLock { ready } }

    var stubbedIsReady: Bool {
        get { lock.withLock { ready } }
        set { lock.withLock { ready = newValue } }
    }

    var stubbedTranscription: String {
        get { lock.withLock { transcription } }
        set { lock.withLock { transcription = newValue } }
    }

    var feedCallCount: Int { lock.withLock { _feedCallCount } }
    var finishCallCount: Int { lock.withLock { _finishCallCount } }
    var loadCallCount: Int { lock.withLock { _loadCallCount } }
    var sessionCreationCount: Int { lock.withLock { _sessionCreationCount } }
    var fedSampleCounts: [Int] { lock.withLock { _fedSampleCounts } }
    var fedSamples: [[Float]] { lock.withLock { _fedSamples } }

    func load() async throws {
        lock.withLock {
            _loadCallCount += 1
            ready = true
        }
    }

    func makeRecognitionSession() throws -> any LocalRecognitionSession {
        let error = lock.withLock { () -> (any Error)? in
            _sessionCreationCount += 1
            return makeSessionError
        }
        if let error { throw error }
        return ScriptedRecognitionSession(recognizer: self)
    }

    fileprivate func recordFeed(_ samples: [Float]) throws {
        let error = lock.withLock { () -> (any Error)? in
            _feedCallCount += 1
            _fedSampleCounts.append(samples.count)
            _fedSamples.append(samples)
            return feedError
        }
        if let error { throw error }
    }

    fileprivate func currentTranscript(successfulFeeds: Int) -> String {
        lock.withLock { transcriptLocked(successfulFeeds: successfulFeeds) }
    }

    fileprivate func finish(successfulFeeds: Int) throws -> String {
        let result = lock.withLock { () -> (String, (any Error)?) in
            _finishCallCount += 1
            return (
                transcriptLocked(successfulFeeds: successfulFeeds),
                finishError)
        }
        if let error = result.1 { throw error }
        return result.0
    }

    private func transcriptLocked(successfulFeeds: Int) -> String {
        guard successfulFeeds > 0 else { return "" }
        guard !transcripts.isEmpty else { return transcription }
        let index = max(0, min(successfulFeeds - 1, transcripts.count - 1))
        return transcripts[index]
    }
}

private final class ScriptedRecognitionSession: LocalRecognitionSession {
    private let recognizer: ScriptedRecognizer
    private var successfulFeeds = 0

    init(recognizer: ScriptedRecognizer) {
        self.recognizer = recognizer
    }

    func feed(_ samples: [Float]) throws {
        try recognizer.recordFeed(samples)
        successfulFeeds += 1
    }

    func transcript() -> String {
        recognizer.currentTranscript(successfulFeeds: successfulFeeds)
    }

    func finish() throws -> String {
        try recognizer.finish(successfulFeeds: successfulFeeds)
    }
}

// MARK: - Preprocessing with sentence splitting

@Suite("LocalStreamingProvider – preprocessing")
struct LocalStreamingPreprocessingTests {

    private func makeProvider(
        sttResult: String
    ) -> (LocalStreamingProvider, ScriptedRecognizer) {
        let engine = ScriptedRecognizer()
        engine.stubbedTranscription = sttResult
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: nil)
        return (provider, engine)
    }

    private func makePCM(bytes: Int = 64) -> Data {
        Data(repeating: 0x42, count: bytes)
    }

    private func startSession(
        _ provider: LocalStreamingProvider
    ) async throws -> DictationSessionID {
        let sessionID = DictationSessionID()
        try await provider.startStreaming(
            sessionID: sessionID,
            context: .empty,
            language: nil,
            micProximity: .farField)
        return sessionID
    }

    private func runPipeline(_ sttResult: String) async throws -> String {
        let (provider, _) = makeProvider(sttResult: sttResult)
        let sessionID = try await startSession(provider)
        try await provider.sendAudio(
            makePCM(bytes: 64), sessionID: sessionID)
        return try await provider.finishStreaming(sessionID: sessionID)
    }

    private func runPipelineWithEchoModel(_ sttResult: String) async throws -> String {
        let engine = ScriptedRecognizer()
        engine.stubbedTranscription = sttResult
        let echoClient = EchoPolishClient()
        let provider = LocalStreamingProvider(
            sttEngine: engine, polishChatClient: echoClient)
        let sessionID = try await startSession(provider)
        try await provider.sendAudio(
            makePCM(bytes: 64), sessionID: sessionID)
        return try await provider.finishStreaming(sessionID: sessionID)
    }

    @Test("Filler um is stripped in finishStreaming output")
    func fillerUmStripped() async throws {
        let result = try await runPipeline(
            "Think about the key areas. Um for CTO roles and AI roles.")
        #expect(
            !result.contains("Um ") && !result.contains(" um "),
            "Filler 'um' should be stripped but got: \(result)")
    }

    @Test("Filler uh is stripped in finishStreaming output")
    func fillerUhStripped() async throws {
        let result = try await runPipeline(
            "I like the beginning of uh A but I want the product statement.")
        #expect(
            !result.contains(" uh "),
            "Filler 'uh' should be stripped but got: \(result)")
    }

    @Test("Trailing Mm-hmm is stripped in finishStreaming output")
    func trailingMmHmmStripped() async throws {
        let result = try await runPipeline(
            "We should add rate limiting to the API. Mm-hmm.")
        #expect(
            !result.contains("Mm-hmm"),
            "Trailing 'Mm-hmm' should be stripped but got: \(result)")
    }

    @Test("a.m./p.m. is preserved in finishStreaming output")
    func ampmPreserved() async throws {
        let result = try await runPipeline(
            "The meeting is at 3 p.m. in the large conference room.")
        #expect(
            result.contains("PM") || result.contains("p.m."),
            "a.m./p.m. should be preserved but got: \(result)")
        #expect(
            !result.contains("p.m in"),
            "a.m./p.m. period should not be stripped: \(result)")
    }

    @Test("Filler across background cache boundary is stripped")
    func fillerAcrossCacheBoundary() async throws {
        // Background cycle 1 sees: "Think about the key areas."
        // Background cycle 2 sees: "Think about the key areas. Um for CTO roles."
        // The "Um" starts a new sentence after the cache boundary.
        let engine = ScriptedRecognizer(transcripts: [
            "Think about the key areas.",
            "Think about the key areas. Um for CTO roles and AI roles.",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            cycleInterval: 1)
        let result = try await provider.replayForTesting(
            makePCM(bytes: 64_000))
        #expect(
            !result.contains("Um ") && !result.contains(" um "),
            "Filler should be stripped across cache boundary but got: \(result)")
    }

    @Test("Mid-sentence filler is stripped from incremental recognition")
    func midSentenceFillerFromIncrementalRecognition() async throws {
        let engine = ScriptedRecognizer(transcripts: [
            "I did all of those things, um but I think the details are too much.",
        ])
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: nil,
            cycleInterval: 1)
        let result = try await provider.replayForTesting(
            makePCM(bytes: 32_000))
        #expect(
            !result.contains(" um "),
            "Mid-sentence filler should be stripped but got: \(result)")
    }

    @Test("Filler stripped when echo model is used")
    func fillerStrippedWithEchoModel() async throws {
        // Echo model returns its input unchanged — fillers should
        // still be stripped by preprocessing before the model sees them.
        let engine = ScriptedRecognizer()
        engine.stubbedTranscription = "I did all of those things, um but I think the details are too much."
        let echoClient = EchoPolishClient()
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: echoClient)
        let sessionID = try await startSession(provider)
        try await provider.sendAudio(
            makePCM(bytes: 64), sessionID: sessionID)
        let result = try await provider.finishStreaming(sessionID: sessionID)
        print("[TEST] Filler with echo model: \"\(result)\"")
        #expect(
            !result.contains(" um "),
            "Filler should be stripped before model sees it but got: \(result)")
    }

    @Test("Multiple fillers stripped with echo model")
    func multipleFillerWithEchoModel() async throws {
        let engine = ScriptedRecognizer()
        engine.stubbedTranscription = "Read the first page of um product docs. Um I think that gives us better vocabulary. Um The term is harness."
        let echoClient = EchoPolishClient()
        let provider = LocalStreamingProvider(
            sttEngine: engine,
            polishChatClient: echoClient)
        let sessionID = try await startSession(provider)
        try await provider.sendAudio(
            makePCM(bytes: 64), sessionID: sessionID)
        let result = try await provider.finishStreaming(sessionID: sessionID)
        print("[TEST] Multiple fillers with echo: \"\(result)\"")
        #expect(
            !result.lowercased().contains(" um ") && !result.contains("Um "),
            "All fillers should be stripped but got: \(result)")
    }

}
