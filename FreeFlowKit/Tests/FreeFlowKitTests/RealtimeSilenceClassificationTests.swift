import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Realtime silence classification")
struct RealtimeSilenceClassificationTests {
    private let samplesPerWindow = 320 // 20 ms at 16 kHz

    @Test("production policy uses 180/10/310 source boundaries behind a 300 second cap")
    func productionPolicyBoundaries() {
        let policy = RealtimeCommitPolicy()
        let bytesPerSecond = 16_000 * MemoryLayout<Int16>.size

        #expect(policy.maximumUniqueBytes == 310 * bytesPerSecond)
        #expect(policy.minimumUniqueBytesBeforeSilence == 180 * bytesPerSecond)
        #expect(policy.trailingSilenceBytesRequired == 10 * bytesPerSecond)
        #expect(
            !policy.shouldCommit(
                uniqueByteCount: 300 * bytesPerSecond + 4_096,
                trailingSilenceByteCount: 0))
        #expect(
            policy.shouldCommit(
                uniqueByteCount: 310 * bytesPerSecond,
                trailingSilenceByteCount: 0))
    }

    @Test("all-silent callback contributes every byte to trailing silence")
    func allSilentCallback() {
        let pcm = rawPCM([Int16](repeating: 0, count: samplesPerWindow * 3))

        #expect(
            AudioLevelAnalyzer.trailingSilenceByteCount(
                pcm16: pcm,
                threshold: 0.005,
                windowSampleCount: samplesPerWindow) == pcm.count)
    }

    @Test("speech in the final window contributes no trailing silence")
    func speechInFinalWindow() {
        let silence = [Int16](repeating: 0, count: samplesPerWindow * 2)
        let speech = alternatingSpeech(sampleCount: samplesPerWindow)
        let pcm = rawPCM(silence + speech)

        #expect(
            AudioLevelAnalyzer.trailingSilenceByteCount(
                pcm16: pcm,
                threshold: 0.005,
                windowSampleCount: samplesPerWindow) == 0)
    }

    @Test("mixed callback counts only complete silent windows after speech")
    func mixedSpeechAndSilenceCallback() {
        let speech = alternatingSpeech(sampleCount: samplesPerWindow)
        let silence = [Int16](repeating: 0, count: samplesPerWindow * 3)
        let pcm = rawPCM(speech + silence)

        #expect(
            AudioLevelAnalyzer.trailingSilenceByteCount(
                pcm16: pcm,
                threshold: 0.005,
                windowSampleCount: samplesPerWindow) == silence.count * 2)
    }

    @Test("partial leading window keeps silence accounting conservative")
    func partialLeadingWindow() {
        let speech = alternatingSpeech(sampleCount: samplesPerWindow / 2)
        let silence = [Int16](repeating: 0, count: samplesPerWindow * 2)
        let pcm = rawPCM(speech + silence)

        #expect(
            AudioLevelAnalyzer.trailingSilenceByteCount(
                pcm16: pcm,
                threshold: 0.005,
                windowSampleCount: samplesPerWindow) == samplesPerWindow * 2 * 2)
    }

    @Test("session accumulates exact trailing silence across mixed callbacks")
    func sessionAccumulatesMixedCallbacks() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 10_000,
                minimumUniqueBytesBeforeSilence: 2_000,
                trailingSilenceBytesRequired: 1_280))

        #expect(
            try await session.appendSucceeded(
                byteCount: 2_000,
                trailingSilenceByteCount: 0) == false)
        #expect(
            try await session.appendSucceeded(
                byteCount: 1_280,
                trailingSilenceByteCount: 640) == false)
        #expect(
            try await session.appendSucceeded(
                byteCount: 640,
                trailingSilenceByteCount: 640) == true)
    }

    @Test("speech inside a mixed callback resets earlier trailing silence")
    func mixedCallbackResetsEarlierSilence() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 10_000,
                minimumUniqueBytesBeforeSilence: 2_000,
                trailingSilenceBytesRequired: 1_280))

        _ = try await session.appendSucceeded(
            byteCount: 2_640,
            trailingSilenceByteCount: 640)
        #expect(
            try await session.appendSucceeded(
                byteCount: 1_280,
                trailingSilenceByteCount: 640) == false)
        #expect(
            try await session.appendSucceeded(
                byteCount: 640,
                trailingSilenceByteCount: 640) == true)
    }

    @Test("silence boundary permits later speech")
    func silenceBoundaryPermitsContinuation() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 8,
                minimumUniqueBytesBeforeSilence: 6,
                trailingSilenceBytesRequired: 2))

        #expect(
            try await session.appendSucceeded(
                byteCount: 6,
                trailingSilenceByteCount: 2))
        let first = try #require(
            try await session.prepareCommit(force: false).commit)
        try await resolve(
            first,
            session: session,
            predecessor: .root)

        #expect(
            try await session.appendSucceeded(
                byteCount: 2,
                trailingSilenceByteCount: 0) == false)
        let second = try #require(
            try await session.prepareCommit(force: true).commit)
        try await resolve(
            second,
            session: session,
            predecessor: .item("fixture-item-0"))
        try await session.sealCapture()

        #expect(first.coverageRange == 0..<6)
        #expect(second.coverageRange == 6..<8)
    }

    @Test("silence wins when silence and hard boundaries coincide")
    func simultaneousSilenceAndHardBoundaryPermitsContinuation() async throws {
        let session = OpenAIRealtimeCommitSession(
            policy: RealtimeCommitPolicy(
                maximumUniqueBytes: 8,
                minimumUniqueBytesBeforeSilence: 6,
                trailingSilenceBytesRequired: 2))

        #expect(
            try await session.appendSucceeded(
                byteCount: 8,
                trailingSilenceByteCount: 2))
        let first = try #require(
            try await session.prepareCommit(force: false).commit)
        try await resolve(
            first,
            session: session,
            predecessor: .root)

        #expect(try await session.maximumAppendByteCount(requested: 2) == 2)
    }

    @Test("meeting fixture room noise does not authorize a conservative pause commit")
    func meetingFixtureDoesNotAuthorizePauseCommit() async throws {
        let url = try #require(
            WAVFixture.audioURL(named: "meeting-10efb8de"))
        let fixture = try WAVFixture(data: Data(contentsOf: url))
        let policy = RealtimeCommitPolicy(
            maxChunkSeconds: 15,
            minSilenceCommitSeconds: 3,
            requiredSilenceSeconds: 0.3)

        let ranges = try await scheduledCommitRanges(
            pcm: fixture.pcm,
            policy: policy,
            callbackByteCount: 4_096)

        #expect(ranges == [0..<382_400])

        let recordedPauseRanges = [
            164_096..<186_496,
            269_696..<285_440,
        ]
        for pause in recordedPauseRanges {
            #expect(
                isSilent20msWindows(
                    in: pause,
                    pcm: fixture.pcm,
                    threshold: 0.005))
            #expect(
                !isSilent20msWindows(
                    in: pause,
                    pcm: fixture.pcm,
                    threshold: OpenAIStreamingProvider.pauseSilenceThreshold))
        }
    }

    private func alternatingSpeech(sampleCount: Int) -> [Int16] {
        (0..<sampleCount).map { $0.isMultiple(of: 2) ? 3_000 : -3_000 }
    }

    private func rawPCM(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func scheduledCommitRanges(
        pcm: Data,
        policy: RealtimeCommitPolicy,
        callbackByteCount: Int
    ) async throws -> [Range<Int>] {
        let session = OpenAIRealtimeCommitSession(
            policy: policy,
            maxUnresolvedItems: 2)
        var ranges: [Range<Int>] = []
        var callbackStart = 0

        while callbackStart < pcm.count {
            let callbackEnd = min(callbackStart + callbackByteCount, pcm.count)
            var offset = callbackStart
            while offset < callbackEnd {
                let appendCount = try await session.maximumAppendByteCount(
                    requested: callbackEnd - offset)
                if appendCount == 0 {
                    try await resolvePreparedCommit(
                        session: session,
                        force: false,
                        ranges: &ranges)
                    continue
                }

                let source = pcm.subdata(in: offset..<(offset + appendCount))
                let trailingSilence =
                    AudioLevelAnalyzer.trailingSilenceByteCount(
                        pcm16: source,
                        threshold: OpenAIStreamingProvider.pauseSilenceThreshold,
                        windowSampleCount: samplesPerWindow)
                let shouldCommit = try await session.appendSucceeded(
                    byteCount: appendCount,
                    trailingSilenceByteCount: trailingSilence)
                offset += appendCount
                if shouldCommit {
                    try await resolvePreparedCommit(
                        session: session,
                        force: false,
                        ranges: &ranges)
                }
            }
            callbackStart = callbackEnd
        }

        try await resolvePreparedCommit(
            session: session,
            force: true,
            ranges: &ranges)
        return ranges
    }

    private func resolvePreparedCommit(
        session: OpenAIRealtimeCommitSession,
        force: Bool,
        ranges: inout [Range<Int>]
    ) async throws {
        let preparation = try await session.prepareCommit(force: force)
        guard case .ready(let commit) = preparation else {
            Issue.record("expected a ready commit, got \(preparation)")
            return
        }
        ranges.append(commit.coverageRange)

        let itemID = "fixture-item-\(commit.sequence)"
        try await session.apply(
            .commitAcknowledged(
                serverEventID: "fixture-ack-\(commit.sequence)",
                itemID: itemID,
                predecessor: commit.sequence == 0
                    ? .root
                    : .item("fixture-item-\(commit.sequence - 1)")))
        try await session.apply(
            .completed(
                serverEventID: "fixture-terminal-\(commit.sequence)",
                itemID: itemID,
                contentIndex: 0,
                transcript: "fixture segment \(commit.sequence)"))
    }

    private func resolve(
        _ commit: RealtimeTranscriptLedger.Commit,
        session: OpenAIRealtimeCommitSession,
        predecessor: RealtimeItemPredecessor
    ) async throws {
        let itemID = "fixture-item-\(commit.sequence)"
        try await session.apply(
            .commitAcknowledged(
                serverEventID: "fixture-ack-\(commit.sequence)",
                itemID: itemID,
                predecessor: predecessor))
        try await session.apply(
            .completed(
                serverEventID: "fixture-terminal-\(commit.sequence)",
                itemID: itemID,
                contentIndex: 0,
                transcript: "fixture segment \(commit.sequence)"))
    }

    private func isSilent20msWindows(
        in range: Range<Int>,
        pcm: Data,
        threshold: Float
    ) -> Bool {
        let byteCount = samplesPerWindow * MemoryLayout<Int16>.size
        return stride(from: range.lowerBound, to: range.upperBound, by: byteCount)
            .allSatisfy { start in
                AudioLevelAnalyzer.rmsLevel(
                    pcm16: pcm.subdata(in: start..<(start + byteCount))) <= threshold
            }
    }
}

private extension OpenAIRealtimeCommitSession.CommitPreparation {
    var commit: RealtimeTranscriptLedger.Commit? {
        guard case .ready(let commit) = self else { return nil }
        return commit
    }
}
