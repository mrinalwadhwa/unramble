import Foundation

/// Publishes the current PCM stream without depending on the audio engine's
/// state lock. Reads are short and cannot queue behind engine startup or tap
/// teardown.
final class AudioCapturePCMStreamSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: AsyncStream<Data>?

    var current: AsyncStream<Data>? {
        lock.withLock { stream }
    }

    func publish(_ stream: AsyncStream<Data>) {
        lock.withLock { self.stream = stream }
    }

    func clear() {
        lock.withLock { stream = nil }
    }
}
