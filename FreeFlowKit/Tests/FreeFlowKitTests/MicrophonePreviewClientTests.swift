import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Microphone preview client")
@MainActor
struct MicrophonePreviewClientTests {
    @Test("Stopping before the queued start runs prevents acquisition")
    func stopBeforeQueuedStartPreventsAcquisition() async {
        let trace = PreviewClientTrace()
        let visibility = PreviewClientVisibility()
        let client = MicrophonePreviewClient(
            acquirePreview: {
                await trace.recordAcquisition()
                return makePreviewLease(trace: trace)
            })

        client.start(
            isEligible: { visibility.isVisible },
            onAudioLevel: { _ in },
            onAvailability: { _ in })
        visibility.isVisible = false
        client.stop()

        await Task.yield()
        #expect(await trace.acquisitionCount == 0)
        #expect(await trace.releaseCount == 0)
    }

    @Test("A lease returned after close is released instead of retained")
    func lateLeaseAfterCloseIsReleased() async {
        let acquisitionGate = PreviewClientGate()
        let leaseReleased = PreviewClientSignal()
        let trace = PreviewClientTrace(releaseSignal: leaseReleased)
        let visibility = PreviewClientVisibility()
        let availability = PreviewAvailabilityTrace()
        let client = MicrophonePreviewClient(
            acquirePreview: {
                await trace.recordAcquisition()
                await acquisitionGate.wait()
                return makePreviewLease(trace: trace)
            })

        client.start(
            isEligible: { visibility.isVisible },
            onAudioLevel: { _ in },
            onAvailability: { availability.append($0) })
        await acquisitionGate.waitUntilEntered()

        visibility.isVisible = false
        client.stop()
        await acquisitionGate.open()
        await leaseReleased.wait()

        #expect(await trace.acquisitionCount == 1)
        #expect(await trace.releaseCount == 1)
        #expect(availability.values.allSatisfy { !$0 })
    }
}

@MainActor
private final class PreviewClientVisibility {
    var isVisible = true
}

@MainActor
private final class PreviewAvailabilityTrace {
    private(set) var values: [Bool] = []

    func append(_ value: Bool) {
        values.append(value)
    }
}

private actor PreviewClientTrace {
    private(set) var acquisitionCount = 0
    private(set) var releaseCount = 0
    private let releaseSignal: PreviewClientSignal?

    init(releaseSignal: PreviewClientSignal? = nil) {
        self.releaseSignal = releaseSignal
    }

    func recordAcquisition() {
        acquisitionCount += 1
    }

    func recordRelease() async {
        releaseCount += 1
        await releaseSignal?.signal()
    }
}

private actor PreviewClientGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }
}

private actor PreviewClientSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func makePreviewLease(
    trace: PreviewClientTrace
) -> MicrophoneCaptureLease {
    let levelStream = AsyncStream<Float>.makeStream()
    levelStream.continuation.finish()
    let availabilityStream = AsyncStream<Bool>.makeStream()
    availabilityStream.continuation.finish()
    return MicrophoneCaptureLease(
        audioLevels: levelStream.stream,
        captureAvailability: availabilityStream.stream,
        releaseAction: {
            await trace.recordRelease()
            return true
        })
}
