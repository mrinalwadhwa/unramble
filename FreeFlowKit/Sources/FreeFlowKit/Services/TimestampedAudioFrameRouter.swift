import Foundation

#if canImport(AVFoundation)
    import AVFoundation
    import AudioToolbox
    import CoreAudio

    /// Owns the bounded audio history captured by a persistent microphone tap
    /// and promotes that history into one timestamp-owned dictation route.
    ///
    /// Calls are serialized. Buffers retained for pre-roll and buffers handed to
    /// the dictation sink are independent copies of the tap-owned source buffer.
    public final class TimestampedAudioFrameRouter: @unchecked Sendable {
        public struct Limits: Sendable, Equatable {
            public let maxDuration: TimeInterval
            public let maxFrameCount: Int
            public let maxByteCount: Int

            public init(
                maxDuration: TimeInterval = 2,
                maxFrameCount: Int = 192_000,
                maxByteCount: Int = 8 * 1_024 * 1_024
            ) {
                precondition(maxDuration > 0)
                precondition(maxFrameCount > 0)
                precondition(maxByteCount > 0)
                self.maxDuration = maxDuration
                self.maxFrameCount = maxFrameCount
                self.maxByteCount = maxByteCount
            }
        }

        /// Invalid AVAudioTime values cannot be compared with physical key
        /// boundaries. The loss-preserving fallback anchors a bounded suffix at
        /// callback observation time; callers may instead elect to discard it.
        public enum InvalidTimestampPolicy: Sendable, Equatable {
            case estimateFromObservation(maximumFrameCount: Int)
            case discard
        }

        public enum TimestampOrigin: Sendable, Equatable {
            case audioDevice
            case estimatedFromObservation
        }

        public enum PromotionError: Error, Sendable, Equatable {
            case dictationAlreadyActive

            /// At least one frame in `[pressHostTime, evictedThroughHostTime)`
            /// was discarded before promotion could claim it.
            case preRollCoverageLost(
                pressHostTime: UInt64,
                evictedThroughHostTime: UInt64)
            case preRollCoverageUnavailable(pressHostTime: UInt64)
            case sinkCreationFailed
        }

        public enum IngestResult: Sendable, Equatable {
            case routed
            case empty
            case invalidTimestampDiscarded
            case copyFailed
        }

        public struct Route: @unchecked Sendable, Hashable {
            fileprivate let id: UUID
            public let pressHostTime: UInt64
            public let releaseBoundary: AudioCaptureReleaseBoundary

            public static func == (lhs: Route, rhs: Route) -> Bool {
                lhs.id == rhs.id
            }

            public func hash(into hasher: inout Hasher) {
                hasher.combine(id)
            }

            /// Key-up should publish directly through this route so an audio
            /// callback observes the boundary without waiting for another queue.
            @discardableResult
            public func publishRelease(at releaseHostTime: UInt64) -> Bool {
                releaseBoundary.publish(releaseHostTime: releaseHostTime)
            }
        }

        /// The sink owns each routed buffer and may mutate it without changing
        /// the retained pre-roll copy.
        public struct RoutedFrame: @unchecked Sendable {
            public let buffer: AVAudioPCMBuffer
            public let startHostTime: UInt64
            public let sequenceNumber: UInt64
            public let timestampOrigin: TimestampOrigin
        }

        public struct Snapshot: Sendable, Equatable {
            public let bufferedBufferCount: Int
            public let bufferedFrameCount: Int
            public let bufferedByteCount: Int
            public let retainedDuration: TimeInterval
            public let hasActiveDictation: Bool
            public let invalidTimestampFallbackCount: Int
            public let invalidTimestampDroppedFrameCount: Int
            public let copyFailureCount: Int
            public let activeReleaseWaiterCount: Int
        }

        public struct DictationSink: @unchecked Sendable {
            fileprivate let integrity: AudioCaptureIntegrityPublication
            private let consumeFrame: @Sendable (RoutedFrame) -> Void

            public init(consume: @escaping @Sendable (RoutedFrame) -> Void) {
                self.init(
                    integrity: AudioCaptureIntegrityPublication(),
                    consume: consume)
            }

            init(
                integrity: AudioCaptureIntegrityPublication,
                consume: @escaping @Sendable (RoutedFrame) -> Void
            ) {
                self.integrity = integrity
                self.consumeFrame = consume
            }

            fileprivate var integrityFailure: AudioCaptureIntegrityFailure? {
                integrity.failure
            }

            fileprivate func consume(_ frame: RoutedFrame) {
                consumeFrame(frame)
            }

            fileprivate func recordIntegrityFailure(
                _ failure: AudioCaptureIntegrityFailure
            ) {
                integrity.record(failure)
            }
        }

        public typealias DictationSinkFactory = @Sendable () throws -> DictationSink

        enum CopyPurpose: Sendable, Equatable {
            case retention
            case routeSlice
        }

        typealias FrameCopy = @Sendable (
            _ buffer: AVAudioPCMBuffer,
            _ range: Range<Int>,
            _ purpose: CopyPurpose
        ) -> AVAudioPCMBuffer?

        private struct PreparedFrame: @unchecked Sendable {
            let buffer: AVAudioPCMBuffer
            let startHostTime: UInt64
            let bytesPerFrame: Int
            let timestampOrigin: TimestampOrigin
            let invalidTimestampDroppedFrameCount: Int
            let precedingLoss: LostFrames?
        }

        private struct LostFrames: Sendable {
            let frameCount: Int
            let startHostTime: UInt64?
            let endHostTime: UInt64?
            let stage: AudioCaptureIntegrityFailure.Stage
        }

        private struct StoredFrame: @unchecked Sendable {
            let buffer: AVAudioPCMBuffer
            let startHostTime: UInt64
            let bytesPerFrame: Int
            let sequenceNumber: UInt64
            let timestampOrigin: TimestampOrigin

            var frameCount: Int {
                Int(buffer.frameLength)
            }

            var byteCount: Int {
                frameCount * bytesPerFrame
            }

            var endHostTime: UInt64 {
                Self.addingFrames(
                    frameCount,
                    to: startHostTime,
                    sampleRate: buffer.format.sampleRate)
            }

            func droppingFirst(_ count: Int) -> StoredFrame? {
                let retainedStart = min(max(count, 0), frameCount)
                guard retainedStart < frameCount,
                    let retained = Self.copySlice(
                        buffer,
                        range: retainedStart..<frameCount)
                else { return nil }

                return StoredFrame(
                    buffer: retained,
                    startHostTime: Self.addingFrames(
                        retainedStart,
                        to: startHostTime,
                        sampleRate: buffer.format.sampleRate),
                    bytesPerFrame: bytesPerFrame,
                    sequenceNumber: sequenceNumber,
                    timestampOrigin: timestampOrigin)
            }

            private static func addingFrames(
                _ frameCount: Int,
                to hostTime: UInt64,
                sampleRate: Double
            ) -> UInt64 {
                guard frameCount > 0, sampleRate > 0 else { return hostTime }
                let offset = AVAudioTime.hostTime(
                    forSeconds: Double(frameCount) / sampleRate)
                let (result, overflow) = hostTime.addingReportingOverflow(offset)
                return overflow ? UInt64.max : result
            }

            private static func copySlice(
                _ buffer: AVAudioPCMBuffer,
                range: Range<Int>
            ) -> AVAudioPCMBuffer? {
                TimestampedAudioFrameRouter.copySlice(buffer, range: range)
            }
        }

        private final class ActiveRoute {
            let route: Route
            let sink: DictationSink
            var pendingFrames: [StoredFrame] = []
            var pendingIndex = 0
            var isDelivering = false
            var hasObservedRelease = false
            var releaseWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

            init(route: Route, sink: DictationSink) {
                self.route = route
                self.sink = sink
            }
        }

        private let limits: Limits
        private let invalidTimestampPolicy: InvalidTimestampPolicy
        private let copyFrame: FrameCopy
        private let makeDictationSink: DictationSinkFactory
        private let routingQueue = DispatchQueue(
            label: "com.freeflow.timestamped-audio-frame-router",
            qos: .userInteractive)
        private let routingQueueKey = DispatchSpecificKey<UUID>()
        private let routingQueueID = UUID()

        private var preRoll: [StoredFrame] = []
        private var bufferedFrameCount = 0
        private var bufferedByteCount = 0
        private var preRollEvictedThroughHostTime: UInt64?
        private var nextSequenceNumber: UInt64 = 0
        private var activeRoute: ActiveRoute?
        private var isPromoting = false
        private var invalidTimestampFallbackCount = 0
        private var invalidTimestampDroppedFrameCount = 0
        private var copyFailureCount = 0
        private var continuousCaptureStartedAtHostTime: UInt64?
        private var deviceContinuityIsUnknown = false
        private var deviceContinuityUnknownSinceHostTime: UInt64?
        private var lastDeviceFrameEndHostTime: UInt64?

        public init(
            limits: Limits = Limits(),
            invalidTimestampPolicy: InvalidTimestampPolicy =
                .estimateFromObservation(maximumFrameCount: 4_096),
            makeDictationSink: @escaping DictationSinkFactory
        ) {
            if case .estimateFromObservation(let maximumFrameCount) =
                invalidTimestampPolicy
            {
                precondition(maximumFrameCount > 0)
            }
            self.limits = limits
            self.invalidTimestampPolicy = invalidTimestampPolicy
            self.copyFrame = { buffer, range, _ in
                TimestampedAudioFrameRouter.copySlice(buffer, range: range)
            }
            self.makeDictationSink = makeDictationSink
            routingQueue.setSpecific(
                key: routingQueueKey,
                value: routingQueueID)
        }

        init(
            limits: Limits = Limits(),
            invalidTimestampPolicy: InvalidTimestampPolicy =
                .estimateFromObservation(maximumFrameCount: 4_096),
            copyFrame: @escaping FrameCopy,
            makeDictationSink: @escaping DictationSinkFactory
        ) {
            if case .estimateFromObservation(let maximumFrameCount) =
                invalidTimestampPolicy
            {
                precondition(maximumFrameCount > 0)
            }
            self.limits = limits
            self.invalidTimestampPolicy = invalidTimestampPolicy
            self.copyFrame = copyFrame
            self.makeDictationSink = makeDictationSink
            routingQueue.setSpecific(
                key: routingQueueKey,
                value: routingQueueID)
        }

        @discardableResult
        public func ingest(
            _ buffer: AVAudioPCMBuffer,
            timestamp: AVAudioTime
        ) -> IngestResult {
            ingest(
                buffer,
                timestamp: timestamp,
                observedHostTime: AudioCaptureReleaseFence.currentHostTime())
        }

        /// Publishes the physical tap boundary independently of the first
        /// callback. Dictation promotion must prove that this tap predates the
        /// key-down it claims; a tap started after key-down cannot recover the
        /// missing prefix.
        public func markContinuousCaptureStarted(atHostTime hostTime: UInt64) {
            serialized {
                continuousCaptureStartedAtHostTime = min(
                    continuousCaptureStartedAtHostTime ?? hostTime,
                    hostTime)
                if lastDeviceFrameEndHostTime == nil,
                    !deviceContinuityIsUnknown
                {
                    lastDeviceFrameEndHostTime = hostTime
                }
            }
        }

        /// `observedHostTime` is explicit so fallback behavior is deterministic
        /// and uses the same Mach clock as key boundaries.
        @discardableResult
        public func ingest(
            _ buffer: AVAudioPCMBuffer,
            timestamp: AVAudioTime,
            observedHostTime: UInt64
        ) -> IngestResult {
            guard buffer.frameLength > 0 else { return .empty }

            let preparation = prepareFrame(
                buffer,
                timestamp: timestamp,
                observedHostTime: observedHostTime)
            switch preparation {
            case .invalidTimestampDiscarded(let loss):
                serialized {
                    markDeviceContinuityUnknown(after: loss.endHostTime)
                    invalidTimestampDroppedFrameCount += loss.frameCount
                    record(loss, on: activeRoute)
                }
                return .invalidTimestampDiscarded
            case .copyFailed(let loss):
                serialized {
                    markDeviceContinuityUnknown(after: loss.endHostTime)
                    copyFailureCount += 1
                    record(loss, on: activeRoute)
                }
                return .copyFailed
            case .frame(let prepared):
                serialized {
                    if prepared.timestampOrigin == .estimatedFromObservation {
                        invalidTimestampFallbackCount += 1
                        invalidTimestampDroppedFrameCount +=
                            prepared.invalidTimestampDroppedFrameCount
                    }
                    if let precedingLoss = prepared.precedingLoss {
                        record(precedingLoss, on: activeRoute)
                    }

                    if prepared.timestampOrigin == .audioDevice {
                        recordDeviceTimestampDiscontinuity(before: prepared)
                    } else {
                        let frameEndHostTime = Self.addingFrames(
                            Int(prepared.buffer.frameLength),
                            to: prepared.startHostTime,
                            sampleRate: prepared.buffer.format.sampleRate)
                        markDeviceContinuityUnknown(after: frameEndHostTime)
                    }

                    let stored = StoredFrame(
                        buffer: prepared.buffer,
                        startHostTime: prepared.startHostTime,
                        bytesPerFrame: prepared.bytesPerFrame,
                        sequenceNumber: nextSequenceNumber,
                        timestampOrigin: prepared.timestampOrigin)
                    nextSequenceNumber &+= 1

                    appendToPreRoll(stored)
                    if let activeRoute {
                        activeRoute.pendingFrames.append(stored)
                        drain(activeRoute)
                        observeReleaseCrossing(
                            on: activeRoute,
                            candidateEndHostTime: stored.endHostTime)
                    }
                }
                return .routed
            }
        }

        /// Atomically fixes the lower boundary, creates the sink, and replays
        /// retained frames before a concurrent ingest can deliver live audio.
        public func promote(
            releaseBoundary: AudioCaptureReleaseBoundary
        ) throws -> Route {
            try serialized {
                guard activeRoute == nil, !isPromoting else {
                    throw PromotionError.dictationAlreadyActive
                }
                guard continuousCaptureStartedAtHostTime.map({
                    $0 <= releaseBoundary.pressHostTime
                }) == true
                else {
                    throw PromotionError.preRollCoverageUnavailable(
                        pressHostTime: releaseBoundary.pressHostTime)
                }
                if let evictedThroughHostTime =
                    preRollEvictedThroughHostTime,
                    releaseBoundary.pressHostTime < evictedThroughHostTime
                {
                    throw PromotionError.preRollCoverageLost(
                        pressHostTime: releaseBoundary.pressHostTime,
                        evictedThroughHostTime: evictedThroughHostTime)
                }
                isPromoting = true
                defer { isPromoting = false }

                let sink: DictationSink
                do {
                    sink = try makeDictationSink()
                } catch {
                    throw PromotionError.sinkCreationFailed
                }

                let route = Route(
                    id: UUID(),
                    pressHostTime: releaseBoundary.pressHostTime,
                    releaseBoundary: releaseBoundary)
                let active = ActiveRoute(route: route, sink: sink)
                active.pendingFrames = preRoll
                activeRoute = active
                drain(active)
                observeReleaseCrossing(on: active, candidateEndHostTime: nil)
                return route
            }
        }

        /// Whether an already-running preview tap has retained uninterrupted
        /// coverage through this press. Future callbacks may extend coverage;
        /// promotion performs the same eviction/loss check again.
        func hasRetainedCoverage(at pressHostTime: UInt64) -> Bool {
            serialized {
                hasRetainedCoverageLocked(at: pressHostTime)
            }
        }

        /// Whether a still-running tap can eventually prove this press even if
        /// the callback containing the boundary has not arrived yet.
        func canPromoteFromContinuousCapture(at pressHostTime: UInt64) -> Bool {
            serialized {
                canPromoteFromContinuousCaptureLocked(at: pressHostTime)
            }
        }

        private func canPromoteFromContinuousCaptureLocked(
            at pressHostTime: UInt64
        ) -> Bool {
            guard let startedAt = continuousCaptureStartedAtHostTime,
                startedAt <= pressHostTime
            else { return false }
            guard let lostThrough = preRollEvictedThroughHostTime else {
                return true
            }
            return pressHostTime >= lostThrough
        }

        private func hasRetainedCoverageLocked(
            at pressHostTime: UInt64
        ) -> Bool {
            guard let first = preRoll.first,
                let last = preRoll.last,
                first.startHostTime <= pressHostTime,
                last.endHostTime >= pressHostTime
            else { return false }
            guard let evictedThroughHostTime = preRollEvictedThroughHostTime else {
                return true
            }
            return pressHostTime >= evictedThroughHostTime
        }

        /// Wait until a serialized tap callback reaches the exact route's
        /// published release boundary. A frame wholly after release counts as
        /// progress even though none of its samples are sent to the sink.
        public func waitUntilReleaseObserved(for route: Route) async -> Bool {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    serialized {
                        let isCancelled = withUnsafeCurrentTask {
                            $0?.isCancelled ?? false
                        }
                        guard !isCancelled,
                            let active = activeRoute,
                            active.route.id == route.id
                        else {
                            continuation.resume(returning: false)
                            return
                        }

                        observeReleaseCrossing(
                            on: active,
                            candidateEndHostTime: nil)
                        if active.sink.integrityFailure != nil {
                            continuation.resume(returning: false)
                        } else if active.hasObservedRelease {
                            continuation.resume(returning: true)
                        } else {
                            active.releaseWaiters[waiterID] = continuation
                        }
                    }
                }
            } onCancel: {
                self.cancelReleaseWaiter(
                    waiterID,
                    routeID: route.id)
            }
        }

        /// Finish only the exact route. A stale owner cannot close a later one.
        @discardableResult
        public func finish(_ route: Route) -> Bool {
            serialized {
                guard let active = activeRoute,
                    active.route.id == route.id
                else { return false }
                activeRoute = nil
                resolveReleaseWaiters(on: active, result: false)
                return true
            }
        }

        /// Invalidates the active owner and preview history. Outstanding waiters
        /// fail so a shutdown cannot strand a continuation.
        public func reset() {
            serialized {
                let active = activeRoute
                activeRoute = nil
                if let active {
                    resolveReleaseWaiters(on: active, result: false)
                }
                preRoll.removeAll(keepingCapacity: false)
                bufferedFrameCount = 0
                bufferedByteCount = 0
                preRollEvictedThroughHostTime = nil
                nextSequenceNumber = 0
                invalidTimestampFallbackCount = 0
                invalidTimestampDroppedFrameCount = 0
                copyFailureCount = 0
                continuousCaptureStartedAtHostTime = nil
                deviceContinuityIsUnknown = false
                deviceContinuityUnknownSinceHostTime = nil
                lastDeviceFrameEndHostTime = nil
            }
        }

        /// Discards preview history, for example after the physical input format
        /// changes. An active route and its already queued frames are unaffected.
        public func clearPreRoll() {
            serialized {
                for frame in preRoll {
                    recordPreRollEviction(through: frame.endHostTime)
                }
                preRoll.removeAll(keepingCapacity: false)
                bufferedFrameCount = 0
                bufferedByteCount = 0
            }
        }

        public var snapshot: Snapshot {
            serialized {
                Snapshot(
                    bufferedBufferCount: preRoll.count,
                    bufferedFrameCount: bufferedFrameCount,
                    bufferedByteCount: bufferedByteCount,
                    retainedDuration: retainedDuration,
                    hasActiveDictation: activeRoute != nil,
                    invalidTimestampFallbackCount: invalidTimestampFallbackCount,
                    invalidTimestampDroppedFrameCount:
                        invalidTimestampDroppedFrameCount,
                    copyFailureCount: copyFailureCount,
                    activeReleaseWaiterCount:
                        activeRoute?.releaseWaiters.count ?? 0)
            }
        }

        private enum Preparation {
            case frame(PreparedFrame)
            case invalidTimestampDiscarded(LostFrames)
            case copyFailed(LostFrames)
        }

        private func prepareFrame(
            _ buffer: AVAudioPCMBuffer,
            timestamp: AVAudioTime,
            observedHostTime: UInt64
        ) -> Preparation {
            let sourceFrameCount = Int(buffer.frameLength)
            let deviceStartHostTime = AudioCaptureReleaseFence.bufferStartHostTime(
                timestamp: timestamp)
            let estimatedStartHostTime = Self.subtractingFrames(
                sourceFrameCount,
                from: observedHostTime,
                sampleRate: buffer.format.sampleRate)
            let probableStartHostTime =
                deviceStartHostTime ?? estimatedStartHostTime
            let probableEndHostTime = deviceStartHostTime.map {
                Self.addingFrames(
                    sourceFrameCount,
                    to: $0,
                    sampleRate: buffer.format.sampleRate)
            } ?? observedHostTime
            guard let bytesPerFrame = Self.bytesPerFrame(buffer),
                bytesPerFrame > 0
            else {
                return .copyFailed(
                    LostFrames(
                        frameCount: sourceFrameCount,
                        startHostTime: probableStartHostTime,
                        endHostTime: probableEndHostTime,
                        stage: .retentionCopy))
            }

            if let startHostTime = deviceStartHostTime {
                guard
                    let copied = copyFrame(
                        buffer,
                        0..<sourceFrameCount,
                        .retention)
                else {
                    return .copyFailed(
                        LostFrames(
                            frameCount: sourceFrameCount,
                            startHostTime: startHostTime,
                            endHostTime: probableEndHostTime,
                            stage: .retentionCopy))
                }
                return .frame(
                    PreparedFrame(
                        buffer: copied,
                        startHostTime: startHostTime,
                        bytesPerFrame: bytesPerFrame,
                        timestampOrigin: .audioDevice,
                        invalidTimestampDroppedFrameCount: 0,
                        precedingLoss: nil))
            }

            switch invalidTimestampPolicy {
            case .discard:
                return .invalidTimestampDiscarded(
                    LostFrames(
                        frameCount: sourceFrameCount,
                        startHostTime: estimatedStartHostTime,
                        endHostTime: observedHostTime,
                        stage: .timestampCoverage))
            case .estimateFromObservation(let maximumFrameCount):
                let retainedFrameCount = min(sourceFrameCount, maximumFrameCount)
                let retainedStart = sourceFrameCount - retainedFrameCount
                let duration = AVAudioTime.hostTime(
                    forSeconds: Double(retainedFrameCount)
                        / buffer.format.sampleRate)
                let startHostTime = observedHostTime >= duration
                    ? observedHostTime - duration
                    : 0
                guard
                    let copied = copyFrame(
                        buffer,
                        retainedStart..<sourceFrameCount,
                        .retention)
                else {
                    return .copyFailed(
                        LostFrames(
                            frameCount: sourceFrameCount,
                            startHostTime: estimatedStartHostTime,
                            endHostTime: observedHostTime,
                            stage: .retentionCopy))
                }
                let droppedFrameCount = sourceFrameCount - retainedFrameCount
                let precedingLoss = droppedFrameCount > 0
                    ? LostFrames(
                        frameCount: droppedFrameCount,
                        startHostTime: estimatedStartHostTime,
                        endHostTime: startHostTime,
                        stage: .timestampCoverage)
                    : nil
                return .frame(
                    PreparedFrame(
                        buffer: copied,
                        startHostTime: startHostTime,
                        bytesPerFrame: bytesPerFrame,
                        timestampOrigin: .estimatedFromObservation,
                        invalidTimestampDroppedFrameCount: droppedFrameCount,
                        precedingLoss: precedingLoss))
            }
        }

        private func record(
            _ loss: LostFrames,
            on active: ActiveRoute?
        ) {
            if let endHostTime = loss.endHostTime {
                recordPreRollEviction(through: endHostTime)
            }
            guard let active else { return }
            if failedFrameMayBelong(
                startHostTime: loss.startHostTime,
                endHostTime: loss.endHostTime,
                to: active.route)
            {
                active.sink.recordIntegrityFailure(
                    AudioCaptureIntegrityFailure(
                        stage: loss.stage,
                        affectedFrameCount: loss.frameCount))
                resolveReleaseWaiters(on: active, result: false)
            } else {
                observeReleaseCrossing(
                    on: active,
                    candidateEndHostTime: loss.endHostTime)
            }
        }

        private func recordDeviceTimestampDiscontinuity(before frame: PreparedFrame) {
            let frameEndHostTime = Self.addingFrames(
                Int(frame.buffer.frameLength),
                to: frame.startHostTime,
                sampleRate: frame.buffer.format.sampleRate)

            if deviceContinuityIsUnknown {
                let unknownSince = deviceContinuityUnknownSinceHostTime
                if unknownSince.map({ frame.startHostTime > $0 }) ?? true {
                    let affectedFrames: Int
                    if let unknownSince,
                        frame.startHostTime > unknownSince
                    {
                        let missingSeconds = AVAudioTime.seconds(
                            forHostTime: frame.startHostTime - unknownSince)
                        affectedFrames = max(
                            Int(
                                (missingSeconds * frame.buffer.format.sampleRate)
                                    .rounded()),
                            1)
                    } else {
                        affectedFrames = 1
                    }
                    record(
                        LostFrames(
                            frameCount: affectedFrames,
                            startHostTime: unknownSince,
                            endHostTime: frame.startHostTime,
                            stage: .timestampCoverage),
                        on: activeRoute)
                }

                if let unknownSince, frameEndHostTime < unknownSince {
                    return
                }
                deviceContinuityIsUnknown = false
                deviceContinuityUnknownSinceHostTime = nil
                lastDeviceFrameEndHostTime = frameEndHostTime
                return
            }

            guard let previousEnd = lastDeviceFrameEndHostTime else { return }
            defer {
                lastDeviceFrameEndHostTime = max(previousEnd, frameEndHostTime)
            }

            // AVAudioTime host conversion can differ by one sample tick at a
            // callback boundary. Only classify a discontinuity larger than that
            // rounding allowance as uncertain capture.
            let tolerance = AVAudioTime.hostTime(
                forSeconds: 1 / frame.buffer.format.sampleRate)

            if frame.startHostTime < previousEnd {
                let regression = previousEnd - frame.startHostTime
                guard regression > tolerance else { return }
                let affectedSeconds = AVAudioTime.seconds(
                    forHostTime: regression)
                let affectedFrames = max(
                    Int(
                        (affectedSeconds * frame.buffer.format.sampleRate)
                            .rounded()),
                    1)
                record(
                    LostFrames(
                        frameCount: affectedFrames,
                        startHostTime: frame.startHostTime,
                        endHostTime: previousEnd,
                        stage: .timestampCoverage),
                    on: activeRoute)
                return
            }

            guard frame.startHostTime - previousEnd > tolerance else { return }

            let missingSeconds = AVAudioTime.seconds(
                forHostTime: frame.startHostTime - previousEnd)
            let missingFrames = max(
                Int((missingSeconds * frame.buffer.format.sampleRate).rounded()),
                1)
            record(
                LostFrames(
                    frameCount: missingFrames,
                    startHostTime: previousEnd,
                    endHostTime: frame.startHostTime,
                    stage: .timestampCoverage),
                on: activeRoute)
        }

        private func markDeviceContinuityUnknown(after hostTime: UInt64?) {
            if deviceContinuityIsUnknown {
                if let existing = deviceContinuityUnknownSinceHostTime,
                    let hostTime
                {
                    deviceContinuityUnknownSinceHostTime = max(existing, hostTime)
                } else if hostTime == nil {
                    deviceContinuityUnknownSinceHostTime = nil
                }
            } else {
                deviceContinuityIsUnknown = true
                deviceContinuityUnknownSinceHostTime = hostTime
            }
            lastDeviceFrameEndHostTime = nil
        }

        private func appendToPreRoll(_ frame: StoredFrame) {
            preRoll.append(frame)
            bufferedFrameCount += frame.frameCount
            bufferedByteCount += frame.byteCount
            trimPreRoll()
        }

        private func trimPreRoll() {
            while let oldest = preRoll.first {
                var framesToDrop = max(
                    bufferedFrameCount - limits.maxFrameCount,
                    0)

                let excessBytes = max(
                    bufferedByteCount - limits.maxByteCount,
                    0)
                if excessBytes > 0 {
                    let byteLimitedDrop =
                        (excessBytes + oldest.bytesPerFrame - 1)
                        / oldest.bytesPerFrame
                    framesToDrop = max(framesToDrop, byteLimitedDrop)
                }

                if let newest = preRoll.last {
                    let durationTicks = AVAudioTime.hostTime(
                        forSeconds: limits.maxDuration)
                    let cutoff = newest.endHostTime > durationTicks
                        ? newest.endHostTime - durationTicks
                        : 0
                    let durationLimitedDrop =
                        AudioCaptureReleaseFence.preReleaseFrameCount(
                            bufferStartHostTime: oldest.startHostTime,
                            releaseHostTime: cutoff,
                            sampleRate: oldest.buffer.format.sampleRate,
                            frameLength: oldest.frameCount)
                    framesToDrop = max(framesToDrop, durationLimitedDrop)
                }

                guard framesToDrop > 0 else { break }
                if framesToDrop >= oldest.frameCount {
                    removeOldestPreRollFrame()
                    continue
                }

                guard let retained = oldest.droppingFirst(framesToDrop) else {
                    removeOldestPreRollFrame()
                    continue
                }
                recordPreRollEviction(through: retained.startHostTime)
                preRoll[0] = retained
                bufferedFrameCount -= framesToDrop
                bufferedByteCount -= framesToDrop * oldest.bytesPerFrame
            }
        }

        private func removeOldestPreRollFrame() {
            let removed = preRoll.removeFirst()
            recordPreRollEviction(through: removed.endHostTime)
            bufferedFrameCount -= removed.frameCount
            bufferedByteCount -= removed.byteCount
        }

        private func recordPreRollEviction(through endHostTime: UInt64) {
            preRollEvictedThroughHostTime = max(
                preRollEvictedThroughHostTime ?? 0,
                endHostTime)
        }

        private func drain(_ route: ActiveRoute) {
            guard !route.isDelivering else { return }
            route.isDelivering = true
            defer {
                route.isDelivering = false
                route.pendingFrames.removeAll(keepingCapacity: false)
                route.pendingIndex = 0
            }

            while activeRoute === route,
                route.pendingIndex < route.pendingFrames.count
            {
                let stored = route.pendingFrames[route.pendingIndex]
                route.pendingIndex += 1
                switch routedFrame(stored, for: route.route) {
                case .outsideRoute:
                    continue
                case .copyFailed(let affectedFrameCount):
                    route.sink.recordIntegrityFailure(
                        AudioCaptureIntegrityFailure(
                            stage: .routeSliceCopy,
                            affectedFrameCount: affectedFrameCount))
                    resolveReleaseWaiters(on: route, result: false)
                case .frame(let routed):
                    route.sink.consume(routed)
                    if route.sink.integrityFailure != nil {
                        resolveReleaseWaiters(on: route, result: false)
                    }
                }
            }
        }

        private enum RoutedFramePreparation {
            case outsideRoute
            case copyFailed(affectedFrameCount: Int)
            case frame(RoutedFrame)
        }

        private func routedFrame(
            _ frame: StoredFrame,
            for route: Route
        ) -> RoutedFramePreparation {
            if frame.timestampOrigin == .estimatedFromObservation {
                // Observation time is not a sample boundary. Retain the whole
                // uncertain callback once it can contain post-press audio;
                // trimming it against an estimated release can lose speech.
                guard frame.endHostTime > route.pressHostTime else {
                    return .outsideRoute
                }
                guard
                    let copied = copyFrame(
                        frame.buffer,
                        0..<frame.frameCount,
                        .routeSlice)
                else {
                    return .copyFailed(
                        affectedFrameCount: frame.frameCount)
                }
                return .frame(
                    RoutedFrame(
                        buffer: copied,
                        startHostTime: frame.startHostTime,
                        sequenceNumber: frame.sequenceNumber,
                        timestampOrigin: frame.timestampOrigin))
            }

            let lowerFrame = AudioCaptureReleaseFence.preReleaseFrameCount(
                bufferStartHostTime: frame.startHostTime,
                releaseHostTime: route.pressHostTime,
                sampleRate: frame.buffer.format.sampleRate,
                frameLength: frame.frameCount)
            let upperFrame: Int
            if let releaseHostTime = route.releaseBoundary.releaseHostTime {
                upperFrame = AudioCaptureReleaseFence.preReleaseFrameCount(
                    bufferStartHostTime: frame.startHostTime,
                    releaseHostTime: releaseHostTime,
                    sampleRate: frame.buffer.format.sampleRate,
                    frameLength: frame.frameCount)
            } else {
                upperFrame = frame.frameCount
            }

            guard lowerFrame < upperFrame else { return .outsideRoute }
            guard
                let copied = copyFrame(
                    frame.buffer,
                    lowerFrame..<upperFrame,
                    .routeSlice)
            else {
                return .copyFailed(
                    affectedFrameCount: upperFrame - lowerFrame)
            }

            let offset = AVAudioTime.hostTime(
                forSeconds: Double(lowerFrame)
                    / frame.buffer.format.sampleRate)
            let (startHostTime, overflow) =
                frame.startHostTime.addingReportingOverflow(offset)
            return .frame(
                RoutedFrame(
                    buffer: copied,
                    startHostTime: overflow ? UInt64.max : startHostTime,
                    sequenceNumber: frame.sequenceNumber,
                    timestampOrigin: frame.timestampOrigin))
        }

        private func observeReleaseCrossing(
            on route: ActiveRoute,
            candidateEndHostTime: UInt64?
        ) {
            guard activeRoute === route, !route.hasObservedRelease,
                let releaseHostTime = route.route.releaseBoundary.releaseHostTime
            else { return }

            let crossed: Bool
            if let candidateEndHostTime {
                crossed = candidateEndHostTime >= releaseHostTime
            } else {
                crossed = preRoll.contains {
                    $0.endHostTime >= releaseHostTime
                }
            }
            guard crossed else { return }
            route.hasObservedRelease = true
            resolveReleaseWaiters(
                on: route,
                result: route.sink.integrityFailure == nil)
        }

        private func failedFrameMayBelong(
            startHostTime: UInt64?,
            endHostTime: UInt64?,
            to route: Route
        ) -> Bool {
            guard let startHostTime, let endHostTime else { return true }
            guard endHostTime > route.pressHostTime else { return false }
            guard let releaseHostTime = route.releaseBoundary.releaseHostTime else {
                return true
            }
            return startHostTime < releaseHostTime
        }

        private func resolveReleaseWaiters(
            on route: ActiveRoute,
            result: Bool
        ) {
            let continuations = Array(route.releaseWaiters.values)
            route.releaseWaiters.removeAll(keepingCapacity: false)
            for continuation in continuations {
                continuation.resume(returning: result)
            }
        }

        private func cancelReleaseWaiter(
            _ waiterID: UUID,
            routeID: UUID
        ) {
            serialized {
                guard let active = activeRoute,
                    active.route.id == routeID,
                    let continuation = active.releaseWaiters.removeValue(
                        forKey: waiterID)
                else { return }
                continuation.resume(returning: false)
            }
        }

        private var retainedDuration: TimeInterval {
            guard let first = preRoll.first, let last = preRoll.last,
                last.endHostTime > first.startHostTime
            else { return 0 }
            return AVAudioTime.seconds(
                forHostTime: last.endHostTime - first.startHostTime)
        }

        private func serialized<T>(_ operation: () throws -> T) rethrows -> T {
            if DispatchQueue.getSpecific(key: routingQueueKey) == routingQueueID {
                return try operation()
            }
            return try routingQueue.sync(execute: operation)
        }

        private static func bytesPerFrame(
            _ buffer: AVAudioPCMBuffer
        ) -> Int? {
            let bytesPerAudioBuffer = Int(
                buffer.format.streamDescription.pointee.mBytesPerFrame)
            let audioBufferCount = UnsafeMutableAudioBufferListPointer(
                buffer.mutableAudioBufferList).count
            guard bytesPerAudioBuffer > 0, audioBufferCount > 0 else {
                return nil
            }
            let (result, overflow) = bytesPerAudioBuffer
                .multipliedReportingOverflow(by: audioBufferCount)
            return overflow ? nil : result
        }

        private static func addingFrames(
            _ frameCount: Int,
            to hostTime: UInt64,
            sampleRate: Double
        ) -> UInt64 {
            guard frameCount > 0, sampleRate > 0 else { return hostTime }
            let offset = AVAudioTime.hostTime(
                forSeconds: Double(frameCount) / sampleRate)
            let (result, overflow) = hostTime.addingReportingOverflow(offset)
            return overflow ? UInt64.max : result
        }

        private static func subtractingFrames(
            _ frameCount: Int,
            from hostTime: UInt64,
            sampleRate: Double
        ) -> UInt64? {
            guard frameCount > 0, sampleRate > 0 else { return nil }
            let offset = AVAudioTime.hostTime(
                forSeconds: Double(frameCount) / sampleRate)
            return hostTime >= offset ? hostTime - offset : 0
        }

        private static func copySlice(
            _ buffer: AVAudioPCMBuffer,
            range: Range<Int>
        ) -> AVAudioPCMBuffer? {
            let sourceFrameCount = Int(buffer.frameLength)
            guard range.lowerBound >= 0,
                range.upperBound <= sourceFrameCount,
                !range.isEmpty,
                let destination = AVAudioPCMBuffer(
                    pcmFormat: buffer.format,
                    frameCapacity: AVAudioFrameCount(range.count))
            else { return nil }

            destination.frameLength = AVAudioFrameCount(range.count)
            let bytesPerAudioBufferFrame = Int(
                buffer.format.streamDescription.pointee.mBytesPerFrame)
            guard bytesPerAudioBufferFrame > 0 else { return nil }

            let sources = UnsafeMutableAudioBufferListPointer(
                buffer.mutableAudioBufferList)
            let destinations = UnsafeMutableAudioBufferListPointer(
                destination.mutableAudioBufferList)
            guard sources.count == destinations.count else { return nil }

            let sourceOffset = range.lowerBound * bytesPerAudioBufferFrame
            let copyByteCount = range.count * bytesPerAudioBufferFrame
            for index in sources.indices {
                let source = sources[index]
                let destinationBuffer = destinations[index]
                guard let sourceData = source.mData,
                    let destinationData = destinationBuffer.mData,
                    sourceOffset + copyByteCount <= Int(source.mDataByteSize)
                else { return nil }
                memcpy(
                    destinationData,
                    sourceData.advanced(by: sourceOffset),
                    copyByteCount)
                destinations[index].mDataByteSize = UInt32(copyByteCount)
            }
            return destination
        }
    }
#endif
