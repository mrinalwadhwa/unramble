import Foundation

/// Owns one PCM stream consumer from capture through provider teardown.
final class AudioForwardingOperation: Sendable {
    enum Outcome: Equatable, Sendable {
        case drained
        case failed(String)
        case cancelled
        case timedOut
    }

    private enum DrainRace: Sendable {
        case completed(Outcome)
        case timedOut
        case cancelled
    }

    private let completionStream: AsyncStream<Outcome>
    private let task: Task<Outcome, Never>

    init(
        stream: AsyncStream<Data>,
        send: @escaping @Sendable (Data) async throws -> Void
    ) {
        let (completionStream, continuation) = AsyncStream<Outcome>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.completionStream = completionStream
        self.task = Task {
            var firstFailure: String?

            for await chunk in stream {
                guard !Task.isCancelled else { break }
                guard firstFailure == nil else { continue }

                do {
                    try await send(chunk)
                } catch {
                    guard !Task.isCancelled else { break }
                    if let error = error as? LocalizedError,
                        let description = error.errorDescription
                    {
                        firstFailure = description
                    } else {
                        firstFailure = String(describing: error)
                    }
                }
            }

            let outcome: Outcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if let firstFailure {
                outcome = .failed(firstFailure)
            } else {
                outcome = .drained
            }

            continuation.yield(outcome)
            continuation.finish()
            return outcome
        }
    }

    /// Wait for capture EOF without cancelling queued audio.
    ///
    /// A timeout or caller cancellation closes the provider before joining a
    /// send that may ignore Swift task cancellation.
    func drain(
        timeout: Duration,
        cancelStreaming: @escaping @Sendable () async -> Void
    ) async -> Outcome {
        let race = await withTaskGroup(of: DrainRace.self) { group in
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

        let resolvedRace: DrainRace = Task.isCancelled ? .cancelled : race
        switch resolvedRace {
        case .completed(.drained):
            _ = await task.value
            return .drained
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

    /// Cancel capture forwarding, close the provider, and join the sender.
    func cancel(
        cancelStreaming: @escaping @Sendable () async -> Void
    ) async {
        task.cancel()
        await cancelStreaming()
        _ = await task.value
    }
}
