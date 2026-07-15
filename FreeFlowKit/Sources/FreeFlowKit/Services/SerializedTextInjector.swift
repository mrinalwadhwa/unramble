import Foundation

/// Serialize target-application mutations across automatic injection and
/// explicit paste recovery. Arbitrary AX/pasteboard writes are not composable,
/// so at most one publication may cross this boundary at a time.
public actor SerializedTextInjector: TextInjecting {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let base: any TextInjecting
    private var isPublishing = false
    private var waiters: [Waiter] = []

    var queuedPublicationCount: Int { waiters.count }

    public init(base: any TextInjecting) {
        self.base = base
    }

    public func inject(text: String, into context: AppContext) async throws {
        try await acquirePublication()
        defer { releasePublication() }
        try Task.checkCancellation()
        try await base.inject(text: text, into: context)
    }

    private func acquirePublication() async throws {
        try Task.checkCancellation()
        guard isPublishing else {
            isPublishing = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releasePublication() {
        guard !waiters.isEmpty else {
            isPublishing = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }
}
