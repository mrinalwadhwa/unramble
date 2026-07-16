import Foundation
import Testing

@testable import FreeFlowKit

@Suite("MicDiagnosticStore")
struct MicDiagnosticStoreTests {

    @Test("Record, clear, and empty formatting")
    func recordAndClear() async {
        let store = MicDiagnosticStore()
        #expect(await store.count == 0)
        #expect(
            await store.formattedDiagnostics()
                == "No dictation sessions recorded yet.")

        await store.record(entry())
        await store.record(entry(result: .silent))
        #expect(await store.count == 2)

        await store.clear()
        #expect(await store.count == 0)
        #expect(
            await store.formattedDiagnostics()
                == "No dictation sessions recorded yet.")
    }

    @Test("Capacity is FIFO and capped at ten")
    func boundedFIFO() async {
        let store = MicDiagnosticStore(maxEntries: 10_000)
        for index in 0..<15 {
            await store.record(entry(peakRMS: Float(index) / 100))
        }

        #expect(await store.count == MicDiagnosticStore.maximumCapacity)
        let report = await store.formattedDiagnostics()
        #expect(!report.contains("peak=0.000000"))
        #expect(!report.contains("peak=0.040000"))
        #expect(report.contains("peak=0.050000"))
        #expect(report.contains("peak=0.140000"))
    }

    @Test("Custom capacity keeps newest entries in order")
    func customCapacity() async throws {
        let store = MicDiagnosticStore(maxEntries: 3)
        for peak: Float in [0.01, 0.02, 0.03, 0.04] {
            await store.record(entry(peakRMS: peak))
        }

        #expect(await store.count == 3)
        let report = await store.formattedDiagnostics()
        #expect(!report.contains("peak=0.010000"))
        let second = try #require(report.range(of: "peak=0.020000"))
        let third = try #require(report.range(of: "peak=0.030000"))
        let fourth = try #require(report.range(of: "peak=0.040000"))
        #expect(second.lowerBound < third.lowerBound)
        #expect(third.lowerBound < fourth.lowerBound)
    }

    @Test("Zero and negative capacities discard entries")
    func nonpositiveCapacity() async {
        let zero = MicDiagnosticStore(maxEntries: 0)
        let negative = MicDiagnosticStore(maxEntries: -10)

        await zero.record(entry())
        await negative.record(entry())

        #expect(await zero.count == 0)
        #expect(await negative.count == 0)
    }

    @Test("Formatting contains only typed outcomes and numeric mic metadata")
    func contentFreeFormatting() async {
        let store = MicDiagnosticStore()
        await store.record(
            entry(
                proximity: .farField,
                ambientRMS: 0.0003,
                peakRMS: 0.045,
                gain: 12,
                threshold: 0.001,
                duration: 2.5,
                latency: 0.55,
                result: .successLocal))

        let report = await store.formattedDiagnostics()
        #expect(report.contains("(1 session)"))
        #expect(report.contains("Session 1:"))
        #expect(report.contains("proximity=far_field"))
        #expect(report.contains("ambient=0.000300"))
        #expect(report.contains("peak=0.045000"))
        #expect(report.contains("gain=12.0x"))
        #expect(report.contains("threshold=0.001000"))
        #expect(report.contains("duration=2.50s"))
        #expect(report.contains("latency=0.55s"))
        #expect(report.contains("result=ok_local"))
        #expect(!report.contains("device="))
    }

    @Test("Every diagnostic outcome has a stable wire label", arguments: [
        (MicDiagnosticResult.silent, "silent"),
        (.empty, "empty"),
        (.successLocal, "ok_local"),
        (.successRealtime, "ok_realtime"),
        (.successHTTPFallback, "ok_http_fallback"),
    ])
    func resultLabels(result: MicDiagnosticResult, label: String) {
        #expect(result.rawValue == label)
    }

    @Suite("Pipeline integration")
    struct PipelineIntegrationTests {

        @Test("Realtime success records the closed success outcome")
        func realtimeSuccess() async {
            let audio = configuredAudio()
            let realtime = MockStreamingProvider()
            realtime.stubbedText = "Hello world"
            let store = MicDiagnosticStore()
            let pipeline = makePipeline(
                audio: audio,
                realtime: realtime,
                fallback: MockBatchProvider(stubbedText: "fallback"),
                store: store)

            await activateAndComplete(
                pipeline, audio: audio, realtime: realtime)

            let report = await store.formattedDiagnostics()
            #expect(await store.count == 1)
            #expect(report.contains("result=ok_realtime"))
            #expect(report.contains("proximity=near_field"))
        }

        @Test("Silent capture records silent without sending content")
        func silentCapture() async {
            let audio = configuredAudio()
            audio.stubbedPeakRMS = 0.0001
            audio.stubbedAmbientRMS = 0.0001
            audio.stubbedMicProximity = .farField
            let realtime = MockStreamingProvider()
            let store = MicDiagnosticStore()
            let pipeline = makePipeline(
                audio: audio,
                realtime: realtime,
                fallback: MockBatchProvider(),
                store: store)

            await activateAndComplete(
                pipeline,
                audio: audio,
                realtime: realtime,
                waitForStreaming: false)

            let report = await store.formattedDiagnostics()
            #expect(await store.count == 1)
            #expect(report.contains("result=silent"))
            #expect(realtime.sendCallCount == 0)
        }

        @Test("Empty realtime and fallback results record empty")
        func emptyResult() async {
            let audio = configuredAudio()
            let realtime = MockStreamingProvider()
            realtime.stubbedText = ""
            let store = MicDiagnosticStore()
            let pipeline = makePipeline(
                audio: audio,
                realtime: realtime,
                fallback: MockBatchProvider(stubbedText: "   "),
                store: store)

            await activateAndComplete(
                pipeline, audio: audio, realtime: realtime)

            let report = await store.formattedDiagnostics()
            #expect(await store.count >= 1)
            #expect(report.contains("result=empty"))
        }

        @Test("HTTP fallback success records its distinct outcome")
        func fallbackSuccess() async {
            let audio = configuredAudio()
            let realtime = MockStreamingProvider()
            realtime.stubbedFinishError = DictationError.networkError("offline")
            let store = MicDiagnosticStore()
            let pipeline = makePipeline(
                audio: audio,
                realtime: realtime,
                fallback: MockBatchProvider(stubbedText: "Recovered"),
                store: store)

            await activateAndComplete(
                pipeline, audio: audio, realtime: realtime)

            let report = await store.formattedDiagnostics()
            #expect(await store.count == 1)
            #expect(report.contains("result=ok_http_fallback"))
        }

        @Test("Pipeline without diagnostics store remains functional")
        func noStore() async {
            let audio = configuredAudio()
            let realtime = MockStreamingProvider()
            let pipeline = DictationPipeline(
                audioProvider: audio,
                contextProvider: MockAppContextProvider(),
                backend: .cloud(
                    realtime: realtime,
                    fallback: MockBatchProvider(stubbedText: "safe")),
                textInjector: MockTextInjector(),
                coordinator: RecordingCoordinator())

            await activateAndComplete(
                pipeline, audio: audio, realtime: realtime)
        }

        private func configuredAudio() -> MockAudioProvider {
            let audio = MockAudioProvider()
            audio.enablePCMStream = true
            audio.stubbedPeakRMS = 0.1
            audio.stubbedAmbientRMS = 0.001
            audio.stubbedMicProximity = .nearField
            return audio
        }

        private func makePipeline(
            audio: MockAudioProvider,
            realtime: MockStreamingProvider,
            fallback: MockBatchProvider,
            store: MicDiagnosticStore
        ) -> DictationPipeline {
            DictationPipeline(
                audioProvider: audio,
                contextProvider: MockAppContextProvider(),
                backend: .cloud(realtime: realtime, fallback: fallback),
                textInjector: MockTextInjector(),
                coordinator: RecordingCoordinator(),
                micDiagnosticStore: store)
        }

        private func activateAndComplete(
            _ pipeline: DictationPipeline,
            audio: MockAudioProvider,
            realtime: MockStreamingProvider,
            waitForStreaming: Bool = true
        ) async {
            let readyCount = audio.captureReadyCount
            guard await pipeline.activate() != nil else {
                Issue.record("Pipeline activation was rejected")
                return
            }
            for _ in 0..<10_000 where audio.captureReadyCount == readyCount {
                await Task.yield()
            }
            guard audio.captureReadyCount > readyCount else {
                Issue.record("Audio capture did not become ready")
                return
            }
            guard waitForStreaming else {
                await pipeline.complete()
                return
            }

            let setupDeadline = ContinuousClock.now + .seconds(1)
            while realtime.startCallCount == 0,
                ContinuousClock.now < setupDeadline
            {
                try? await Task.sleep(for: .milliseconds(1))
            }
            guard realtime.startCallCount > 0 else {
                Issue.record("Realtime setup did not start")
                return
            }
            audio.emitPCMChunk(Data(repeating: 1, count: 320))
            let forwardingDeadline = ContinuousClock.now + .seconds(1)
            while realtime.sendCallCount == 0,
                ContinuousClock.now < forwardingDeadline
            {
                try? await Task.sleep(for: .milliseconds(1))
            }
            guard realtime.sendCallCount > 0 else {
                Issue.record("Realtime audio forwarding did not start")
                return
            }
            await pipeline.complete()
        }
    }

    private func entry(
        proximity: MicProximity = .nearField,
        ambientRMS: Float = 0.001,
        peakRMS: Float = 0.05,
        gain: Float = 1,
        threshold: Float = 0.005,
        duration: TimeInterval = 1,
        latency: TimeInterval = 0.5,
        result: MicDiagnosticResult = .successRealtime
    ) -> MicDiagnosticEntry {
        MicDiagnosticEntry(
            proximity: proximity,
            ambientRMS: ambientRMS,
            peakRMS: peakRMS,
            gain: gain,
            threshold: threshold,
            duration: duration,
            latency: latency,
            result: result)
    }
}
