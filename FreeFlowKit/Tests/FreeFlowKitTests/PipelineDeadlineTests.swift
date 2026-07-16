import Foundation
import Testing

@testable import FreeFlowKit

private final class GrowingFinishWatchdogProvider:
    StreamingDictationProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private var activeSessionID: DictationSessionID?

    var finishStreamingWatchdog: TimeInterval = 20
    let maximumFinishStreamingWatchdog: TimeInterval = 175

    func startStreaming(
        sessionID: DictationSessionID,
        context _: AppContext,
        language _: String?,
        micProximity _: MicProximity
    ) async throws {
        let claimed = lock.withLock {
            guard activeSessionID == nil else { return false }
            activeSessionID = sessionID
            return true
        }
        guard claimed else { throw CancellationError() }
    }

    func sendAudio(
        _: Data,
        sessionID: DictationSessionID
    ) async throws {
        let accepted = lock.withLock { activeSessionID == sessionID }
        guard accepted else { throw CancellationError() }
    }

    func finishStreaming(sessionID: DictationSessionID) async throws -> String {
        let finished = lock.withLock {
            guard activeSessionID == sessionID else { return false }
            activeSessionID = nil
            return true
        }
        guard finished else { throw CancellationError() }
        return ""
    }

    func cancelActiveStreaming() async {
        guard let sessionID = lock.withLock({ activeSessionID }) else { return }
        await cancelStreaming(sessionID: sessionID)
    }

    func cancelStreaming(sessionID: DictationSessionID) async {
        lock.withLock {
            guard activeSessionID == sessionID else { return }
            activeSessionID = nil
        }
    }
}

// ---------------------------------------------------------------------------
// Tests for DictationPipeline.pipelineDeadline.
//
// The deadline is the hard cap on the pipeline task's total duration. It
// must scale with the recording duration so long dictations do not race
// the force-reset and drop valid transcripts.
// ---------------------------------------------------------------------------

@Suite("DictationPipeline – pipelineDeadline")
struct PipelineDeadlineTests {

    @Test("zero recording duration returns the baseline budget")
    func zeroRecording() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 0)
        #expect(d == 45.0)
    }

    @Test("two second recording gets baseline + duration")
    func twoSecondRecording() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 2.0)
        #expect(d == 47.0)
    }

    @Test("recordingDuration + 45 formula applies in the middle range")
    func middleRange() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 30)
        #expect(d == 75.0)
    }

    @Test("130 second monologue gets 175 second deadline")
    func longMonologue() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 130)
        #expect(d == 175.0)
    }

    @Test("deadline is capped at 300 seconds")
    func cappedAtCeiling() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 600)
        #expect(d == 300.0)
    }

    @Test("batch-only cloud path reserves transcription, polish, and teardown")
    func batchOnlyRecoveryReserve() {
        let d = DictationPipeline.pipelineDeadline(
            forRecordingDuration: 2,
            cloudStreamingMaximumFinishWatchdog: nil,
            requiresCloudBatchWindow: true)

        #expect(d == DictationPipeline.cloudBatchRecoveryReserve)
        #expect(d == 100)
    }

    @Test("cloud streaming deadline starts its batch reserve after the watchdog")
    func streamingRecoveryReserve() {
        let watchdog: TimeInterval = 21
        let d = DictationPipeline.pipelineDeadline(
            forRecordingDuration: 2,
            cloudStreamingMaximumFinishWatchdog: watchdog,
            requiresCloudBatchWindow: true)

        #expect(d - watchdog >= DictationPipeline.cloudBatchRecoveryReserve)
        #expect(d == 121)
    }

    @Test("cloud outer deadline reserves the stable maximum while child watchdog grows")
    func streamingRecoveryUsesMaximumWatchdog() {
        let provider = GrowingFinishWatchdogProvider()
        let earlyDynamicWatchdog = provider.finishStreamingWatchdog
        let earlyDeadline = DictationPipeline.pipelineDeadline(
            forRecordingDuration: 2,
            cloudStreamingProvider: provider,
            requiresCloudBatchWindow: true)

        provider.finishStreamingWatchdog = 175
        let lateDeadline = DictationPipeline.pipelineDeadline(
            forRecordingDuration: 2,
            cloudStreamingProvider: provider,
            requiresCloudBatchWindow: true)

        #expect(earlyDynamicWatchdog == 20)
        #expect(earlyDeadline == 275)
        #expect(lateDeadline == earlyDeadline)
    }

    @Test("five-minute cloud boundary leaves at least the promised reserve")
    func supportedCloudMaximumReserve() {
        let sourceDuration: TimeInterval = 300
        let wireBytes = Int(sourceDuration * 48_000)
        let watchdog = min(
            295,
            OpenAIStreamingProvider.transcriptTimeout(forAudioBytes: wireBytes) + 5)
        let d = DictationPipeline.pipelineDeadline(
            forRecordingDuration: sourceDuration,
            cloudStreamingMaximumFinishWatchdog: watchdog,
            requiresCloudBatchWindow: true)

        #expect(watchdog == 170)
        #expect(d == 300)
        #expect(d - watchdog >= DictationPipeline.cloudBatchRecoveryReserve)
    }
}
