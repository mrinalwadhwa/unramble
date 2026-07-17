import AVFoundation
import Foundation
import Testing

@testable import UnrambleKit

@Suite("Timestamped audio frame router")
struct TimestampedAudioFrameRouterTests {
    @Test("Promotion deep-copies and slices a buffer at the press boundary")
    func promotionCopiesPressSuffix() throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let start = hostTime(seconds: 100)
        let source = try pcmBuffer(values: Array(0..<10))

        router.ingest(
            source,
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: hostTime(seconds: 100.010))
        overwrite(source, with: 99)
        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: hostTime(seconds: 100.004))

        let route = try router.promote(releaseBoundary: boundary)

        #expect(route.pressHostTime == hostTime(seconds: 100.004))
        #expect(probe.sampleGroups == [[4, 5, 6, 7, 8, 9]])
    }

    @Test("A pre-published release slices the same replay buffer to [press, release)")
    func replaySlicesBothBoundaries() throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: hostTime(seconds: 100.003))
        let start = hostTime(seconds: 100)

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: hostTime(seconds: 100.010))
        #expect(boundary.publish(releaseHostTime: hostTime(seconds: 100.007)))

        _ = try router.promote(releaseBoundary: boundary)

        #expect(probe.sampleGroups == [[3, 4, 5, 6]])
    }

    @Test("A live buffer that straddles release contributes only its prefix")
    func liveBufferSlicesReleasePrefix() throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: hostTime(seconds: 100))
        _ = try router.promote(releaseBoundary: boundary)
        #expect(boundary.publish(releaseHostTime: hostTime(seconds: 100.006)))

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(hostTime: hostTime(seconds: 100)),
            observedHostTime: hostTime(seconds: 100.010))

        #expect(probe.sampleGroups == [[0, 1, 2, 3, 4, 5]])
    }

    @Test("Replay is delivered before later live frames")
    func preservesReplayLiveOrder() throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let start = hostTime(seconds: 100)

        router.ingest(
            try pcmBuffer(values: [0, 1]),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: hostTime(seconds: 100.002))
        _ = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: start))
        router.ingest(
            try pcmBuffer(values: [2, 3]),
            timestamp: AVAudioTime(hostTime: hostTime(seconds: 100.002)),
            observedHostTime: hostTime(seconds: 100.004))

        #expect(probe.sampleGroups == [[0, 1], [2, 3]])
        #expect(probe.sequenceNumbers == [0, 1])
    }

    @Test(
        "Each pre-roll capacity independently trims the oldest samples",
        arguments: [
            RetentionCase(
                limits: .init(
                    maxDuration: 0.004,
                    maxFrameCount: 100,
                    maxByteCount: 1_000),
                expectedValues: [6, 7, 8, 9]),
            RetentionCase(
                limits: .init(
                    maxDuration: 1,
                    maxFrameCount: 4,
                    maxByteCount: 1_000),
                expectedValues: [6, 7, 8, 9]),
            RetentionCase(
                limits: .init(
                    maxDuration: 1,
                    maxFrameCount: 100,
                    maxByteCount: 16),
                expectedValues: [6, 7, 8, 9]),
        ])
    func enforcesEveryRetentionCapacity(retention: RetentionCase) throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe, limits: retention.limits)
        let start = hostTime(seconds: 100)

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: hostTime(seconds: 100.010))

        let snapshot = router.snapshot
        #expect(snapshot.bufferedFrameCount == 4)
        #expect(snapshot.bufferedByteCount == 16)
        #expect(snapshot.retainedDuration <= 0.004_001)

        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageLost(
                    pressHostTime: addingFrames(3, to: start),
                    evictedThroughHostTime: addingFrames(6, to: start))
        ) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: addingFrames(3, to: start)))
        }
        #expect(probe.factoryInvocationCount == 0)

        _ = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: addingFrames(6, to: start)))
        #expect(probe.sampleGroups == [retention.expectedValues])
    }

    @Test("Promotion rejects a press whose audio was evicted from pre-roll")
    func promotionRejectsEvictedPostPressAudio() throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            limits: .init(
                maxDuration: 1,
                maxFrameCount: 4,
                maxByteCount: 1_000))
        let start = hostTime(seconds: 100)

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: addingFrames(10, to: start))
        let pressHostTime = addingFrames(3, to: start)

        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageLost(
                    pressHostTime: pressHostTime,
                    evictedThroughHostTime: addingFrames(6, to: start))
        ) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: pressHostTime))
        }
        #expect(probe.factoryInvocationCount == 0)
        #expect(!router.snapshot.hasActiveDictation)
    }

    @Test("A cold router cannot claim a key-down boundary")
    func coldRouterCannotPromote() throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            continuousCaptureStartedAt: nil)
        let pressHostTime = hostTime(seconds: 100)

        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageUnavailable(
                    pressHostTime: pressHostTime)
        ) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: pressHostTime))
        }
        #expect(probe.factoryInvocationCount == 0)
        #expect(!router.snapshot.hasActiveDictation)
    }

    @Test("A released boundary cannot promote from an empty cold router")
    func releasedBoundaryRequiresPreviewCoverage() throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            continuousCaptureStartedAt: nil)
        let pressHostTime = hostTime(seconds: 100)
        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: pressHostTime)
        #expect(
            boundary.publish(
                releaseHostTime: addingFrames(1, to: pressHostTime)))

        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageUnavailable(
                    pressHostTime: pressHostTime)
        ) {
            try router.promote(releaseBoundary: boundary)
        }
        #expect(probe.factoryInvocationCount == 0)
        #expect(!router.snapshot.hasActiveDictation)
    }

    @Test("A released boundary can wait for its continuous preview callback")
    func releasedBoundaryWaitsForPreviewCallback() async throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let pressHostTime = hostTime(seconds: 100)
        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: pressHostTime)
        #expect(
            boundary.publish(
                releaseHostTime: addingFrames(4, to: pressHostTime)))

        let route = try router.promote(releaseBoundary: boundary)
        let wait = Task { await router.waitUntilReleaseObserved(for: route) }
        #expect(await waitForReleaseWaiter(on: router))
        router.ingest(
            try pcmBuffer(values: [0, 1, 2, 3]),
            timestamp: AVAudioTime(hostTime: pressHostTime),
            observedHostTime: addingFrames(4, to: pressHostTime))

        #expect(await wait.value)
        #expect(probe.sampleGroups == [[0, 1, 2, 3]])
    }

    @Test("A recovery tap started after key-down cannot claim the prefix")
    func lateRecoveryTapCannotPromote() throws {
        let probe = SinkProbe()
        let pressHostTime = hostTime(seconds: 100)
        let router = makeRouter(
            probe: probe,
            continuousCaptureStartedAt: hostTime(seconds: 100.001))

        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageUnavailable(
                    pressHostTime: pressHostTime)
        ) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: pressHostTime))
        }
        #expect(probe.factoryInvocationCount == 0)
    }

    @Test("Clearing pre-roll records the discarded coverage frontier")
    func clearPreRollRecordsCoverageLoss() throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let start = hostTime(seconds: 100)

        router.ingest(
            try pcmBuffer(values: [0, 1, 2, 3]),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: addingFrames(4, to: start))
        router.clearPreRoll()

        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageLost(
                    pressHostTime: addingFrames(2, to: start),
                    evictedThroughHostTime: addingFrames(4, to: start))
        ) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: addingFrames(2, to: start)))
        }
        #expect(probe.factoryInvocationCount == 0)
    }

    @Test("A press at the eviction frontier retains complete post-press audio")
    func promotionAcceptsEvictionFrontier() throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            limits: .init(
                maxDuration: 1,
                maxFrameCount: 4,
                maxByteCount: 1_000))
        let start = hostTime(seconds: 100)

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: addingFrames(10, to: start))

        _ = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: addingFrames(6, to: start)))

        #expect(probe.sampleGroups == [[6, 7, 8, 9]])
    }

    @Test("Promotion rejects a press whose preview coverage contains a timestamp gap")
    func promotionRejectsTimestampGap() throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            limits: .init(
                maxDuration: 1,
                maxFrameCount: 4,
                maxByteCount: 1_000))
        let start = hostTime(seconds: 100)

        router.ingest(
            try pcmBuffer(values: [0, 1, 2, 3]),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: addingFrames(4, to: start))
        router.ingest(
            try pcmBuffer(values: [10, 11, 12, 13]),
            timestamp: AVAudioTime(hostTime: addingFrames(10, to: start)),
            observedHostTime: addingFrames(14, to: start))

        let pressHostTime = addingFrames(6, to: start)
        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageLost(
                    pressHostTime: pressHostTime,
                    evictedThroughHostTime: addingFrames(10, to: start))
        ) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: pressHostTime))
        }
        #expect(probe.sampleGroups.isEmpty)
    }

    @Test("Preview recovery requires retained audio to reach the exact press")
    func previewRecoveryRequiresCoverageThroughPress() throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let start = hostTime(seconds: 100)

        #expect(!router.hasRetainedCoverage(at: start))
        router.ingest(
            try pcmBuffer(values: [0, 1, 2, 3]),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: addingFrames(4, to: start))

        #expect(router.hasRetainedCoverage(at: addingFrames(2, to: start)))
        #expect(!router.hasRetainedCoverage(at: addingFrames(6, to: start)))
    }

    @Test("Long preview remains bounded and does not allocate a dictation sink")
    func longPreviewStaysBoundedAndLazy() throws {
        let probe = SinkProbe()
        let limits = TimestampedAudioFrameRouter.Limits(
            maxDuration: 0.020,
            maxFrameCount: 20,
            maxByteCount: 80)
        let router = makeRouter(probe: probe, limits: limits)
        let base = hostTime(seconds: 100)

        for index in 0..<2_000 {
            let start = addingFrames(index * 10, to: base)
            router.ingest(
                try pcmBuffer(values: Array(repeating: index, count: 10)),
                timestamp: AVAudioTime(hostTime: start),
                observedHostTime: addingFrames(index * 10 + 10, to: base))

            let snapshot = router.snapshot
            #expect(snapshot.bufferedFrameCount <= limits.maxFrameCount)
            #expect(snapshot.bufferedByteCount <= limits.maxByteCount)
            #expect(snapshot.retainedDuration <= limits.maxDuration + 0.000_001)
            #expect(!snapshot.hasActiveDictation)
        }

        #expect(probe.factoryInvocationCount == 0)
        #expect(router.snapshot.bufferedBufferCount == 2)

        _ = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: addingFrames(19_980, to: base)))
        #expect(probe.factoryInvocationCount == 1)
    }

    @Test("Invalid timestamp fallback retains its whole uncertain suffix")
    func invalidTimestampFallbackIsBounded() throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            invalidTimestampPolicy: .estimateFromObservation(maximumFrameCount: 4))
        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: hostTime(seconds: 100.007))

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(),
            observedHostTime: hostTime(seconds: 100.010))
        #expect(boundary.publish(releaseHostTime: hostTime(seconds: 100.009)))
        _ = try router.promote(releaseBoundary: boundary)

        #expect(probe.sampleGroups == [[6, 7, 8, 9]])
        #expect(router.snapshot.invalidTimestampFallbackCount == 1)
        #expect(router.snapshot.invalidTimestampDroppedFrameCount == 6)
    }

    @Test("Discarded invalid timestamps poison overlapping promotion coverage")
    func invalidTimestampDiscardPolicy() throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            invalidTimestampPolicy: .discard)
        let observedHostTime = hostTime(seconds: 100.010)
        let pressHostTime = hostTime(seconds: 100.005)

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(),
            observedHostTime: observedHostTime)

        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageLost(
                    pressHostTime: pressHostTime,
                    evictedThroughHostTime: observedHostTime)
        ) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: pressHostTime))
        }
        #expect(probe.sampleGroups.isEmpty)
        #expect(router.snapshot.invalidTimestampDroppedFrameCount == 10)
    }

    @Test("A failed callback keeps continuity unproved until the next device frame")
    func failedCallbackPoisonsFollowingUnknownGap() throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            invalidTimestampPolicy: .discard)
        let start = hostTime(seconds: 100)

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: addingFrames(10, to: start))
        router.ingest(
            try pcmBuffer(values: Array(10..<20)),
            timestamp: AVAudioTime(),
            observedHostTime: addingFrames(20, to: start))
        router.ingest(
            try pcmBuffer(values: Array(30..<40)),
            timestamp: AVAudioTime(hostTime: addingFrames(30, to: start)),
            observedHostTime: addingFrames(40, to: start))

        let pressHostTime = addingFrames(25, to: start)
        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageLost(
                    pressHostTime: pressHostTime,
                    evictedThroughHostTime: addingFrames(30, to: start))
        ) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: pressHostTime))
        }
        #expect(probe.factoryInvocationCount == 0)
    }

    @Test("An active route owns an immutable press until it is finished")
    func activeRouteOwnsPressBoundary() throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let route = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: hostTime(seconds: 100)))

        #expect(throws: TimestampedAudioFrameRouter.PromotionError.dictationAlreadyActive) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: hostTime(seconds: 101)))
        }
        #expect(route.pressHostTime == hostTime(seconds: 100))

        #expect(router.finish(route))
        let next = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: hostTime(seconds: 101)))
        #expect(next.pressHostTime == hostTime(seconds: 101))
    }

    @Test("Release wait stays pending until ingest reaches the physical boundary")
    func releaseWaitsForCrossingFrame() async throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: hostTime(seconds: 100))
        let route = try router.promote(releaseBoundary: boundary)
        #expect(boundary.publish(releaseHostTime: hostTime(seconds: 100.010)))
        let wait = Task { await router.waitUntilReleaseObserved(for: route) }
        #expect(await waitForReleaseWaiter(on: router))

        router.ingest(
            try pcmBuffer(values: Array(0..<5)),
            timestamp: AVAudioTime(hostTime: hostTime(seconds: 100)),
            observedHostTime: hostTime(seconds: 100.005))

        #expect(router.snapshot.activeReleaseWaiterCount == 1)

        router.ingest(
            try pcmBuffer(values: Array(5..<10)),
            timestamp: AVAudioTime(hostTime: hostTime(seconds: 100.005)),
            observedHostTime: hostTime(seconds: 100.010))

        #expect(await wait.value)
        #expect(router.snapshot.activeReleaseWaiterCount == 0)
    }

    @Test("A release deadline does not join a blocked routing callback")
    func releaseDeadlineDoesNotJoinBlockedRouter() async throws {
        let sinkEntered = DispatchSemaphore(value: 0)
        let releaseSink = DispatchSemaphore(value: 0)
        let ingestFinished = DispatchSemaphore(value: 0)
        let router = TimestampedAudioFrameRouter {
            TimestampedAudioFrameRouter.DictationSink { _ in
                sinkEntered.signal()
                releaseSink.wait()
            }
        }
        let start = hostTime(seconds: 100)
        router.markContinuousCaptureStarted(atHostTime: start)
        let boundary = AudioCaptureReleaseBoundary(pressHostTime: start)
        let route = try router.promote(releaseBoundary: boundary)
        #expect(boundary.publish(releaseHostTime: addingFrames(4, to: start)))

        DispatchQueue.global().async {
            _ = router.ingest(
                try! self.pcmBuffer(values: [0, 1, 2, 3]),
                timestamp: AVAudioTime(hostTime: start),
                observedHostTime: self.addingFrames(4, to: start))
            ingestFinished.signal()
        }
        let sinkDidEnter = await waitForSemaphore(sinkEntered)
        #expect(sinkDidEnter)

        let releaseDrain = DetachedOperation {
            await router.waitUntilReleaseObserved(for: route)
        }
        let outcome = await releaseDrain.outcome(timeout: 0.01)
        guard case .deadline = outcome else {
            Issue.record("Expected release observation deadline")
            releaseSink.signal()
            return
        }

        releaseSink.signal()
        let ingestDidFinish = await waitForSemaphore(ingestFinished)
        #expect(ingestDidFinish)
        router.reset()
        #expect(await releaseDrain.task.value)
    }

    @Test("A timestamp gap crossing release fails the active route")
    func timestampGapFailsActiveReleaseDrain() async throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let start = hostTime(seconds: 100)
        let boundary = AudioCaptureReleaseBoundary(pressHostTime: start)
        let route = try router.promote(releaseBoundary: boundary)

        router.ingest(
            try pcmBuffer(values: [0, 1, 2, 3]),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: addingFrames(4, to: start))
        #expect(boundary.publish(releaseHostTime: addingFrames(7, to: start)))
        let wait = Task { await router.waitUntilReleaseObserved(for: route) }
        #expect(await waitForReleaseWaiter(on: router))

        router.ingest(
            try pcmBuffer(values: [10, 11, 12, 13]),
            timestamp: AVAudioTime(hostTime: addingFrames(10, to: start)),
            observedHostTime: addingFrames(14, to: start))

        #expect(!(await wait.value))
        #expect(
            probe.integrityFailure
                == AudioCaptureIntegrityFailure(
                    stage: .timestampCoverage,
                    affectedFrameCount: 6))
    }

    @Test("A timestamp regression cannot satisfy the release boundary")
    func timestampRegressionFailsActiveReleaseDrain() async throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let start = hostTime(seconds: 100)
        let boundary = AudioCaptureReleaseBoundary(pressHostTime: start)
        let route = try router.promote(releaseBoundary: boundary)

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(hostTime: start),
            observedHostTime: addingFrames(10, to: start))
        #expect(boundary.publish(releaseHostTime: addingFrames(15, to: start)))
        let wait = Task { await router.waitUntilReleaseObserved(for: route) }
        #expect(await waitForReleaseWaiter(on: router))

        router.ingest(
            try pcmBuffer(values: Array(10..<20)),
            timestamp: AVAudioTime(hostTime: addingFrames(5, to: start)),
            observedHostTime: addingFrames(15, to: start))

        #expect(!(await wait.value))
        #expect(
            probe.integrityFailure
                == AudioCaptureIntegrityFailure(
                    stage: .timestampCoverage,
                    affectedFrameCount: 5))
    }

    @Test("Release wait sees a crossing frame already retained for replay")
    func releaseWaitUsesBufferedReplayProgress() async throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: hostTime(seconds: 100))

        router.ingest(
            try pcmBuffer(values: Array(0..<10)),
            timestamp: AVAudioTime(hostTime: hostTime(seconds: 100)),
            observedHostTime: hostTime(seconds: 100.010))
        #expect(boundary.publish(releaseHostTime: hostTime(seconds: 100.006)))
        let route = try router.promote(releaseBoundary: boundary)

        #expect(await router.waitUntilReleaseObserved(for: route))
        #expect(probe.sampleGroups == [[0, 1, 2, 3, 4, 5]])
    }

    @Test("A first callback wholly after release fails missing lower coverage")
    func postReleaseFirstFrameFailsCoverage() async throws {
        let probe = SinkProbe()
        let pressHostTime = hostTime(seconds: 100)
        let router = makeRouter(
            probe: probe,
            continuousCaptureStartedAt: pressHostTime)
        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: pressHostTime)
        let route = try router.promote(releaseBoundary: boundary)
        #expect(boundary.publish(releaseHostTime: hostTime(seconds: 100.006)))
        let wait = Task { await router.waitUntilReleaseObserved(for: route) }
        #expect(await waitForReleaseWaiter(on: router))

        router.ingest(
            try pcmBuffer(values: [6, 7, 8, 9]),
            timestamp: AVAudioTime(hostTime: hostTime(seconds: 100.006)),
            observedHostTime: hostTime(seconds: 100.010))

        #expect(!(await wait.value))
        #expect(probe.sampleGroups.isEmpty)
        #expect(
            probe.integrityFailure
                == AudioCaptureIntegrityFailure(
                    stage: .timestampCoverage,
                    affectedFrameCount: 6))
    }

    @Test("Finishing a stale route cannot fail the current route's drain wait")
    func staleFinishDoesNotResolveCurrentWait() async throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let stale = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: hostTime(seconds: 99)))
        #expect(router.finish(stale))

        let boundary = AudioCaptureReleaseBoundary(
            pressHostTime: hostTime(seconds: 100))
        let current = try router.promote(releaseBoundary: boundary)
        #expect(boundary.publish(releaseHostTime: hostTime(seconds: 100.005)))
        let wait = Task { await router.waitUntilReleaseObserved(for: current) }
        #expect(await waitForReleaseWaiter(on: router))

        #expect(!router.finish(stale))
        #expect(router.snapshot.activeReleaseWaiterCount == 1)
        router.ingest(
            try pcmBuffer(values: Array(0..<5)),
            timestamp: AVAudioTime(hostTime: hostTime(seconds: 100)),
            observedHostTime: hostTime(seconds: 100.005))

        #expect(await wait.value)
    }

    @Test("Exact finish and reset fail an outstanding release wait")
    func finishAndResetFailOutstandingWaits() async throws {
        let probe = SinkProbe()
        let router = makeRouter(probe: probe)
        let first = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: hostTime(seconds: 100)))
        let finishWait = Task {
            await router.waitUntilReleaseObserved(for: first)
        }
        #expect(await waitForReleaseWaiter(on: router))

        #expect(router.finish(first))
        #expect(!(await finishWait.value))

        let second = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: hostTime(seconds: 101)))
        let resetWait = Task {
            await router.waitUntilReleaseObserved(for: second)
        }
        #expect(await waitForReleaseWaiter(on: router))

        router.reset()
        #expect(!(await resetWait.value))
    }

    @Test("An active-route retention copy failure fails the release drain")
    func activeRouteRetentionCopyFailureFailsRelease() async throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            copyFrame: { buffer, range, purpose in
                guard purpose != .retention else { return nil }
                return copyPCMBuffer(buffer, range: range)
            })
        let start = hostTime(seconds: 100)
        let boundary = AudioCaptureReleaseBoundary(pressHostTime: start)
        let route = try router.promote(releaseBoundary: boundary)
        #expect(boundary.publish(releaseHostTime: addingFrames(5, to: start)))
        let wait = Task { await router.waitUntilReleaseObserved(for: route) }
        #expect(await waitForReleaseWaiter(on: router))

        #expect(
            router.ingest(
                try pcmBuffer(values: Array(0..<5)),
                timestamp: AVAudioTime(hostTime: start),
                observedHostTime: addingFrames(5, to: start)) == .copyFailed)

        #expect(!(await wait.value))
        #expect(
            probe.integrityFailure
                == AudioCaptureIntegrityFailure(
                    stage: .retentionCopy,
                    affectedFrameCount: 5))
    }

    @Test("An active-route invalid timestamp discard fails the release drain")
    func activeRouteInvalidTimestampFailsRelease() async throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            invalidTimestampPolicy: .discard)
        let start = hostTime(seconds: 100)
        let boundary = AudioCaptureReleaseBoundary(pressHostTime: start)
        let route = try router.promote(releaseBoundary: boundary)
        #expect(boundary.publish(releaseHostTime: addingFrames(5, to: start)))
        let wait = Task { await router.waitUntilReleaseObserved(for: route) }
        #expect(await waitForReleaseWaiter(on: router))

        #expect(
            router.ingest(
                try pcmBuffer(values: Array(0..<5)),
                timestamp: AVAudioTime(),
                observedHostTime: addingFrames(5, to: start))
                == .invalidTimestampDiscarded)

        #expect(!(await wait.value))
        #expect(
            probe.integrityFailure
                == AudioCaptureIntegrityFailure(
                    stage: .timestampCoverage,
                    affectedFrameCount: 5))
    }

    @Test("A pre-promotion copy failure poisons only overlapping presses")
    func prePromotionCopyFailurePoisonsCoverage() throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            copyFrame: { buffer, range, purpose in
                guard purpose != .retention else { return nil }
                return copyPCMBuffer(buffer, range: range)
            })
        let start = hostTime(seconds: 100)
        let failedEnd = addingFrames(5, to: start)
        #expect(
            router.ingest(
                try pcmBuffer(values: Array(0..<5)),
                timestamp: AVAudioTime(hostTime: start),
                observedHostTime: failedEnd) == .copyFailed)

        let overlappingPress = addingFrames(2, to: start)
        #expect(
            throws: TimestampedAudioFrameRouter.PromotionError
                .preRollCoverageLost(
                    pressHostTime: overlappingPress,
                    evictedThroughHostTime: failedEnd)
        ) {
            try router.promote(
                releaseBoundary: AudioCaptureReleaseBoundary(
                    pressHostTime: overlappingPress))
        }

        let later = try router.promote(
            releaseBoundary: AudioCaptureReleaseBoundary(
                pressHostTime: failedEnd))
        #expect(later.pressHostTime == failedEnd)
    }

    @Test("A failed route slice cannot report a successful release crossing")
    func routeSliceCopyFailureFailsCrossing() async throws {
        let probe = SinkProbe()
        let router = makeRouter(
            probe: probe,
            copyFrame: { buffer, range, purpose in
                guard purpose != .routeSlice else { return nil }
                return copyPCMBuffer(buffer, range: range)
            })
        let start = hostTime(seconds: 100)
        let boundary = AudioCaptureReleaseBoundary(pressHostTime: start)
        let route = try router.promote(releaseBoundary: boundary)
        #expect(boundary.publish(releaseHostTime: addingFrames(5, to: start)))
        let wait = Task { await router.waitUntilReleaseObserved(for: route) }
        #expect(await waitForReleaseWaiter(on: router))

        #expect(
            router.ingest(
                try pcmBuffer(values: Array(0..<5)),
                timestamp: AVAudioTime(hostTime: start),
                observedHostTime: addingFrames(5, to: start)) == .routed)

        #expect(!(await wait.value))
        #expect(probe.sampleGroups.isEmpty)
        #expect(
            probe.integrityFailure
                == AudioCaptureIntegrityFailure(
                    stage: .routeSliceCopy,
                    affectedFrameCount: 5))
    }

    private func makeRouter(
        probe: SinkProbe,
        limits: TimestampedAudioFrameRouter.Limits = .init(
            maxDuration: 1,
            maxFrameCount: 10_000,
            maxByteCount: 100_000),
        invalidTimestampPolicy: TimestampedAudioFrameRouter.InvalidTimestampPolicy =
            .estimateFromObservation(maximumFrameCount: 4_096),
        copyFrame: TimestampedAudioFrameRouter.FrameCopy? = nil,
        continuousCaptureStartedAt: UInt64? = AVAudioTime.hostTime(
            forSeconds: 99)
    ) -> TimestampedAudioFrameRouter {
        let router: TimestampedAudioFrameRouter
        if let copyFrame {
            router = TimestampedAudioFrameRouter(
                limits: limits,
                invalidTimestampPolicy: invalidTimestampPolicy,
                copyFrame: copyFrame,
                makeDictationSink: probe.makeSink)
        } else {
            router = TimestampedAudioFrameRouter(
                limits: limits,
                invalidTimestampPolicy: invalidTimestampPolicy,
                makeDictationSink: probe.makeSink)
        }
        if let continuousCaptureStartedAt {
            router.markContinuousCaptureStarted(
                atHostTime: continuousCaptureStartedAt)
        }
        return router
    }

    private func pcmBuffer(values: [Int]) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 1_000,
                channels: 1,
                interleaved: false))
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(values.count)))
        buffer.frameLength = AVAudioFrameCount(values.count)
        let samples = try #require(buffer.floatChannelData?[0])
        for (index, value) in values.enumerated() {
            samples[index] = Float(value)
        }
        return buffer
    }

    private func overwrite(_ buffer: AVAudioPCMBuffer, with value: Float) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = value
        }
    }

    private func hostTime(seconds: TimeInterval) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: seconds)
    }

    private func addingFrames(_ frames: Int, to hostTime: UInt64) -> UInt64 {
        hostTime + AVAudioTime.hostTime(forSeconds: Double(frames) / 1_000)
    }

    private func waitForReleaseWaiter(
        on router: TimestampedAudioFrameRouter
    ) async -> Bool {
        for _ in 0..<100 {
            if router.snapshot.activeReleaseWaiterCount == 1 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForSemaphore(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime = .now() + 1
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }
}

struct RetentionCase: Sendable {
    let limits: TimestampedAudioFrameRouter.Limits
    let expectedValues: [Int]
}

private final class SinkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var factoryCount = 0
    private var frames: [TimestampedAudioFrameRouter.RoutedFrame] = []
    private var integrityPublications: [AudioCaptureIntegrityPublication] = []

    lazy var makeSink: TimestampedAudioFrameRouter.DictationSinkFactory = {
        self.lock.withLock {
            self.factoryCount += 1
        }
        let integrity = AudioCaptureIntegrityPublication()
        self.lock.withLock {
            self.integrityPublications.append(integrity)
        }
        return TimestampedAudioFrameRouter.DictationSink(
            integrity: integrity,
            consume: { frame in
                self.lock.withLock {
                    self.frames.append(frame)
                }
            })
    }

    var factoryInvocationCount: Int {
        lock.withLock { factoryCount }
    }

    var sequenceNumbers: [UInt64] {
        lock.withLock { frames.map(\.sequenceNumber) }
    }

    var sampleGroups: [[Int]] {
        lock.withLock {
            frames.map { frame in
                guard let samples = frame.buffer.floatChannelData?[0] else {
                    return []
                }
                return (0..<Int(frame.buffer.frameLength)).map {
                    Int(samples[$0])
                }
            }
        }
    }

    var integrityFailure: AudioCaptureIntegrityFailure? {
        lock.withLock { integrityPublications.last?.failure }
    }
}

private func copyPCMBuffer(
    _ buffer: AVAudioPCMBuffer,
    range: Range<Int>
) -> AVAudioPCMBuffer? {
    guard !range.isEmpty,
        let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: AVAudioFrameCount(range.count)),
        let source = buffer.floatChannelData,
        let destination = copy.floatChannelData
    else { return nil }
    copy.frameLength = AVAudioFrameCount(range.count)
    for channel in 0..<Int(buffer.format.channelCount) {
        for frame in range.indices {
            destination[channel][frame - range.lowerBound] = source[channel][frame]
        }
    }
    return copy
}
