import Foundation

/// Owns one streaming finalization call through provider teardown.
final class StreamingFinishOperation: Sendable {
    enum Outcome: Equatable, Sendable {
        case completed(String)
        case failed(String)
        case cancelled
        case timedOut
    }

    private enum ResolutionRace: Sendable {
        case completed(Outcome)
        case timedOut
        case cancelled
    }

    private let completionStream: AsyncStream<Outcome>
    private let task: Task<Outcome, Never>

    init(finish: @escaping @Sendable () async throws -> String) {
        let (completionStream, continuation) = AsyncStream<Outcome>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.completionStream = completionStream
        self.task = Task {
            let outcome: Outcome
            do {
                let text = try await finish()
                outcome = Task.isCancelled ? .cancelled : .completed(text)
            } catch {
                if Task.isCancelled {
                    outcome = .cancelled
                } else if let error = error as? LocalizedError,
                    let description = error.errorDescription
                {
                    outcome = .failed(description)
                } else {
                    outcome = .failed(String(describing: error))
                }
            }

            continuation.yield(outcome)
            continuation.finish()
            return outcome
        }
    }

    /// Resolve finalization or close the provider before joining blocked work.
    func resolve(
        timeout: Duration,
        cancelStreaming: @escaping @Sendable () async -> Void
    ) async -> Outcome {
        let race = await withTaskGroup(of: ResolutionRace.self) { group in
            group.addTask { [completionStream] in
                for await outcome in completionStream {
                    guard !Task.isCancelled else { return .cancelled }
                    return .completed(outcome)
                }
                return .cancelled
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    try Task.checkCancellation()
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }

        let resolvedRace: ResolutionRace = Task.isCancelled ? .cancelled : race
        switch resolvedRace {
        case .completed(.completed(let text)):
            _ = await task.value
            return .completed(text)
        case .completed(let outcome):
            await cancelStreaming()
            _ = await task.value
            return outcome
        case .timedOut:
            task.cancel()
            await cancelStreaming()
            _ = await task.value
            return .timedOut
        case .cancelled:
            task.cancel()
            await cancelStreaming()
            _ = await task.value
            return .cancelled
        }
    }
}
