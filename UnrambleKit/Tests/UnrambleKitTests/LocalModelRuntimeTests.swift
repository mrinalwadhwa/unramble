import Foundation
import Testing

@testable import UnrambleKit
import UnrambleKitTestSupport

@Suite("Local model runtime")
struct LocalModelRuntimeTests {

    @Test("Concurrent and later callers share one retained preload")
    func retainedSharedPreload() async throws {
        let trace = EventTrace()
        let sttGate = AsyncGate()
        let llmGate = AsyncGate()
        let stt = ControlledModelEngine(
            name: "stt", loadGate: sttGate, trace: trace)
        let llm = ControlledModelEngine(
            name: "llm", loadGate: llmGate, trace: trace)
        let runtime = LocalModelRuntime(sttEngine: stt, llmEngine: llm)

        let first = Task { try await runtime.preload() }
        let second = Task { try await runtime.preload() }

        await sttGate.waitUntilArrived()
        await llmGate.waitUntilArrived()
        #expect(stt.loadCallCount == 1)
        #expect(llm.loadCallCount == 1)

        await sttGate.release()
        await llmGate.release()
        try await first.value
        try await second.value

        try await runtime.preload()
        #expect(stt.loadCallCount == 1)
        #expect(llm.loadCallCount == 1)

        await runtime.shutdown()
    }

    @Test("Preload and first use share one STT load")
    func preloadSharesFirstUseSTTLoad() async throws {
        let trace = EventTrace()
        let sttGate = AsyncGate()
        let llmGate = AsyncGate()
        let stt = ControlledModelEngine(
            name: "stt", loadGate: sttGate, trace: trace)
        let llm = ControlledModelEngine(
            name: "llm", loadGate: llmGate, trace: trace)
        let runtime = LocalModelRuntime(sttEngine: stt, llmEngine: llm)

        let firstUse = Task { try await runtime.loadSTT() }
        await sttGate.waitUntilArrived()

        let preload = Task { try await runtime.preload() }
        await llmGate.waitUntilArrived()
        #expect(stt.loadCallCount == 1)

        await sttGate.release()
        await llmGate.release()
        try await firstUse.value
        try await preload.value

        #expect(stt.loadCallCount == 1)
        await runtime.shutdown()
    }

    @Test("Shutdown is terminal and idempotent")
    func terminalShutdown() async throws {
        let trace = EventTrace()
        let stt = ControlledModelEngine(name: "stt", trace: trace)
        let llm = ControlledModelEngine(name: "llm", trace: trace)
        let runtime = LocalModelRuntime(sttEngine: stt, llmEngine: llm)

        try await runtime.preload()
        await runtime.shutdown()

        let sttUnloadCount = stt.unloadCallCount
        let llmUnloadCount = llm.unloadCallCount
        #expect(sttUnloadCount > 0)
        #expect(llmUnloadCount > 0)
        #expect(!stt.isReady)
        #expect(!llm.isReady)

        await runtime.shutdown()
        #expect(stt.unloadCallCount == sttUnloadCount)
        #expect(llm.unloadCallCount == llmUnloadCount)

        await #expect(throws: CancellationError.self) {
            try await runtime.preload()
        }
        #expect(stt.loadCallCount == 1)
        #expect(llm.loadCallCount == 1)
    }

    @Test("Shutdown drains a noncooperative STT load before unloading it")
    func drainsNoncooperativeLoad() async throws {
        let trace = EventTrace()
        let sttGate = AsyncGate()
        let stt = ControlledModelEngine(
            name: "stt", loadGate: sttGate, trace: trace)
        let llm = ControlledModelEngine(name: "llm", trace: trace)
        let runtime = LocalModelRuntime(sttEngine: stt, llmEngine: llm)

        let preload = Task { try await runtime.preload() }
        await sttGate.waitUntilArrived()

        let shutdown = Task {
            await runtime.shutdown()
            trace.record("shutdown.finished")
        }

        await trace.wait(for: "llm.unload.1")
        #expect(stt.unloadCallCount == 0)
        #expect(!trace.contains("shutdown.finished"))

        await sttGate.release()
        await #expect(throws: CancellationError.self) {
            try await preload.value
        }
        await shutdown.value

        let events = trace.snapshot()
        let loadFinished = try #require(
            events.firstIndex(of: "stt.load.1.finished"))
        let unload = try #require(events.firstIndex(of: "stt.unload.1"))
        #expect(loadFinished < unload)
        #expect(!stt.isReady)
    }

    @Test("Replacement waits until old model cleanup drains")
    @MainActor
    func replacementWaitsForOldDrain() async throws {
        let trace = EventTrace()
        let sttGate = AsyncGate()
        let stt = ControlledModelEngine(
            name: "old.stt", loadGate: sttGate, trace: trace)
        let llm = ControlledModelEngine(name: "old.llm", trace: trace)
        let runtime = LocalModelRuntime(sttEngine: stt, llmEngine: llm)
        let queue = AsyncLatestOperationQueue()

        let preload = Task { try await runtime.preload() }
        await sttGate.waitUntilArrived()

        let replacement = queue.submit(
            cleanup: {
                trace.record("cleanup.started")
                await runtime.shutdown()
                trace.record("cleanup.finished")
            },
            replacement: {
                trace.record("replacement.started")
            })

        await trace.wait(for: "old.llm.unload.1")
        #expect(!trace.contains("replacement.started"))
        #expect(stt.unloadCallCount == 0)

        await sttGate.release()
        await #expect(throws: CancellationError.self) {
            try await preload.value
        }
        await replacement.value

        let events = trace.snapshot()
        let loadFinished = try #require(
            events.firstIndex(of: "old.stt.load.1.finished"))
        let unload = try #require(
            events.firstIndex(of: "old.stt.unload.1"))
        let cleanupFinished = try #require(
            events.firstIndex(of: "cleanup.finished"))
        let replacementStarted = try #require(
            events.firstIndex(of: "replacement.started"))
        #expect(loadFinished < unload)
        #expect(unload < cleanupFinished)
        #expect(cleanupFinished < replacementStarted)
    }

    @Test("A newer request skips the stale replacement")
    @MainActor
    func skipsStaleReplacement() async {
        let trace = EventTrace()
        let firstCleanupGate = AsyncGate()
        let queue = AsyncLatestOperationQueue()

        let first = queue.submit(
            cleanup: {
                trace.record("first.cleanup.started")
                await firstCleanupGate.arriveAndWait()
                trace.record("first.cleanup.finished")
            },
            replacement: {
                trace.record("first.replacement")
            })

        await firstCleanupGate.waitUntilArrived()

        let second = queue.submit(
            cleanup: {
                trace.record("second.cleanup.started")
                trace.record("second.cleanup.finished")
            },
            replacement: {
                trace.record("second.replacement")
            })

        #expect(!trace.contains("second.cleanup.started"))
        await firstCleanupGate.release()
        await first.value
        await second.value

        #expect(trace.snapshot() == [
            "first.cleanup.started",
            "first.cleanup.finished",
            "second.cleanup.started",
            "second.cleanup.finished",
            "second.replacement",
        ])
    }

    @Test("Retirement start joins an in-flight cancellation drain")
    func beginRetirementJoinsInFlightCancel() async {
        let trace = EventTrace()
        let cancellationGate = AsyncGate()
        let streaming = GatedCancellationStreamingProvider(
            cancellationGate: cancellationGate,
            trace: trace
        )
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: .local(streaming: streaming),
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator()
        )
        guard let sessionID = await pipeline.activate() else {
            Issue.record("Pipeline activation was rejected")
            return
        }
        await trace.wait(for: "streaming.start")

        let cancellation = Task {
            await pipeline.cancel(sessionID: sessionID)
            trace.record("pipeline.cancel.finished")
        }
        await cancellationGate.waitUntilArrived()
        #expect(streaming.cancelCallCount == 1)

        await pipeline.beginRetirement()

        #expect(streaming.cancelCallCount == 1)
        #expect(!trace.contains("pipeline.cancel.finished"))

        await cancellationGate.release()
        await cancellation.value

        #expect(streaming.cancelCallCount == 1)
        #expect(trace.contains("pipeline.cancel.finished"))
        #expect(trace.snapshot().filter { $0.hasPrefix("streaming.cancel") } == [
            "streaming.cancel.1.started",
            "streaming.cancel.1.finished",
        ])
    }
}

private final class ControlledModelEngine: LocalSTTEngine, LocalLLMEngine,
    @unchecked Sendable
{
    let name: String

    private let lock = NSLock()
    private let loadGate: AsyncGate?
    private let trace: EventTrace
    private var ready = false
    private var loads = 0
    private var unloads = 0

    init(name: String, loadGate: AsyncGate? = nil, trace: EventTrace) {
        self.name = name
        self.loadGate = loadGate
        self.trace = trace
    }

    var isReady: Bool { lock.withLock { ready } }
    var loadCallCount: Int { lock.withLock { loads } }
    var unloadCallCount: Int { lock.withLock { unloads } }

    func load() async throws {
        let invocation = lock.withLock {
            loads += 1
            return loads
        }
        trace.record("\(name).load.\(invocation).started")

        // The first invocation deliberately ignores cancellation while gated.
        // This models synchronous Core ML construction already in progress.
        if invocation == 1, let loadGate {
            await loadGate.arriveAndWait()
        }

        lock.withLock { ready = true }
        trace.record("\(name).load.\(invocation).finished")
    }

    func unload() async {
        let invocation = lock.withLock {
            unloads += 1
            ready = false
            return unloads
        }
        trace.record("\(name).unload.\(invocation)")
    }

    func transcribe(audio: Data) async throws -> String { "" }

    func complete(
        systemPrompt: String, userPrompt: String, maxTokens: Int
    ) async throws -> String {
        ""
    }
}

private final class GatedCancellationStreamingProvider:
    LocalAudioReplayProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private let cancellationGate: AsyncGate
    private let trace: EventTrace
    private var cancellations = 0
    private var activeSessionID: DictationSessionID?

    init(cancellationGate: AsyncGate, trace: EventTrace) {
        self.cancellationGate = cancellationGate
        self.trace = trace
    }

    var cancelCallCount: Int { lock.withLock { cancellations } }

    func startStreaming(
        sessionID: DictationSessionID,
        context _: AppContext,
        language _: String?,
        micProximity _: MicProximity
    ) async throws {
        let claimed = lock.withLock {
            guard activeSessionID == nil else { return false }
            activeSessionID = sessionID
            return true
        }
        guard claimed else { throw CancellationError() }
        trace.record("streaming.start")
    }

    func sendAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID
    ) async throws {
        let accepted = lock.withLock { activeSessionID == sessionID }
        guard accepted else { throw CancellationError() }
    }

    func finishStreaming(
        sessionID: DictationSessionID
    ) async throws -> String {
        let finished = lock.withLock {
            guard activeSessionID == sessionID else { return false }
            activeSessionID = nil
            return true
        }
        guard finished else { throw CancellationError() }
        return ""
    }

    func cancelActiveStreaming() async {
        guard let sessionID = lock.withLock({ activeSessionID }) else { return }
        await cancelStreaming(sessionID: sessionID)
    }

    func cancelStreaming(sessionID: DictationSessionID) async {
        let owned = lock.withLock {
            guard activeSessionID == sessionID else { return false }
            activeSessionID = nil
            return true
        }
        guard owned else { return }
        await performCancellation()
    }

    private func performCancellation() async {
        let invocation = lock.withLock {
            cancellations += 1
            return cancellations
        }
        trace.record("streaming.cancel.\(invocation).started")
        if invocation == 1 {
            await cancellationGate.arriveAndWait()
        }
        trace.record("streaming.cancel.\(invocation).finished")
    }

    func replayCapturedAudio(
        _ pcmData: Data,
        sessionID: DictationSessionID,
        context: AppContext,
        language: String?,
        micProximity: MicProximity,
        silenceThreshold: Float
    ) async throws -> String {
        ""
    }
}

private actor AsyncGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        if !arrived {
            arrived = true
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class EventTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ event: String) {
        let eventWaiters = lock.withLock {
            events.append(event)
            return waiters.removeValue(forKey: event) ?? []
        }
        for waiter in eventWaiters { waiter.resume() }
    }

    func wait(for event: String) async {
        await withCheckedContinuation { continuation in
            let alreadyRecorded = lock.withLock {
                guard !events.contains(event) else { return true }
                waiters[event, default: []].append(continuation)
                return false
            }
            if alreadyRecorded { continuation.resume() }
        }
    }

    func contains(_ event: String) -> Bool {
        lock.withLock { events.contains(event) }
    }

    func snapshot() -> [String] { lock.withLock { events } }
}
