import Foundation
import Testing

@testable import UnrambleKit

@Suite("Detached pipeline generation")
struct DetachedPipelineGenerationTests {

    @Test("Drain retires and shuts down in the fencing order")
    func drainOrder() async {
        let recorder = CallRecorder()
        let generation = DetachedPipelineGeneration(
            pipeline: FakeRetireablePipeline(recorder),
            runtime: FakeShutdownableRuntime(recorder),
            preloadTask: nil)

        await generation.drain()

        #expect(
            await recorder.calls
                == ["beginRetirement", "beginShutdown", "retire", "shutdown"])
    }

    @Test("Drain tolerates a generation with no pipeline, runtime, or task")
    func drainToleratesEmpty() async {
        let generation = DetachedPipelineGeneration(
            pipeline: nil, runtime: nil, preloadTask: nil)

        await generation.drain()
    }

    @Test("Drain awaits the preload task")
    func drainAwaitsPreloadTask() async {
        let recorder = CallRecorder()
        let task = Task<Void, Never> { await recorder.record("preload") }
        let generation = DetachedPipelineGeneration(
            pipeline: nil, runtime: nil, preloadTask: task)

        await generation.drain()

        #expect(await recorder.calls == ["preload"])
    }
}

private actor CallRecorder {
    private(set) var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
}

private final class FakeRetireablePipeline: RetireablePipeline, @unchecked Sendable {
    private let recorder: CallRecorder
    init(_ recorder: CallRecorder) { self.recorder = recorder }
    func beginRetirement() async { await recorder.record("beginRetirement") }
    func retire() async { await recorder.record("retire") }
}

private final class FakeShutdownableRuntime: ShutdownableRuntime, @unchecked Sendable {
    private let recorder: CallRecorder
    init(_ recorder: CallRecorder) { self.recorder = recorder }
    func beginShutdown() async { await recorder.record("beginShutdown") }
    func shutdown() async { await recorder.record("shutdown") }
}
