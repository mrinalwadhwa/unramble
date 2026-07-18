import Foundation
import Testing

@testable import UnrambleKit
import UnrambleKitTestSupport

/// Lifecycle behavior that holds across every backend: the pipeline resolves
/// one transcript per press, injects it, stores it in the buffer, and returns
/// to idle. Each invariant runs against the cloud streaming path, the cloud
/// batch-fallback path, and the local path, so one statement of the behavior
/// covers all three backends instead of repeating it per suite.
@Suite("Pipeline session lifecycle")
struct PipelineSessionLifecycleTests {

    // MARK: - Transcript buffer wiring

    @Test("success stores the resolved transcript", arguments: LifecycleMode.allCases)
    func successStoresTranscript(_ mode: LifecycleMode) async {
        let buffer = TranscriptBuffer()
        let harness = LifecycleHarness(mode: mode, resolvesTo: "Hello from buffer", buffer: buffer)
        await harness.runCycle()

        #expect(await buffer.lastTranscript == "Hello from buffer")
        #expect(harness.injector.lastInjectedText == "Hello from buffer")
        #expect(await harness.coordinator.state == .idle)
    }

    @Test(
        "an empty or whitespace result stores nothing and does not inject",
        arguments: LifecycleMode.allCases, ["", "   "])
    func emptyResultStoresNothing(_ mode: LifecycleMode, _ resolved: String) async {
        let buffer = TranscriptBuffer()
        let harness = LifecycleHarness(mode: mode, resolvesTo: resolved, buffer: buffer)
        await harness.runCycle()

        #expect(await buffer.lastTranscript == nil)
        #expect(harness.injector.injectionCount == 0)
        #expect(await harness.coordinator.state == .idle)
    }

    @Test("a cycle without a buffer still injects", arguments: LifecycleMode.allCases)
    func nilBufferStillInjects(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "No buffer here", buffer: nil)
        await harness.runCycle()

        #expect(harness.injector.injectionCount == 1)
        #expect(harness.injector.lastInjectedText == "No buffer here")
        #expect(await harness.coordinator.state == .idle)
    }

    @Test("the buffer updates on each cycle", arguments: LifecycleMode.allCases)
    func bufferUpdatesEachCycle(_ mode: LifecycleMode) async {
        let buffer = TranscriptBuffer()
        let harness = LifecycleHarness(mode: mode, resolvesTo: "first", buffer: buffer)
        await harness.runCycle()
        #expect(await buffer.lastTranscript == "first")

        harness.resolve(to: "second")
        await harness.runCycle()
        #expect(await buffer.lastTranscript == "second")
    }
}

/// The backend configuration a lifecycle behavior runs against.
enum LifecycleMode: CaseIterable, CustomStringConvertible, Sendable {
    /// Cloud backend where realtime streaming resolves the transcript.
    case cloudStreaming
    /// Cloud backend with no PCM stream, so the batch fallback resolves it.
    case cloudBatch
    /// Local backend where on-device streaming resolves the transcript.
    case local

    var description: String {
        switch self {
        case .cloudStreaming: return "cloud-streaming"
        case .cloudBatch: return "cloud-batch"
        case .local: return "local"
        }
    }

    /// Streaming and local forward live PCM; the batch-fallback path does not.
    var streamsPCM: Bool { self != .cloudBatch }
}

/// Drives one activate → forward → complete dictation cycle for a backend
/// mode, configuring the mode's resolving provider to produce a given
/// transcript so a single behavior can assert across all three backends.
private final class LifecycleHarness {
    let mode: LifecycleMode
    let pipeline: DictationPipeline
    let audio: MockAudioProvider
    let streaming: MockStreamingProvider
    let batch: MockBatchProvider
    let injector: MockTextInjector
    let coordinator: RecordingCoordinator

    init(mode: LifecycleMode, resolvesTo text: String, buffer: TranscriptBuffer?) {
        self.mode = mode
        let audio = MockAudioProvider()
        audio.enablePCMStream = mode.streamsPCM
        let streaming = MockStreamingProvider(stubbedText: "")
        let batch = MockBatchProvider(stubbedText: "")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()

        let backend: DictationBackend
        switch mode {
        case .cloudStreaming:
            streaming.stubbedText = text
            backend = .cloud(realtime: streaming, fallback: batch)
        case .cloudBatch:
            batch.stubbedText = text
            backend = .cloud(realtime: streaming, fallback: batch)
        case .local:
            streaming.stubbedText = text
            backend = .local(streaming: streaming)
        }

        self.audio = audio
        self.streaming = streaming
        self.batch = batch
        self.injector = injector
        self.coordinator = coordinator
        self.pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            backend: backend,
            textInjector: injector,
            coordinator: coordinator,
            transcriptBuffer: buffer
        )
    }

    /// Reconfigure the resolving provider before a subsequent cycle.
    func resolve(to text: String) {
        switch mode {
        case .cloudStreaming, .local: streaming.stubbedText = text
        case .cloudBatch: batch.stubbedText = text
        }
    }

    /// Run one activate → forward-PCM → complete cycle and let it settle.
    func runCycle() async {
        let previousReadyCount = audio.captureReadyCount
        await pipeline.activate()
        await waitForCaptureReady(after: previousReadyCount)

        let emitTask = mode.streamsPCM ? emitChunks() : nil
        await pipeline.complete()
        emitTask?.cancel()
    }

    private func waitForCaptureReady(after previous: Int) async {
        for _ in 0..<1_000 {
            if audio.captureReadyCount > previous { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Capture did not become ready for mode \(mode)")
    }

    private func emitChunks(count: Int = 8) -> Task<Void, Never> {
        let audio = self.audio
        return Task {
            for _ in 0..<count {
                guard !Task.isCancelled else { break }
                audio.emitPCMChunk(Self.nonSilentPCMChunk())
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private static func nonSilentPCMChunk(sampleCount: Int = 1600) -> Data {
        var data = Data(capacity: sampleCount * 2)
        for i in 0..<sampleCount {
            let sample: Int16 = i % 2 == 0 ? 3000 : -3000
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
