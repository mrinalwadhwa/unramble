import Foundation

/// A dictation pipeline that a retired generation fences and retires around
/// model teardown.
public protocol RetireablePipeline: Sendable {
    func beginRetirement() async
    func retire() async
}

/// A local model runtime that a retired generation shuts down during a drain.
public protocol ShutdownableRuntime: Sendable {
    func beginShutdown() async
    func shutdown() async
}

extension DictationPipeline: RetireablePipeline {}
extension LocalModelRuntime: ShutdownableRuntime {}

/// A retired dictation generation: the previous pipeline, its local model
/// runtime, and any in-flight model preload task. Draining tears them down in
/// the order that fences the pipeline before model cancellation can suspend, so
/// a replacement generation never loads while the old one is still writing.
public struct DetachedPipelineGeneration: Sendable {
    public let pipeline: (any RetireablePipeline)?
    public let runtime: (any ShutdownableRuntime)?
    public let preloadTask: Task<Void, Never>?

    public init(
        pipeline: (any RetireablePipeline)?,
        runtime: (any ShutdownableRuntime)?,
        preloadTask: Task<Void, Never>?
    ) {
        self.pipeline = pipeline
        self.runtime = runtime
        self.preloadTask = preloadTask
    }

    public func drain() async {
        // Fence the pipeline before Qwen cancellation can suspend. The
        // cancellation drain then progresses alongside model teardown.
        await pipeline?.beginRetirement()
        await runtime?.beginShutdown()
        await pipeline?.retire()
        await runtime?.shutdown()
        await preloadTask?.value
    }
}
