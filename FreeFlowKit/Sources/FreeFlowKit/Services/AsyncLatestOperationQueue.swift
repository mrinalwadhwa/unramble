/// Serializes cleanup/replacement transactions and publishes only the latest.
///
/// Cleanup always runs in submission order. If a newer request arrives while
/// cleanup is suspended, the stale request skips its replacement operation.
@MainActor
public final class AsyncLatestOperationQueue {

    private var generation: UInt = 0
    private var tail: Task<Void, Never>?

    public init() {}

    @discardableResult
    public func submit(
        cleanup: @Sendable @escaping () async -> Void,
        replacement: @MainActor @Sendable @escaping () -> Void
    ) -> Task<Void, Never> {
        generation &+= 1
        let requestGeneration = generation
        let predecessor = tail
        let task = Task { @MainActor in
            await predecessor?.value
            await cleanup()
            guard !Task.isCancelled,
                generation == requestGeneration
            else { return }

            // The latest check and synchronous publication share one
            // MainActor turn, so a newer request cannot interleave here.
            replacement()
        }
        tail = task
        return task
    }

    /// Prevent the pending request from publishing a replacement.
    public func invalidate() {
        generation &+= 1
        tail?.cancel()
    }
}
