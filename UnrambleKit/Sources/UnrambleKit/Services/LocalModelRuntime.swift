import Foundation

/// Owns one local STT/LLM generation and its background preload.
///
/// Shutdown is terminal. It cancels and drains preload work before unloading
/// the engines, so a late STT load cannot republish state after teardown.
public actor LocalModelRuntime {

    public nonisolated let sttEngine: any LocalSTTEngine
    public nonisolated let llmEngine: any LocalLLMEngine

    private var sttLoadTask: Task<Void, Error>?
    private var llmLoadTask: Task<Void, Error>?
    private var preloadTask: Task<Void, Error>?
    private var shutdownStartTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    public init(
        sttEngine: any LocalSTTEngine,
        llmEngine: any LocalLLMEngine
    ) {
        self.sttEngine = sttEngine
        self.llmEngine = llmEngine
    }

    /// Start or join this generation's single retained preload task.
    ///
    /// A completed task remains retained so later callers observe the same
    /// success or failure instead of loading the engines again.
    public func preload() async throws {
        guard shutdownStartTask == nil else { throw CancellationError() }

        let task: Task<Void, Error>
        if let preloadTask {
            task = preloadTask
        } else {
            let sttTask = startSTTLoad()
            let llmTask = startLLMLoad()
            let created = Task.detached(priority: .utility) {
                try await sttTask.value
                try await llmTask.value
            }
            preloadTask = created
            task = created
        }

        try await task.value
        guard shutdownStartTask == nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Start or join the STT load owned by this runtime generation.
    ///
    /// Local first use calls this same operation as background preload, so
    /// Core ML model construction cannot run twice within one generation.
    public func loadSTT() async throws {
        guard shutdownStartTask == nil else { throw CancellationError() }
        let task = startSTTLoad()
        try await task.value
        guard shutdownStartTask == nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func startSTTLoad() -> Task<Void, Error> {
        if let sttLoadTask { return sttLoadTask }
        let sttEngine = self.sttEngine
        let task = Task.detached(priority: .utility) {
            try await sttEngine.load()
        }
        sttLoadTask = task
        return task
    }

    private func startLLMLoad() -> Task<Void, Error> {
        if let llmLoadTask { return llmLoadTask }
        let llmEngine = self.llmEngine
        let task = Task.detached(priority: .utility) {
            try await llmEngine.load()
        }
        llmLoadTask = task
        return task
    }

    /// Mark the runtime terminal and cancel Qwen loading without unloading STT.
    ///
    /// Composition calls this before draining pipeline consumers. Qwen's load
    /// is explicitly cancellable through `unload()`, while STT must remain
    /// alive until every pipeline first-use call has returned.
    public func beginShutdown() async {
        let task: Task<Void, Never>
        if let shutdownStartTask {
            task = shutdownStartTask
        } else {
            let preloadTask = self.preloadTask
            let sttLoadTask = self.sttLoadTask
            let llmLoadTask = self.llmLoadTask
            let llmEngine = self.llmEngine
            let created = Task.detached(priority: .utility) {
                preloadTask?.cancel()
                sttLoadTask?.cancel()
                llmLoadTask?.cancel()
                await llmEngine.unload()
            }
            shutdownStartTask = created
            task = created
        }

        await task.value
    }

    /// Cancel and drain preload work, then release both model generations.
    ///
    /// Qwen owns an internal single-flight task, so its first unload is needed
    /// to cancel that work. STT unload happens only after the retained parent
    /// task drains because Core ML loading is not cooperatively cancellable.
    public func shutdown() async {
        await beginShutdown()

        let task: Task<Void, Never>
        if let shutdownTask {
            task = shutdownTask
        } else {
            let preloadTask = self.preloadTask
            let sttLoadTask = self.sttLoadTask
            let llmLoadTask = self.llmLoadTask
            let sttEngine = self.sttEngine
            let llmEngine = self.llmEngine
            let created = Task.detached(priority: .utility) {
                if let sttLoadTask {
                    _ = await sttLoadTask.result
                }
                if let llmLoadTask {
                    _ = await llmLoadTask.result
                }
                if let preloadTask {
                    _ = await preloadTask.result
                }
                await sttEngine.unload()
                await llmEngine.unload()
            }
            shutdownTask = created
            task = created
        }

        await task.value
    }
}
