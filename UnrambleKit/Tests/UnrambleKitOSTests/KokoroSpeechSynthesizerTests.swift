import AVFoundation
import Foundation
import Testing

@testable import UnrambleKit

@Suite("Kokoro speech synthesizer")
struct KokoroSpeechSynthesizerTests {

    private func makeMissingDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-missing-\(UUID().uuidString)")
    }

    @Test("Speaking without a model pack returns promptly")
    func missingPackReturnsPromptly() async {
        // Model load fails (no weights); speak must swallow the failure
        // and return so the read session ends instead of hanging.
        let synthesizer = KokoroSpeechSynthesizer(
            modelDirectory: makeMissingDirectory(),
            g2pResourcesDirectory: makeMissingDirectory())
        await synthesizer.speak("This has nowhere to go.")
    }

    @Test("Stopping while idle is safe")
    func stopWhileIdleIsSafe() {
        let synthesizer = KokoroSpeechSynthesizer(
            modelDirectory: makeMissingDirectory(),
            g2pResourcesDirectory: makeMissingDirectory())
        synthesizer.stopSpeaking()
        synthesizer.stopSpeaking()
    }

    @Test("Speaking empty text returns immediately")
    func emptyTextReturnsImmediately() async {
        let synthesizer = KokoroSpeechSynthesizer(
            modelDirectory: makeMissingDirectory(),
            g2pResourcesDirectory: makeMissingDirectory())
        await synthesizer.speak("   \n ")
    }

    @Test("Playback queues its first buffer before starting")
    func playbackQueuesBeforeStarting() throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)

        try playback.schedule(samples: [0.1, 0.2])

        #expect(player.events == [.scheduled, .started])
        playback.stop()
    }

    @Test("Paragraphs schedule 300 ms of silence between their spoken audio")
    func paragraphsScheduleSilence() async throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)
        defer { playback.stop() }
        let content = ReadableContent(segments: [
            .init(kind: .prose, text: "First paragraph"),
            .init(kind: .prose, text: "Second paragraph"),
        ])
        var generatedTexts: [String] = []

        try await KokoroSpeechSynthesizer.scheduleSpeech(
            SpeechScriptBuilder().script(for: content), into: playback
        ) { text in
            generatedTexts.append(text)
            return [Float(generatedTexts.count)]
        }

        #expect(generatedTexts == ["First paragraph.", "Second paragraph"])
        #expect(player.buffers == [[1], [Float](repeating: 0, count: 7_200), [2]])
    }

    @Test("Sentences within a paragraph do not schedule extra silence")
    func sentencesDoNotScheduleSilence() async throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)
        defer { playback.stop() }
        var generatedTexts: [String] = []

        try await KokoroSpeechSynthesizer.scheduleSpeech(
            "First sentence.\nSecond sentence.", into: playback
        ) { text in
            generatedTexts.append(text)
            return [0.1, 0.2]
        }

        #expect(generatedTexts == ["First sentence. Second sentence."])
        #expect(player.buffers == [[0.1, 0.2]])
    }

    @Test("A long paragraph schedules silence only before the next paragraph")
    func longParagraphSchedulesOnePause() async throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)
        defer { playback.stop() }
        // Each sentence fits, but together they exceed the 350-character budget.
        let sentence = String(repeating: "word ", count: 39) + "end."
        var generatedTexts: [String] = []

        try await KokoroSpeechSynthesizer.scheduleSpeech(
            "\(sentence) \(sentence)\n\nNext paragraph.", into: playback
        ) { text in
            generatedTexts.append(text)
            return [Float(generatedTexts.count)]
        }

        #expect(generatedTexts == [sentence, sentence, "Next paragraph."])
        #expect(player.buffers == [[1], [2], [Float](repeating: 0, count: 7_200), [3]])
    }

    @Test("Whitespace-only scripts do not generate or schedule audio")
    func whitespaceSchedulesNothing() async throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)
        defer { playback.stop() }

        try await KokoroSpeechSynthesizer.scheduleSpeech(" \n\n\t ", into: playback) { _ in
            Issue.record("Whitespace must not reach the voice model")
            return [1]
        }

        #expect(player.buffers.isEmpty)
        #expect(player.events.isEmpty)
    }

    @Test("An empty generated waveform does not schedule a standalone pause")
    func emptyAudioSchedulesNothing() async throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)
        defer { playback.stop() }

        try await KokoroSpeechSynthesizer.scheduleSpeech(
            "First.\n\nSecond.", into: playback
        ) { _ in [] }

        #expect(player.buffers.isEmpty)
    }

    @Test("An empty final chunk keeps the preceding paragraph's pause")
    func emptyFinalChunkKeepsParagraphPause() async throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)
        defer { playback.stop() }
        let firstSentence = String(repeating: "word ", count: 39) + "end."
        let emptySentence = String(repeating: "silent ", count: 39) + "end."

        try await KokoroSpeechSynthesizer.scheduleSpeech(
            "\(firstSentence) \(emptySentence)\n\nNext.", into: playback
        ) { text in
            if text == emptySentence { return [] }
            return text == "Next." ? [2] : [1]
        }

        #expect(player.buffers == [[1], [Float](repeating: 0, count: 7_200), [2]])
    }

    @Test("Empty paragraphs do not introduce leading, trailing, or duplicate silence")
    func emptyParagraphsDoNotAddSilence() async throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)
        defer { playback.stop() }

        try await KokoroSpeechSynthesizer.scheduleSpeech(
            "Empty.\n\nFirst.\n\nEmpty.\n\nSecond.\n\nEmpty.", into: playback
        ) { text in
            if text == "Empty." { return [] }
            return text == "First." ? [1] : [2]
        }

        #expect(player.buffers == [[1], [Float](repeating: 0, count: 7_200), [2]])
    }

    @Test("Silence duration uses the playback sample rate", arguments: [24_000.0, 48_000.0])
    func silenceUsesPlaybackSampleRate(sampleRate: Double) throws {
        let player = RecordingPCMChunkPlayer(sampleRate: sampleRate)
        let playback = PCMChunkPlayback(player: player)
        defer { playback.stop() }

        try playback.scheduleSilence(duration: 0.3)

        let expectedFrames = sampleRate == 24_000 ? 7_200 : 14_400
        #expect(player.buffers == [[Float](repeating: 0, count: expectedFrames)])
        #expect(player.events == [.scheduled, .started])
    }

    @Test("Stopping pending paragraph silence rejects later audio",
        .timeLimit(.minutes(1)))
    func stopDuringParagraphPause() async throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)
        try playback.schedule(samples: [1])
        try playback.scheduleSilence(duration: 0.3)
        player.finishNextBuffer()  // Speech finished; the pause is still pending.

        playback.stop()
        try playback.scheduleSilence(duration: 0.3)
        try playback.schedule(samples: [2])
        await playback.drain()
        player.finishNextBuffer()  // A late device callback after stopping is safe.

        #expect(player.events == [.scheduled, .started, .scheduled, .stopped])
        #expect(player.buffers == [[1], [Float](repeating: 0, count: 7_200)])
    }

    @Test("Stop cannot return before an in-flight player schedule and restart")
    func stopSerializesWithScheduling() {
        let scheduleEntered = DispatchSemaphore(value: 0)
        let releaseSchedule = DispatchSemaphore(value: 0)
        let stopRequested = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        let player = RecordingPCMChunkPlayer(onSchedule: {
            scheduleEntered.signal()
            // A bound keeps a failed test from stranding a worker thread.
            _ = releaseSchedule.wait(timeout: .now() + 5)
        })
        let playback = PCMChunkPlayback(player: player)
        let scheduling = DispatchWorkItem {
            do {
                try playback.schedule(samples: [1])
            } catch {
                Issue.record(error)
            }
        }
        DispatchQueue.global().async(execute: scheduling)
        #expect(scheduleEntered.wait(timeout: .now() + 2) == .success)
        let stopping = DispatchWorkItem {
            stopRequested.signal()
            playback.stop()
            stopReturned.signal()
        }
        DispatchQueue.global().async(execute: stopping)
        #expect(stopRequested.wait(timeout: .now() + 2) == .success)

        // Stop must wait for the in-flight device call; otherwise scheduling
        // can restart audio after Stop has already returned.
        #expect(stopReturned.wait(timeout: .now() + 0.1) == .timedOut)
        releaseSchedule.signal()
        #expect(scheduling.wait(timeout: .now() + 2) == .success)
        #expect(stopping.wait(timeout: .now() + 2) == .success)

        #expect(player.events == [.scheduled, .started, .stopped])
    }

    @Test("Cancellation during generation does not queue the next paragraph")
    func cancellationStopsLaterParagraph() async throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)
        defer { playback.stop() }
        let task = Task {
            try await KokoroSpeechSynthesizer.scheduleSpeech(
                "First.\n\nSecond.", into: playback
            ) { text in
                if text == "Second." {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return [1]
            }
        }

        do {
            try await task.value
            Issue.record("Expected cancellation to stop scheduling")
        } catch is CancellationError {
            // Expected: the generation checkpoint observes cancellation.
        }
        #expect(player.buffers == [[1]])
    }
}

private final class RecordingPCMChunkPlayer: PCMChunkPlaying,
    @unchecked Sendable
{
    enum Event: Equatable {
        case scheduled
        case started
        case stopped
    }

    let format: AVAudioFormat?
    private let lock = NSLock()
    private var recordedEvents: [Event] = []
    private var recordedBuffers: [[Float]] = []
    private var completions: [@Sendable () -> Void] = []
    private let onSchedule: (@Sendable () -> Void)?

    var events: [Event] { lock.withLock { recordedEvents } }
    var buffers: [[Float]] { lock.withLock { recordedBuffers } }

    init(sampleRate: Double = 24_000, onSchedule: (@Sendable () -> Void)? = nil) {
        self.onSchedule = onSchedule
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false)
    }

    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @Sendable () -> Void
    ) {
        let samples = Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        lock.withLock {
            recordedEvents.append(.scheduled)
            recordedBuffers.append(samples)
            completions.append(completion)
        }
        onSchedule?()
    }

    func finishNextBuffer() {
        let completion = lock.withLock { completions.removeFirst() }
        completion()
    }

    func start() throws {
        lock.withLock { recordedEvents.append(.started) }
    }

    func stop() {
        lock.withLock { recordedEvents.append(.stopped) }
    }
}
