import CryptoKit
import Foundation
import Testing

@testable import FreeFlowKit

@Suite(
    "Cloud dictation live verification harness",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI"] != "1"
            || ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI_LONG"] != "1"))
struct CloudDictationLiveHarnessTests {

    @Test("real speech remains faithful when conservative pause detection defers commits")
    func conservativePauseClassification() async throws {
        let environment = ProcessInfo.processInfo.environment
        let apiKey = try #require(environment["OPENAI_API_KEY"])
        #expect(!apiKey.isEmpty)

        let fixtureURL = try #require(
            WAVFixture.audioURL(named: "meeting-10efb8de"))
        let fixture = try WAVFixture(data: Data(contentsOf: fixtureURL))
        #expect(fixture.sampleRate == 16_000)
        #expect(fixture.channels == 1)
        #expect(fixture.bitsPerSample == 16)

        let scenario = try #require(
            allScenarios.first {
                $0.category == "meeting"
                    && $0.input.hasPrefix("the key takeaways")
            })
        let policy = RealtimeCommitPolicy(
            maxChunkSeconds: 15,
            minSilenceCommitSeconds: 3,
            requiredSilenceSeconds: 0.3)
        let realtimeModel = OpenAIStreamingProvider.defaultRealtimeModel
        let sttModel = "gpt-4o-mini-transcribe"
        let recorder = CloudEvidenceRecorder()
        let provider = OpenAIStreamingProvider(
            apiKeyProvider: { apiKey },
            realtimeModel: realtimeModel,
            sttModel: sttModel,
            commitPolicy: policy,
            maxUnresolvedItems: 2,
            evidenceObserver: { await recorder.record($0) })

        let startedAt = Date()
        do {
            try await provider.startStreaming(
                context: scenario.context,
                language: "en",
                micProximity: .nearField)
            let startCallSeconds = Date().timeIntervalSince(startedAt)

            for chunk in fixture.pcm.chunks(maximumByteCount: 4_096) {
                try await provider.sendAudio(chunk)
            }
            let audioSentAt = Date()
            let setupAndAudioSendSeconds =
                audioSentAt.timeIntervalSince(startedAt) - startCallSeconds

            let polished = try await provider.finishStreaming()
            let finishedAt = Date()
            let snapshots = await recorder.snapshots()
            await provider.disconnect()

            let snapshot = try #require(snapshots.only)
            let rawTranscript = snapshot.items.allSatisfy(\.transcript.isEmpty)
                ? ""
                : snapshot.items.map(\.transcript).joined(separator: " ")

            #expect(snapshots.count == 1)
            #expect(snapshot.sourceByteCount == fixture.pcm.count)
            #expect(snapshot.items.count == 1)
            #expect(snapshot.items.allSatisfy { !$0.transcript.isEmpty })
            #expect(
                snapshot.items.map(\.coverageLowerBound)
                    == [0])
            #expect(
                snapshot.items.map(\.coverageUpperBound)
                    == [fixture.pcm.count])
            #expect(
                snapshot.items.map(\.submittedLowerBound)
                    == snapshot.items.map(\.coverageLowerBound))
            #expect(
                snapshot.items.map(\.submittedUpperBound)
                    == snapshot.items.map(\.coverageUpperBound))
            #expect(snapshot.items.first?.previousItemID == nil)

            requireFidelityFragments(in: rawTranscript)
            requireFidelityFragments(in: polished)
            let acceptedMatch = scenario.matches(polished)
            #expect(acceptedMatch)

            let evidence = CloudLiveEvidence(
                caseID: "conservative-pause-classification",
                sourceDescription: fixtureURL.lastPathComponent,
                sourceByteCount: fixture.pcm.count,
                sourceSHA256: sha256(parts: [fixture.pcm]),
                sourceDurationSeconds: fixture.duration,
                realTimePaced: false,
                realtimeModel: realtimeModel,
                sttModel: sttModel,
                policyMaximumUniqueBytes: policy.maximumUniqueBytes,
                policyMinimumUniqueBytesBeforeSilence:
                    policy.minimumUniqueBytesBeforeSilence,
                policyTrailingSilenceBytesRequired:
                    policy.trailingSilenceBytesRequired,
                startCallSeconds: startCallSeconds,
                setupAndAudioSendSeconds: setupAndAudioSendSeconds,
                finishSeconds: finishedAt.timeIntervalSince(audioSentAt),
                totalSeconds: finishedAt.timeIntervalSince(startedAt),
                snapshot: snapshot,
                rawTranscript: rawTranscript,
                polishedOutput: polished,
                polishedMatchesAccepted: acceptedMatch)
            try emit(
                evidence,
                outputDirectory: environment["FREEFLOW_TEST_EVIDENCE_DIR"])
        } catch {
            await provider.disconnect()
            throw error
        }
    }

    @Test("production policy commits an accelerated five-minute source on silence")
    func acceleratedProductionPolicyDuration() async throws {
        let environment = ProcessInfo.processInfo.environment
        let apiKey = try #require(environment["OPENAI_API_KEY"])
        #expect(!apiKey.isEmpty)

        let meetingURL = try #require(
            WAVFixture.audioURL(named: "meeting-10efb8de"))
        let emailURL = try #require(
            WAVFixture.audioURL(named: "email-e04c6897"))
        let meeting = try WAVFixture(data: Data(contentsOf: meetingURL))
        let email = try WAVFixture(data: Data(contentsOf: emailURL))
        for fixture in [meeting, email] {
            #expect(fixture.sampleRate == 16_000)
            #expect(fixture.channels == 1)
            #expect(fixture.bitsPerSample == 16)
        }

        let policy = RealtimeCommitPolicy()
        let sourceByteCount = 300 * RealtimeCommitPolicy.sourceBytesPerSecond
        let firstCommitEnd = policy.minimumUniqueBytesBeforeSilence
        let firstSilence = Data(
            repeating: 0,
            count: firstCommitEnd - meeting.pcm.count)
        let secondSilence = Data(
            repeating: 0,
            count: sourceByteCount - firstCommitEnd - email.pcm.count)
        #expect(sourceByteCount == 9_600_000)
        #expect(firstCommitEnd == 5_760_000)
        #expect(
            meeting.pcm.count + firstSilence.count + secondSilence.count
                + email.pcm.count == sourceByteCount)
        let sourceParts = [
            meeting.pcm, firstSilence, secondSilence, email.pcm,
        ]
        let realTimePaced =
            environment["FREEFLOW_TEST_OPENAI_REALTIME_PACED"] == "1"

        let realtimeModel = OpenAIStreamingProvider.defaultRealtimeModel
        let sttModel = "gpt-4o-mini-transcribe"
        let recorder = CloudEvidenceRecorder()
        let provider = OpenAIStreamingProvider(
            apiKeyProvider: { apiKey },
            realtimeModel: realtimeModel,
            sttModel: sttModel,
            commitPolicy: policy,
            maxUnresolvedItems: 2,
            evidenceObserver: { await recorder.record($0) })

        let startedAt = Date()
        do {
            try await provider.startStreaming(
                context: .empty,
                language: "en",
                micProximity: .nearField)
            let startCallSeconds = Date().timeIntervalSince(startedAt)

            if realTimePaced {
                for part in sourceParts {
                    for chunk in part.chunks(maximumByteCount: 4_096) {
                        try await provider.sendAudio(chunk)
                        try await Task.sleep(
                            for: .seconds(
                                Double(chunk.count)
                                    / Double(RealtimeCommitPolicy.sourceBytesPerSecond)))
                    }
                }
            } else {
                for part in sourceParts {
                    try await provider.sendAudio(part)
                }
            }
            let audioSentAt = Date()
            let setupAndAudioSendSeconds =
                audioSentAt.timeIntervalSince(startedAt) - startCallSeconds

            let polished = try await provider.finishStreaming()
            let finishedAt = Date()
            let snapshots = await recorder.snapshots()
            await provider.disconnect()

            let snapshot = try #require(snapshots.only)
            let rawTranscript = snapshot.items.map(\.transcript)
                .joined(separator: " ")
            #expect(snapshots.count == 1)
            #expect(snapshot.sourceByteCount == sourceByteCount)
            #expect(snapshot.items.count == 2)
            #expect(
                snapshot.items.map(\.coverageLowerBound)
                    == [0, firstCommitEnd])
            #expect(
                snapshot.items.map(\.coverageUpperBound)
                    == [firstCommitEnd, sourceByteCount])
            #expect(
                snapshot.items.map(\.submittedLowerBound)
                    == snapshot.items.map(\.coverageLowerBound))
            #expect(
                snapshot.items.map(\.submittedUpperBound)
                    == snapshot.items.map(\.coverageUpperBound))
            #expect(snapshot.items.first?.previousItemID == nil)
            #expect(snapshot.items[1].previousItemID == snapshot.items[0].itemID)

            requireFidelityFragments(in: snapshot.items[0].transcript)
            requireEmailFragments(in: snapshot.items[1].transcript)
            requireFidelityFragments(in: rawTranscript)
            requireEmailFragments(in: rawTranscript)
            #expect(!polished.isEmpty)
            requireFidelityFragments(in: polished)
            requireEmailFragments(in: polished)

            let evidence = CloudLiveEvidence(
                caseID: realTimePaced
                    ? "production-policy-300s-paced"
                    : "production-policy-300s-accelerated",
                sourceDescription:
                    "\(meetingURL.lastPathComponent)+silence+"
                    + emailURL.lastPathComponent,
                sourceByteCount: sourceByteCount,
                sourceSHA256: sha256(parts: sourceParts),
                sourceDurationSeconds: 300,
                realTimePaced: realTimePaced,
                realtimeModel: realtimeModel,
                sttModel: sttModel,
                policyMaximumUniqueBytes: policy.maximumUniqueBytes,
                policyMinimumUniqueBytesBeforeSilence:
                    policy.minimumUniqueBytesBeforeSilence,
                policyTrailingSilenceBytesRequired:
                    policy.trailingSilenceBytesRequired,
                startCallSeconds: startCallSeconds,
                setupAndAudioSendSeconds: setupAndAudioSendSeconds,
                finishSeconds: finishedAt.timeIntervalSince(audioSentAt),
                totalSeconds: finishedAt.timeIntervalSince(startedAt),
                snapshot: snapshot,
                rawTranscript: rawTranscript,
                polishedOutput: polished,
                polishedMatchesAccepted: nil)
            try emit(
                evidence,
                outputDirectory: environment["FREEFLOW_TEST_EVIDENCE_DIR"])
        } catch {
            await provider.disconnect()
            throw error
        }
    }

    @Test("batch recovery endpoint accepts the exact canonical WAV")
    func liveBatchRecoveryEndpoint() async throws {
        let environment = ProcessInfo.processInfo.environment
        let apiKey = try #require(environment["OPENAI_API_KEY"])
        #expect(!apiKey.isEmpty)

        let fixtureURL = try #require(
            WAVFixture.audioURL(named: "meeting-10efb8de"))
        let fixture = try WAVFixture(data: Data(contentsOf: fixtureURL))
        let canonicalWAV = fixture.canonicalWAV
        let scenario = try #require(
            allScenarios.first {
                $0.category == "meeting"
                    && $0.input.hasPrefix("the key takeaways")
            })
        let provider = OpenAIFileTranscriber(
            apiKey: apiKey,
            language: "en")

        let startedAt = Date()
        let output = try await provider.dictate(
            audio: canonicalWAV,
            context: .empty)
        let finishedAt = Date()

        #expect(!output.isEmpty)
        requireFidelityFragments(in: output)
        let acceptedMatch = scenario.matches(output)

        let evidence = BatchLiveEvidence(
            caseID: "exact-wav-batch-recovery",
            sourceDescription: fixtureURL.lastPathComponent,
            sourceByteCount: canonicalWAV.count,
            sourceSHA256: sha256(parts: [canonicalWAV]),
            sourceDurationSeconds: fixture.duration,
            transcriptionModel: "gpt-4o-mini-transcribe",
            polishedByModel: false,
            totalSeconds: finishedAt.timeIntervalSince(startedAt),
            output: output,
            outputMatchesAccepted: acceptedMatch)
        try emit(
            evidence,
            outputDirectory: environment["FREEFLOW_TEST_EVIDENCE_DIR"])
    }

    private func requireFidelityFragments(in text: String) {
        requireOrderedFragments(
            [
                "key", "takeaway", "hire", "engineer", "deadline", "april",
                "follow", "next", "week",
            ],
            in: text)
        let normalized = normalizedWords(text)
        #expect(
            normalized.contains("need to hire two more engineers")
                || normalized.contains("need to hire 2 more engineers"))
        #expect(
            normalized.contains("deadline is moved to april 15")
                || normalized.contains("deadline is moved to april fifteenth"))
        #expect(normalized.contains("should schedule a follow up for next week"))
        #expect(!normalized.contains("do not hire"))
        #expect(!normalized.contains("don t hire"))
        #expect(!normalized.contains("need not hire"))
    }

    private func requireEmailFragments(in text: String) {
        requireOrderedFragments(
            ["circling", "back", "track", "launch", "next", "thursday"],
            in: text)
        let normalized = normalizedWords(text)
        #expect(normalized.contains("just circling back on this"))
        #expect(
            normalized.contains(
                "are we still on track for the launch next thursday"))
    }

    private func requireOrderedFragments(_ fragments: [String], in text: String) {
        let normalized = text.lowercased()
        var cursor = normalized.startIndex
        for fragment in fragments {
            guard let range = normalized.range(
                of: fragment,
                range: cursor..<normalized.endIndex)
            else {
                Issue.record("Missing ordered fidelity fragment '\(fragment)' in: \(text)")
                return
            }
            cursor = range.upperBound
        }
    }

    private func normalizedWords(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func sha256(parts: [Data]) -> String {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func emit(
        _ evidence: CloudLiveEvidence,
        outputDirectory: String?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(evidence)
        let line = try #require(String(data: json, encoding: .utf8))
        print("STEP10E_CLOUD_DICTATION_EVIDENCE \(line)")

        if let outputDirectory, !outputDirectory.isEmpty {
            let directory = URL(fileURLWithPath: outputDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(evidence.caseID).json")
            try json.write(to: url, options: .atomic)
        }
    }

    private func emit(
        _ evidence: BatchLiveEvidence,
        outputDirectory: String?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(evidence)
        let line = try #require(String(data: json, encoding: .utf8))
        print("STEP10E_BATCH_RECOVERY_EVIDENCE \(line)")

        if let outputDirectory, !outputDirectory.isEmpty {
            let directory = URL(fileURLWithPath: outputDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(evidence.caseID).json")
            try json.write(to: url, options: .atomic)
        }
    }
}

private struct CloudLiveEvidence: Codable {
    let caseID: String
    let sourceDescription: String
    let sourceByteCount: Int
    let sourceSHA256: String
    let sourceDurationSeconds: TimeInterval
    let realTimePaced: Bool
    let realtimeModel: String
    let sttModel: String
    let policyMaximumUniqueBytes: Int
    let policyMinimumUniqueBytesBeforeSilence: Int
    let policyTrailingSilenceBytesRequired: Int
    let startCallSeconds: TimeInterval
    let setupAndAudioSendSeconds: TimeInterval
    let finishSeconds: TimeInterval
    let totalSeconds: TimeInterval
    let snapshot: OpenAIRealtimeCommitSession.EvidenceSnapshot
    let rawTranscript: String
    let polishedOutput: String
    let polishedMatchesAccepted: Bool?
}

private struct BatchLiveEvidence: Codable {
    let caseID: String
    let sourceDescription: String
    let sourceByteCount: Int
    let sourceSHA256: String
    let sourceDurationSeconds: TimeInterval
    let transcriptionModel: String
    let polishedByModel: Bool
    let totalSeconds: TimeInterval
    let output: String
    let outputMatchesAccepted: Bool
}

private actor CloudEvidenceRecorder {
    private var values: [OpenAIRealtimeCommitSession.EvidenceSnapshot] = []

    func record(_ value: OpenAIRealtimeCommitSession.EvidenceSnapshot) {
        values.append(value)
    }

    func snapshots() -> [OpenAIRealtimeCommitSession.EvidenceSnapshot] {
        values
    }
}

private extension Data {
    func chunks(maximumByteCount: Int) -> [Data] {
        precondition(maximumByteCount > 0)
        var result: [Data] = []
        result.reserveCapacity((count + maximumByteCount - 1) / maximumByteCount)
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + maximumByteCount, count)
            result.append(subdata(in: offset..<end))
            offset = end
        }
        return result
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
