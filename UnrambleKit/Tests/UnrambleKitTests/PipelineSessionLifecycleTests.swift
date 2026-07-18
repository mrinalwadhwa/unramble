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

    // MARK: - Full cycle

    @Test("a full cycle starts and stops audio capture", arguments: LifecycleMode.allCases)
    func startsAndStopsCapture(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "captured", buffer: nil)
        await harness.runCycle()

        #expect(harness.audio.startCallCount == 1)
        #expect(harness.audio.stopCallCount == 1)
        #expect(harness.audio.isRecording == false)
    }

    @Test("a full cycle reads the app context once", arguments: LifecycleMode.allCases)
    func readsContextOncePerCycle(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "context", buffer: nil)
        await harness.runCycle()

        #expect(harness.contextProvider.readContextCallCount == 1)
    }

    @Test("injection targets the context read at capture", arguments: LifecycleMode.allCases)
    func injectsIntoReadContext(_ mode: LifecycleMode) async {
        let context = AppContext(
            bundleID: "com.example.myapp", appName: "MyApp", windowTitle: "Document 1")
        let harness = LifecycleHarness(
            mode: mode, resolvesTo: "targeted", buffer: nil, context: context)
        await harness.runCycle()

        #expect(harness.injector.injections.count == 1)
        #expect(harness.injector.injections.first?.context == context)
    }

    // MARK: - State transitions

    @Test(
        "a cycle passes through the expected state sequence",
        arguments: LifecycleMode.allCases)
    func passesThroughStateSequence(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "states", buffer: nil)
        let states = await harness.runCycleObservingStates()
        #expect(states == [.idle, .recording, .processing, .injecting, .idle])
    }

    // MARK: - Cancellation

    @Test("cancel from recording returns to idle", arguments: LifecycleMode.allCases)
    func cancelFromRecordingReturnsToIdle(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "cancelled", buffer: nil)
        await harness.activateToRecording()
        #expect(await harness.coordinator.state == .recording)

        await harness.pipeline.cancel()
        #expect(await harness.coordinator.state == .idle)
        #expect(harness.audio.isRecording == false)
    }

    @Test("cancel from idle stays idle", arguments: LifecycleMode.allCases)
    func cancelFromIdleStaysIdle(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "cancelled", buffer: nil)
        await harness.pipeline.cancel()
        #expect(await harness.coordinator.state == .idle)
    }

    @Test("a cycle works after a cancel", arguments: LifecycleMode.allCases)
    func cycleWorksAfterCancel(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "after cancel", buffer: nil)
        await harness.pipeline.activate()
        await harness.pipeline.cancel()
        #expect(await harness.coordinator.state == .idle)

        await harness.runCycle()
        #expect(await harness.coordinator.state == .idle)
        #expect(harness.injector.injectionCount == 1)
        #expect(harness.injector.lastInjectedText == "after cancel")
    }

    // MARK: - Multiple cycles

    @Test("consecutive cycles each complete and inject", arguments: LifecycleMode.allCases)
    func consecutiveCyclesEachComplete(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "cycle 1", buffer: nil)
        let texts = ["cycle 1", "cycle 2", "cycle 3"]
        for (index, text) in texts.enumerated() {
            harness.resolve(to: text)
            await harness.runCycle()
            #expect(await harness.coordinator.state == .idle)
            #expect(harness.injector.injectionCount == index + 1)
            #expect(harness.injector.lastInjectedText == text)
        }
        #expect(harness.audio.startCallCount == texts.count)
        #expect(harness.audio.stopCallCount == texts.count)
        #expect(harness.contextProvider.readContextCallCount == texts.count)
    }

    // MARK: - Silence gate

    // A silent press must skip dictation on every backend. The two peak-RMS
    // values cover both post-record silence paths: an exact 0 (the tap ran and
    // captured nothing) and a nonzero level at or below the threshold.
    @Test(
        "audio below the silence threshold skips dictation without injecting",
        arguments: LifecycleMode.allCases, [Float(0), Float(0.001)])
    func silentAudioSkipsDictation(_ mode: LifecycleMode, _ peakRMS: Float) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "unheard", buffer: nil)
        harness.audio.stubbedPeakRMS = peakRMS
        await harness.runCycle()

        #expect(harness.injector.injectionCount == 0)
        #expect(harness.batch.dictateCallCount == 0)
        #expect(await harness.coordinator.state == .idle)
    }

    // MARK: - Injection failure

    @Test(
        "an injection failure transitions to injectionFailed",
        arguments: LifecycleMode.allCases)
    func injectionFailureTransitions(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "unreachable", buffer: nil)
        harness.injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        await harness.runCycle()
        #expect(await harness.coordinator.state == .injectionFailed)
    }

    @Test(
        "an injection failure preserves the transcript in the buffer",
        arguments: LifecycleMode.allCases)
    func injectionFailurePreservesTranscript(_ mode: LifecycleMode) async {
        let buffer = TranscriptBuffer()
        let harness = LifecycleHarness(mode: mode, resolvesTo: "preserved", buffer: buffer)
        harness.injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        await harness.runCycle()
        #expect(await buffer.lastTranscript == "preserved")
    }

    @Test(
        "an injection failure ends the state sequence in injectionFailed",
        arguments: LifecycleMode.allCases)
    func injectionFailureStateSequence(_ mode: LifecycleMode) async {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "unreachable", buffer: nil)
        harness.injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let states = await harness.runCycleObservingStates()
        #expect(states == [.idle, .recording, .processing, .injecting, .injectionFailed])
    }

    @Test(
        "a cycle works after dismissing an injection failure",
        arguments: LifecycleMode.allCases)
    func cycleWorksAfterInjectionFailureReset(_ mode: LifecycleMode) async throws {
        let harness = LifecycleHarness(mode: mode, resolvesTo: "first attempt", buffer: nil)
        harness.injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let sessionID = try #require(await harness.runCycle())
        #expect(await harness.coordinator.state == .injectionFailed)

        await harness.pipeline.dismissInjectionFailure(sessionID: sessionID)
        #expect(await harness.coordinator.state == .idle)

        harness.injector.stubbedError = nil
        harness.resolve(to: "second attempt")
        await harness.runCycle()
        #expect(await harness.coordinator.state == .idle)
        #expect(harness.injector.injectionCount == 1)
        #expect(harness.injector.lastInjectedText == "second attempt")
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
    let contextProvider: MockAppContextProvider

    init(
        mode: LifecycleMode,
        resolvesTo text: String,
        buffer: TranscriptBuffer?,
        context: AppContext = .stub
    ) {
        self.mode = mode
        let audio = MockAudioProvider()
        audio.enablePCMStream = mode.streamsPCM
        let streaming = MockStreamingProvider(stubbedText: "")
        let batch = MockBatchProvider(stubbedText: "")
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let contextProvider = MockAppContextProvider(context: context)

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
        self.contextProvider = contextProvider
        self.pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: contextProvider,
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

    /// Activate and wait until live capture is ready (state is recording),
    /// returning the admitted session id.
    @discardableResult
    func activateToRecording() async -> DictationSessionID? {
        let previousReadyCount = audio.captureReadyCount
        let sessionID = await pipeline.activate()
        await waitForCaptureReady(after: previousReadyCount)
        return sessionID
    }

    /// Run one activate → forward-PCM → complete cycle and let it settle,
    /// returning the admitted session id.
    @discardableResult
    func runCycle() async -> DictationSessionID? {
        let sessionID = await activateToRecording()
        let emitTask = mode.streamsPCM ? emitChunks() : nil
        await pipeline.complete()
        emitTask?.cancel()
        return sessionID
    }

    /// Run one cycle while collecting the coordinator's state transitions,
    /// returning the observed sequence once it settles back to idle.
    func runCycleObservingStates() async -> [RecordingState] {
        let coordinator = self.coordinator
        let collector = Task { () -> [RecordingState] in
            var collected: [RecordingState] = []
            for await state in await coordinator.stateStream {
                collected.append(state)
                if collected.count >= 5 { break }
            }
            return collected
        }
        // Let the collector subscribe before the cycle drives transitions.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await runCycle()
        return await collector.value
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
