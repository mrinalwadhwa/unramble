import Foundation

/// Shares one asynchronous operation among concurrent callers.
///
/// Cancellation is explicit: canceling an individual caller does not cancel
/// shared work, while `cancel()` cancels and drains the operation for everyone.
actor AsyncSingleFlight<Value: Sendable> {
    private struct Flight {
        let id: UUID
        let task: Task<Value, Error>
    }

    private struct Cancellation {
        let id: UUID
        let flightID: UUID
        let barrier: Task<Void, Never>
    }

    private var flight: Flight?
    private var cancellation: Cancellation?
    private(set) var activeCallerCount = 0

    var isCancelling: Bool { cancellation != nil }

    func run(
        _ operation: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        activeCallerCount += 1
        defer { activeCallerCount -= 1 }

        await waitForCancellation()
        try Task.checkCancellation()

        let current: Flight
        if let flight {
            current = flight
        } else {
            current = Flight(id: UUID(), task: Task(operation: operation))
            flight = current
        }

        do {
            let value = try await current.task.value
            try Task.checkCancellation()
            clearFlight(id: current.id)
            return value
        } catch {
            clearFlight(id: current.id)
            throw error
        }
    }

    func cancel() async {
        if let cancellation {
            await cancellation.barrier.value
            finishCancellation(cancellation)
            return
        }

        guard let flight else { return }

        flight.task.cancel()
        let barrier = Task {
            _ = await flight.task.result
        }
        let cancellation = Cancellation(
            id: UUID(), flightID: flight.id, barrier: barrier)
        self.cancellation = cancellation

        await barrier.value
        finishCancellation(cancellation)
    }

    private func waitForCancellation() async {
        while let cancellation {
            await cancellation.barrier.value
            finishCancellation(cancellation)
        }
    }

    private func finishCancellation(_ completed: Cancellation) {
        guard cancellation?.id == completed.id else { return }
        cancellation = nil
        clearFlight(id: completed.flightID)
    }

    private func clearFlight(id: UUID) {
        guard flight?.id == id else { return }
        flight = nil
    }
}
