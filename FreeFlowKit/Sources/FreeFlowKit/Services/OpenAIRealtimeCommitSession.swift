import Foundation

/// Serialized source-coverage, commit-admission, and transcript-assembly state
/// for one OpenAI Realtime connection. Network I/O remains at the provider edge.
actor OpenAIRealtimeCommitSession {

    private struct Waiter<Value: Sendable>: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Value, any Error>
    }

    enum CommitPreparation: Equatable, Sendable {
        case ready(RealtimeTranscriptLedger.Commit)
        case noAudio
        case blocked
    }

    enum Failure: Error, Equatable {
        case unalignedAudioByteCount(Int)
        case appendExceedsCommitBoundary(
            available: Int,
            attempted: Int)
        case sourceByteCountOverflow
        case captureAlreadySealed
        case polishAlreadyStarted
        case transcriptNotResolved
        case responseBeforePolish
        case responseAlreadyCompleted
    }

    private let policy: RealtimeCommitPolicy
    private let maxUnresolvedItems: Int
    private var reducer = OpenAIRealtimeTranscriptReducer()
    private var audioResampler = AudioResampler.Stream16kTo24k()

    private var sourceEnd = 0
    private var committedEnd = 0
    private var trailingSilenceBytes = 0
    private var preparedCommitCount = 0
    private var pendingAcknowledgementSequence: Int?
    private var acknowledgedSequences: Set<Int> = []
    private var terminalItemIDs: Set<String> = []
    private var isCaptureSealed = false

    private var storedFailure: (any Error)?
    private var acknowledgementWaiters:
        [Int: [Waiter<Void>]] = [:]
    private var capacityWaiters: [Waiter<Void>] = []
    private var rawTranscriptWaiters:
        [Waiter<String>] = []
    private var transportTurnHeld = false
    private var transportWaiters:
        [Waiter<Void>] = []
    private var resolvedRawTranscript: String?
    private var resolvedTranscriptSegments: [String]?
    private var polishStarted = false
    private var responseText = ""
    private var completedResponseText: String?
    private var resolvedPolishedResponse: String?
    private var responseWaiters:
        [Waiter<String>] = []

    init(
        policy: RealtimeCommitPolicy = RealtimeCommitPolicy(),
        maxUnresolvedItems: Int = 2
    ) {
        precondition(maxUnresolvedItems > 0)
        self.policy = policy
        self.maxUnresolvedItems = maxUnresolvedItems
    }

    func acquireTransportTurn() async throws {
        try Task.checkCancellation()
        try requireSessionSuccess()
        if !transportTurnHeld {
            transportTurnHeld = true
            if Task.isCancelled {
                releaseTransportTurn()
                throw CancellationError()
            }
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let storedFailure {
                    continuation.resume(throwing: storedFailure)
                } else {
                    transportWaiters.append(
                        Waiter(
                            id: waiterID,
                            continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelTransportWaiter(id: waiterID) }
        }
        if Task.isCancelled {
            releaseTransportTurn()
            throw CancellationError()
        }
        do {
            try requireSessionSuccess()
        } catch {
            releaseTransportTurn()
            throw error
        }
    }

    func releaseTransportTurn() {
        guard transportTurnHeld else { return }
        guard storedFailure == nil else {
            transportTurnHeld = false
            return
        }
        if transportWaiters.isEmpty {
            transportTurnHeld = false
        } else {
            transportWaiters.removeFirst().continuation.resume()
        }
    }

    func maximumAppendByteCount(requested: Int) throws -> Int {
        try requireActiveCapture()
        try requireAligned(requested)
        guard requested > 0 else { return 0 }
        let available = policy.maximumUniqueBytes - (sourceEnd - committedEnd)
        return min(
            requested,
            max(0, available),
            RealtimeCommitPolicy.maximumAppendSourceBytes)
    }

    func resampleForAppend(_ pcm16k: Data) throws -> Data {
        try requireActiveCapture()
        try requireAligned(pcm16k.count)
        return audioResampler.append(pcm16k)
    }

    func finishResamplingForCommit() throws -> Data {
        try requireSessionSuccess()
        return audioResampler.finish()
    }

    @discardableResult
    func appendSucceeded(
        byteCount: Int,
        containsSpeech: Bool
    ) throws -> Bool {
        try requireActiveCapture()
        try requireAligned(byteCount)
        guard byteCount > 0 else { return false }

        let available = policy.maximumUniqueBytes - (sourceEnd - committedEnd)
        guard byteCount <= available else {
            throw Failure.appendExceedsCommitBoundary(
                available: available,
                attempted: byteCount)
        }
        let (newSourceEnd, overflow) = sourceEnd.addingReportingOverflow(byteCount)
        guard !overflow else { throw Failure.sourceByteCountOverflow }
        sourceEnd = newSourceEnd
        if containsSpeech {
            trailingSilenceBytes = 0
        } else {
            let (newSilenceBytes, silenceOverflow) =
                trailingSilenceBytes.addingReportingOverflow(byteCount)
            guard !silenceOverflow else { throw Failure.sourceByteCountOverflow }
            trailingSilenceBytes = newSilenceBytes
        }
        return boundaryIsDue
    }

    func prepareCommit(force: Bool) throws -> CommitPreparation {
        try requireActiveCapture()
        guard sourceEnd > committedEnd else { return .noAudio }
        guard force || boundaryIsDue else { return .noAudio }
        guard canPrepareCommit else { return .blocked }

        let coverageRange = committedEnd..<sourceEnd
        let commit = try reducer.recordCommit(
            coverageRange: coverageRange,
            submittedRange: coverageRange)
        committedEnd = sourceEnd
        trailingSilenceBytes = 0
        preparedCommitCount += 1
        pendingAcknowledgementSequence = commit.sequence
        return .ready(commit)
    }

    @discardableResult
    func apply(
        _ event: OpenAIRealtimeTranscriptionEvent
    ) throws -> OpenAIRealtimeTranscriptReducer.Application {
        try requireSessionSuccess()
        do {
            let application = try reducer.apply(event)
            switch application {
            case .acknowledged(let commit):
                acknowledge(commit.sequence)
            case .terminal(let itemID):
                if terminalItemIDs.insert(itemID).inserted {
                    resumeCapacityWaitersIfPossible()
                }
            case .replay:
                break
            }

            if case .failed(_, let itemID, _, let error) = event {
                let failure = RealtimeTranscriptLedger.Failure.transcriptionFailed(
                    itemID: itemID,
                    message: error.ledgerMessage)
                invalidate(with: failure)
                throw failure
            }
            try resolveTranscriptIfPossible()
            return application
        } catch {
            invalidate(with: error)
            throw error
        }
    }

    func waitForAcknowledgement(sequence: Int) async throws {
        try Task.checkCancellation()
        try requireSessionSuccess()
        if acknowledgedSequences.contains(sequence) { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let storedFailure {
                    continuation.resume(throwing: storedFailure)
                } else if acknowledgedSequences.contains(sequence) {
                    continuation.resume()
                } else {
                    acknowledgementWaiters[sequence, default: []].append(
                        Waiter(
                            id: waiterID,
                            continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelAcknowledgementWaiter(
                    sequence: sequence,
                    id: waiterID)
            }
        }
        try Task.checkCancellation()
        try requireSessionSuccess()
    }

    func waitForCommitCapacity() async throws {
        try Task.checkCancellation()
        try requireSessionSuccess()
        if canPrepareCommit { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let storedFailure {
                    continuation.resume(throwing: storedFailure)
                } else if canPrepareCommit {
                    continuation.resume()
                } else {
                    capacityWaiters.append(
                        Waiter(
                            id: waiterID,
                            continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelCapacityWaiter(id: waiterID) }
        }
        try Task.checkCancellation()
        try requireSessionSuccess()
    }

    func sealCapture() throws {
        try requireSessionSuccess()
        guard !isCaptureSealed else { throw Failure.captureAlreadySealed }
        try reducer.seal(expectedCoverageEnd: sourceEnd)
        isCaptureSealed = true
        try resolveTranscriptIfPossible()
    }

    func waitForRawTranscript() async throws -> String {
        try Task.checkCancellation()
        try requireSessionSuccess()
        if let resolvedRawTranscript { return resolvedRawTranscript }
        let waiterID = UUID()
        let result: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let storedFailure {
                    continuation.resume(throwing: storedFailure)
                } else if let resolvedRawTranscript {
                    continuation.resume(returning: resolvedRawTranscript)
                } else {
                    rawTranscriptWaiters.append(
                        Waiter(
                            id: waiterID,
                            continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelRawTranscriptWaiter(id: waiterID) }
        }
        try Task.checkCancellation()
        try requireSessionSuccess()
        return result
    }

    func resolvedSegments() throws -> [String] {
        try requireSessionSuccess()
        if let resolvedTranscriptSegments { return resolvedTranscriptSegments }
        return try reducer.resolvedItems().map(\.transcript)
    }

    func beginPolish() throws {
        try requireSessionSuccess()
        guard resolvedRawTranscript != nil else {
            throw Failure.transcriptNotResolved
        }
        guard !polishStarted else { throw Failure.polishAlreadyStarted }
        polishStarted = true
    }

    @discardableResult
    func appendResponseDelta(_ delta: String) throws -> Bool {
        try requirePolishInProgress()
        let isFirst = responseText.isEmpty
        responseText += delta
        return isFirst && !delta.isEmpty
    }

    func completeResponseText(_ text: String) throws {
        try requirePolishInProgress()
        completedResponseText = text
    }

    func completeResponse() throws {
        try requirePolishInProgress()
        guard resolvedPolishedResponse == nil else {
            throw Failure.responseAlreadyCompleted
        }
        let result = completedResponseText ?? responseText
        resolvedPolishedResponse = result
        let waiters = responseWaiters
        responseWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: result)
        }
    }

    func waitForPolishedResponse() async throws -> String {
        try Task.checkCancellation()
        try requireSessionSuccess()
        if let resolvedPolishedResponse { return resolvedPolishedResponse }
        let waiterID = UUID()
        let result: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let storedFailure {
                    continuation.resume(throwing: storedFailure)
                } else if let resolvedPolishedResponse {
                    continuation.resume(returning: resolvedPolishedResponse)
                } else {
                    responseWaiters.append(
                        Waiter(
                            id: waiterID,
                            continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelResponseWaiter(id: waiterID) }
        }
        try Task.checkCancellation()
        try requireSessionSuccess()
        return result
    }

    func fail(_ error: any Error) {
        invalidate(with: error)
    }

    private var boundaryIsDue: Bool {
        policy.shouldCommit(
            uniqueByteCount: sourceEnd - committedEnd,
            trailingSilenceByteCount: trailingSilenceBytes)
    }

    private var unresolvedItemCount: Int {
        preparedCommitCount - terminalItemIDs.count
    }

    private var canPrepareCommit: Bool {
        pendingAcknowledgementSequence == nil
            && unresolvedItemCount < maxUnresolvedItems
    }

    private func acknowledge(_ sequence: Int) {
        acknowledgedSequences.insert(sequence)
        if pendingAcknowledgementSequence == sequence {
            pendingAcknowledgementSequence = nil
        }
        let waiters = acknowledgementWaiters.removeValue(forKey: sequence) ?? []
        for waiter in waiters { waiter.continuation.resume() }
        resumeCapacityWaitersIfPossible()
    }

    private func resumeCapacityWaitersIfPossible() {
        guard canPrepareCommit else { return }
        let waiters = capacityWaiters
        capacityWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume() }
    }

    private func resolveTranscriptIfPossible() throws {
        guard isCaptureSealed, resolvedRawTranscript == nil else { return }
        do {
            let segments = try reducer.resolvedItems().map(\.transcript)
            let raw = segments.allSatisfy(\.isEmpty)
                ? ""
                : segments.joined(separator: " ")
            resolvedTranscriptSegments = segments
            resolvedRawTranscript = raw
            let waiters = rawTranscriptWaiters
            rawTranscriptWaiters.removeAll()
            for waiter in waiters {
                waiter.continuation.resume(returning: raw)
            }
        } catch RealtimeTranscriptLedger.Failure.incomplete {
            return
        } catch RealtimeTranscriptLedger.Failure.notSealed {
            return
        } catch {
            invalidate(with: error)
            throw error
        }
    }

    private func requireActiveCapture() throws {
        try requireSessionSuccess()
        guard !isCaptureSealed else { throw Failure.captureAlreadySealed }
    }

    private func requireSessionSuccess() throws {
        if let storedFailure { throw storedFailure }
    }

    private func requirePolishInProgress() throws {
        try requireSessionSuccess()
        guard polishStarted else { throw Failure.responseBeforePolish }
        guard resolvedPolishedResponse == nil else {
            throw Failure.responseAlreadyCompleted
        }
    }

    private func requireAligned(_ byteCount: Int) throws {
        guard byteCount >= 0, byteCount.isMultiple(of: MemoryLayout<Int16>.size)
        else {
            throw Failure.unalignedAudioByteCount(byteCount)
        }
    }

    private func cancelAcknowledgementWaiter(sequence: Int, id: UUID) {
        guard var waiters = acknowledgementWaiters[sequence],
            let index = waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            acknowledgementWaiters.removeValue(forKey: sequence)
        } else {
            acknowledgementWaiters[sequence] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelCapacityWaiter(id: UUID) {
        guard let index = capacityWaiters.firstIndex(where: { $0.id == id })
        else { return }
        capacityWaiters.remove(at: index).continuation.resume(
            throwing: CancellationError())
    }

    private func cancelRawTranscriptWaiter(id: UUID) {
        guard let index = rawTranscriptWaiters.firstIndex(where: { $0.id == id })
        else { return }
        rawTranscriptWaiters.remove(at: index).continuation.resume(
            throwing: CancellationError())
    }

    private func cancelTransportWaiter(id: UUID) {
        guard let index = transportWaiters.firstIndex(where: { $0.id == id })
        else { return }
        transportWaiters.remove(at: index).continuation.resume(
            throwing: CancellationError())
    }

    private func cancelResponseWaiter(id: UUID) {
        guard let index = responseWaiters.firstIndex(where: { $0.id == id })
        else { return }
        responseWaiters.remove(at: index).continuation.resume(
            throwing: CancellationError())
    }

    private func invalidate(with error: any Error) {
        guard storedFailure == nil else { return }
        storedFailure = error

        let acknowledgementWaiters = self.acknowledgementWaiters
        self.acknowledgementWaiters.removeAll()
        for waiters in acknowledgementWaiters.values {
            for waiter in waiters {
                waiter.continuation.resume(throwing: error)
            }
        }

        let capacityWaiters = self.capacityWaiters
        self.capacityWaiters.removeAll()
        for waiter in capacityWaiters {
            waiter.continuation.resume(throwing: error)
        }

        let transcriptWaiters = rawTranscriptWaiters
        rawTranscriptWaiters.removeAll()
        for waiter in transcriptWaiters {
            waiter.continuation.resume(throwing: error)
        }

        let transportWaiters = self.transportWaiters
        self.transportWaiters.removeAll()
        for waiter in transportWaiters {
            waiter.continuation.resume(throwing: error)
        }

        let responseWaiters = self.responseWaiters
        self.responseWaiters.removeAll()
        for waiter in responseWaiters {
            waiter.continuation.resume(throwing: error)
        }
    }
}
