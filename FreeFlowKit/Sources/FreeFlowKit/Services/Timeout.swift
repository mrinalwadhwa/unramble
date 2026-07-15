import Foundation

/// Execute an async operation with a timeout. Return nil if the deadline is exceeded.
///
/// Used by context assembly to enforce per-field and total latency budgets.
/// When the timeout fires first, the operation's task is cancelled and nil is returned.
///
/// - Parameters:
///   - seconds: Maximum time in seconds to wait for the operation.
///   - operation: The async work to perform.
/// - Returns: The operation's result, or nil if the timeout expired.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// A detached task whose owner can observe a deadline without making the
/// operation a structured child of the timeout race. The task handle remains
/// available after timeout so the resource owner can cancel, reset, and drain
/// it before admitting replacement work.
private final class DetachedOperationCompletion<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending([UUID: @Sendable (Value) -> Void])
        case completed(Value)
    }

    private let lock = NSLock()
    private var state: State = .pending([:])

    func observe(
        _ observer: @escaping @Sendable (Value) -> Void
    ) -> UUID {
        let id = UUID()
        let completedValue: Value? = lock.withLock {
            switch state {
            case .pending(var observers):
                observers[id] = observer
                state = .pending(observers)
                return nil
            case let .completed(value):
                return value
            }
        }
        if let completedValue {
            observer(completedValue)
        }
        return id
    }

    func resolve(_ value: Value) {
        let observers: [@Sendable (Value) -> Void] = lock.withLock {
            guard case let .pending(observers) = state else { return [] }
            state = .completed(value)
            return Array(observers.values)
        }
        for observer in observers {
            observer(value)
        }
    }

    func removeObserver(id: UUID) {
        lock.withLock {
            guard case .pending(var observers) = state else { return }
            observers[id] = nil
            state = .pending(observers)
        }
    }
}

enum DetachedOperationObservation<Value: Sendable>: Sendable {
    case completed(Value)
    case deadline
    case cancelled
}

private final class DetachedOperationRace<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(
            CheckedContinuation<DetachedOperationObservation<Value>, Never>)
        case resolved(DetachedOperationObservation<Value>)
    }

    private let lock = NSLock()
    private var state: State = .pending

    func wait() async -> DetachedOperationObservation<Value> {
        await withCheckedContinuation { continuation in
            let resolved: DetachedOperationObservation<Value>? = lock.withLock {
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return nil
                case .waiting:
                    preconditionFailure("Detached operation race has one waiter")
                case let .resolved(outcome):
                    return outcome
                }
            }
            if let resolved {
                continuation.resume(returning: resolved)
            }
        }
    }

    func resolve(_ outcome: DetachedOperationObservation<Value>) {
        let continuation: CheckedContinuation<
            DetachedOperationObservation<Value>, Never
        >? = lock.withLock {
            switch state {
            case .pending:
                state = .resolved(outcome)
                return nil
            case let .waiting(continuation):
                state = .resolved(outcome)
                return continuation
            case .resolved:
                return nil
            }
        }
        continuation?.resume(returning: outcome)
    }
}

struct DetachedOperation<Value: Sendable>: Sendable {
    let task: Task<Value, Never>
    private let completion: DetachedOperationCompletion<Value>

    init(operation: @escaping @Sendable () async -> Value) {
        let completion = DetachedOperationCompletion<Value>()
        self.completion = completion
        self.task = Task.detached {
            let value = await operation()
            completion.resolve(value)
            return value
        }
    }

    /// Observe why the wait ended without making the owned task a structured
    /// child of the timeout race. The owner must still drain `task` before
    /// reusing resources after a deadline or caller cancellation.
    func outcome(
        timeout seconds: TimeInterval
    ) async -> DetachedOperationObservation<Value> {
        let race = DetachedOperationRace<Value>()
        let observationID = completion.observe { value in
            race.resolve(.completed(value))
        }
        let deadlineTask = Task.detached {
            do {
                try await Task.sleep(for: .seconds(max(0, seconds)))
                try Task.checkCancellation()
                race.resolve(.deadline)
            } catch {
                // The winning operation or caller cancellation owns resolution.
            }
        }

        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            race.resolve(.cancelled)
        }
        deadlineTask.cancel()
        completion.removeObserver(id: observationID)

        return outcome
    }

    /// Compatibility wrapper that preserves the original nil-on-no-value API.
    func value(timeout seconds: TimeInterval) async -> Value? {
        let outcome = await outcome(timeout: seconds)
        guard case let .completed(value) = outcome else { return nil }
        return value
    }
}
