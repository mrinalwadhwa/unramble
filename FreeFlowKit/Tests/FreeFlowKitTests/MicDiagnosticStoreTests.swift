import Foundation
import Testing

@testable import FreeFlowKit

@Suite("MicDiagnosticStore")
struct MicDiagnosticStoreTests {

    // MARK: - Helpers

    private func makeEntry(
        deviceName: String = "MacBook Pro Microphone",
        proximity: String = "far_field",
        ambientRMS: Float = 0.000300,
        peakRMS: Float = 0.045000,
        gain: Float = 12.0,
        threshold: Float = 0.001000,
        duration: TimeInterval = 2.5,
        latency: TimeInterval = 0.55,
        result: String = "ok"
    ) -> MicDiagnosticEntry {
        MicDiagnosticEntry(
            deviceName: deviceName,
            proximity: proximity,
            ambientRMS: ambientRMS,
            peakRMS: peakRMS,
            gain: gain,
            threshold: threshold,
            duration: duration,
            latency: latency,
            result: result
        )
    }

    // MARK: - Recording

    @Suite("record")
    struct RecordTests {

        private func makeEntry(
            result: String = "ok"
        ) -> MicDiagnosticEntry {
            MicDiagnosticEntry(
                deviceName: "Test Mic",
                proximity: "near_field",
                ambientRMS: 0.001,
                peakRMS: 0.05,
                gain: 1.0,
                threshold: 0.005,
                duration: 1.0,
                latency: 0.5,
                result: result
            )
        }

        @Test("Empty store has zero count")
        func emptyStore() async {
            let store = MicDiagnosticStore()
            let count = await store.count
            #expect(count == 0)
        }

        @Test("Recording one entry increments count")
        func recordOne() async {
            let store = MicDiagnosticStore()
            await store.record(makeEntry())
            let count = await store.count
            #expect(count == 1)
        }

        @Test("Recording multiple entries increments count")
        func recordMultiple() async {
            let store = MicDiagnosticStore()
            await store.record(makeEntry(result: "ok"))
            await store.record(makeEntry(result: "silent"))
            await store.record(makeEntry(result: "empty"))
            let count = await store.count
            #expect(count == 3)
        }

        @Test("Clear removes all entries")
        func clear() async {
            let store = MicDiagnosticStore()
            await store.record(makeEntry())
            await store.record(makeEntry())
            await store.clear()
            let count = await store.count
            #expect(count == 0)
        }
    }

    // MARK: - Eviction

    @Suite("eviction")
    struct EvictionTests {

        private func makeEntry(
            deviceName: String = "Mic",
            result: String = "ok"
        ) -> MicDiagnosticEntry {
            MicDiagnosticEntry(
                deviceName: deviceName,
                proximity: "near_field",
                ambientRMS: 0.001,
                peakRMS: 0.05,
                gain: 1.0,
                threshold: 0.005,
                duration: 1.0,
                latency: 0.5,
                result: result
            )
        }

        @Test("Default max is 10 entries")
        func defaultMax() async {
            let store = MicDiagnosticStore()
            for i in 0..<15 {
                await store.record(makeEntry(deviceName: "Mic \(i)"))
            }
            let count = await store.count
            #expect(count == 10)
        }

        @Test("Oldest entries are evicted first")
        func evictsOldest() async {
            let store = MicDiagnosticStore(maxEntries: 3)
            await store.record(makeEntry(deviceName: "First"))
            await store.record(makeEntry(deviceName: "Second"))
            await store.record(makeEntry(deviceName: "Third"))
            await store.record(makeEntry(deviceName: "Fourth"))

            let count = await store.count
            #expect(count == 3)

            let text = await store.formattedDiagnostics()
            #expect(!text.contains("\"First\""))
            #expect(text.contains("\"Second\""))
            #expect(text.contains("\"Third\""))
            #expect(text.contains("\"Fourth\""))
        }

        @Test("Custom maxEntries of 1 keeps only latest")
        func maxOne() async {
            let store = MicDiagnosticStore(maxEntries: 1)
            await store.record(makeEntry(deviceName: "Old"))
            await store.record(makeEntry(deviceName: "New"))

            let count = await store.count
            #expect(count == 1)

            let text = await store.formattedDiagnostics()
            #expect(!text.contains("\"Old\""))
            #expect(text.contains("\"New\""))
        }

        @Test("At exactly maxEntries, no eviction yet")
        func atCapacity() async {
            let store = MicDiagnosticStore(maxEntries: 3)
            await store.record(makeEntry(deviceName: "A"))
            await store.record(makeEntry(deviceName: "B"))
            await store.record(makeEntry(deviceName: "C"))

            let count = await store.count
            #expect(count == 3)

            let text = await store.formattedDiagnostics()
            #expect(text.contains("\"A\""))
            #expect(text.contains("\"B\""))
            #expect(text.contains("\"C\""))
        }
    }

    // MARK: - Formatted output

    @Suite("formattedDiagnostics")
    struct FormattedDiagnosticsTests {

        @Test("Empty store returns placeholder message")
        func emptyMessage() async {
            let store = MicDiagnosticStore()
            let text = await store.formattedDiagnostics()
            #expect(text == "No dictation sessions recorded yet.")
        }

        @Test("Header includes session count singular")
        func headerSingular() async {
            let store = MicDiagnosticStore()
            await store.record(
                MicDiagnosticEntry(
                    deviceName: "Mic",
                    proximity: "near_field",
                    ambientRMS: 0.001,
                    peakRMS: 0.05,
                    gain: 1.0,
                    threshold: 0.005,
                    duration: 1.0,
                    latency: 0.5,
                    result: "ok"
                ))
            let text = await store.formattedDiagnostics()
            #expect(text.contains("(1 session)"))
        }

        @Test("Header includes session count plural")
        func headerPlural() async {
            let store = MicDiagnosticStore()
            for _ in 0..<3 {
                await store.record(
                    MicDiagnosticEntry(
                        deviceName: "Mic",
                        proximity: "near_field",
                        ambientRMS: 0.001,
                        peakRMS: 0.05,
                        gain: 1.0,
                        threshold: 0.005,
                        duration: 1.0,
                        latency: 0.5,
                        result: "ok"
                    ))
            }
            let text = await store.formattedDiagnostics()
            #expect(text.contains("(3 sessions)"))
        }

        @Test("Header includes macOS version")
        func includesMacOS() async {
            let store = MicDiagnosticStore()
            await store.record(
                MicDiagnosticEntry(
                    deviceName: "Mic",
                    proximity: "near_field",
                    ambientRMS: 0.001,
                    peakRMS: 0.05,
                    gain: 1.0,
                    threshold: 0.005,
                    duration: 1.0,
                    latency: 0.5,
                    result: "ok"
                ))
            let text = await store.formattedDiagnostics()
            #expect(text.contains("macOS:"))
        }

        @Test("Header includes Mac model")
        func includesMacModel() async {
            let store = MicDiagnosticStore()
            await store.record(
                MicDiagnosticEntry(
                    deviceName: "Mic",
                    proximity: "near_field",
                    ambientRMS: 0.001,
                    peakRMS: 0.05,
                    gain: 1.0,
                    threshold: 0.005,
                    duration: 1.0,
                    latency: 0.5,
                    result: "ok"
                ))
            let text = await store.formattedDiagnostics()
            #expect(text.contains("Mac:"))
        }

        @Test("Session line includes all fields with correct formatting")
        func sessionLineFormat() async {
            let store = MicDiagnosticStore()
            await store.record(
                MicDiagnosticEntry(
                    deviceName: "MacBook Pro Microphone",
                    proximity: "far_field",
                    ambientRMS: 0.000300,
                    peakRMS: 0.045000,
                    gain: 12.0,
                    threshold: 0.001000,
                    duration: 2.5,
                    latency: 0.55,
                    result: "ok"
                ))

            let text = await store.formattedDiagnostics()

            #expect(text.contains("Session 1:"))
            #expect(text.contains("device=\"MacBook Pro Microphone\""))
            #expect(text.contains("proximity=far_field"))
            #expect(text.contains("ambient=0.000300"))
            #expect(text.contains("peak=0.045000"))
            #expect(text.contains("gain=12.0x"))
            #expect(text.contains("threshold=0.001000"))
            #expect(text.contains("duration=2.50s"))
            #expect(text.contains("latency=0.55s"))
            #expect(text.contains("result=ok"))
        }

        @Test("Multiple sessions are numbered sequentially")
        func sessionNumbering() async {
            let store = MicDiagnosticStore()
            for _ in 0..<3 {
                await store.record(
                    MicDiagnosticEntry(
                        deviceName: "Mic",
                        proximity: "near_field",
                        ambientRMS: 0.001,
                        peakRMS: 0.05,
                        gain: 1.0,
                        threshold: 0.005,
                        duration: 1.0,
                        latency: 0.5,
                        result: "ok"
                    ))
            }
            let text = await store.formattedDiagnostics()
            #expect(text.contains("Session 1:"))
            #expect(text.contains("Session 2:"))
            #expect(text.contains("Session 3:"))
        }

        @Test("Silent result is formatted correctly")
        func silentResult() async {
            let store = MicDiagnosticStore()
            await store.record(
                MicDiagnosticEntry(
                    deviceName: "AirPods",
                    proximity: "near_field",
                    ambientRMS: 0.000100,
                    peakRMS: 0.000050,
                    gain: 1.0,
                    threshold: 0.005000,
                    duration: 0,
                    latency: 0,
                    result: "silent"
                ))

            let text = await store.formattedDiagnostics()
            #expect(text.contains("result=silent"))
            #expect(text.contains("duration=0.00s"))
            #expect(text.contains("latency=0.00s"))
        }

        @Test("Empty result is formatted correctly")
        func emptyResult() async {
            let store = MicDiagnosticStore()
            await store.record(
                MicDiagnosticEntry(
                    deviceName: "Bose BT",
                    proximity: "near_field",
                    ambientRMS: 0.000200,
                    peakRMS: 0.009000,
                    gain: 1.0,
                    threshold: 0.005000,
                    duration: 1.8,
                    latency: 0.92,
                    result: "empty"
                ))

            let text = await store.formattedDiagnostics()
            #expect(text.contains("result=empty"))
        }

        @Test("Blank line separates header from sessions")
        func blankLineSeparator() async {
            let store = MicDiagnosticStore()
            await store.record(
                MicDiagnosticEntry(
                    deviceName: "Mic",
                    proximity: "near_field",
                    ambientRMS: 0.001,
                    peakRMS: 0.05,
                    gain: 1.0,
                    threshold: 0.005,
                    duration: 1.0,
                    latency: 0.5,
                    result: "ok"
                ))

            let text = await store.formattedDiagnostics()
            let lines = text.components(separatedBy: "\n")

            // Line 0: header, Line 1: FreeFlow version, Line 2: macOS, Line 3: Mac, Line 4: blank, Line 5: Session 1
            #expect(lines.count >= 6)
            #expect(lines[0].hasPrefix("FreeFlow Mic Diagnostics"))
            #expect(lines[1].hasPrefix("FreeFlow:"))
            #expect(lines[2].hasPrefix("macOS:"))
            #expect(lines[3].hasPrefix("Mac:"))
            #expect(lines[4] == "")
            #expect(lines[5].hasPrefix("Session 1:"))
        }

        @Test("Near-field gain 1.0 is formatted as 1.0x")
        func nearFieldGain() async {
            let store = MicDiagnosticStore()
            await store.record(
                MicDiagnosticEntry(
                    deviceName: "AirPods",
                    proximity: "near_field",
                    ambientRMS: 0.001,
                    peakRMS: 0.05,
                    gain: 1.0,
                    threshold: 0.005,
                    duration: 1.0,
                    latency: 0.5,
                    result: "ok"
                ))
            let text = await store.formattedDiagnostics()
            #expect(text.contains("gain=1.0x"))
        }

        @Test("Far-field high gain is formatted correctly")
        func farFieldHighGain() async {
            let store = MicDiagnosticStore()
            await store.record(
                MicDiagnosticEntry(
                    deviceName: "Blue Yeti",
                    proximity: "far_field",
                    ambientRMS: 0.000150,
                    peakRMS: 0.032000,
                    gain: 15.5,
                    threshold: 0.001000,
                    duration: 3.2,
                    latency: 0.62,
                    result: "ok"
                ))
            let text = await store.formattedDiagnostics()
            #expect(text.contains("gain=15.5x"))
        }
    }

    // MARK: - MicDiagnosticEntry

    @Suite("MicDiagnosticEntry")
    struct EntryTests {

        @Test("Timestamp defaults to now")
        func defaultTimestamp() {
            let before = Date()
            let entry = MicDiagnosticEntry(
                deviceName: "Mic",
                proximity: "near_field",
                ambientRMS: 0.001,
                peakRMS: 0.05,
                gain: 1.0,
                threshold: 0.005,
                duration: 1.0,
                latency: 0.5,
                result: "ok"
            )
            let after = Date()
            #expect(entry.timestamp >= before)
            #expect(entry.timestamp <= after)
        }

        @Test("All fields are stored correctly")
        func fieldsStored() {
            let entry = MicDiagnosticEntry(
                deviceName: "Test Device",
                proximity: "far_field",
                ambientRMS: 0.000300,
                peakRMS: 0.045000,
                gain: 12.0,
                threshold: 0.001000,
                duration: 2.5,
                latency: 0.55,
                result: "ok"
            )
            #expect(entry.deviceName == "Test Device")
            #expect(entry.proximity == "far_field")
            #expect(entry.ambientRMS == 0.000300)
            #expect(entry.peakRMS == 0.045000)
            #expect(entry.gain == 12.0)
            #expect(entry.threshold == 0.001000)
            #expect(entry.duration == 2.5)
            #expect(entry.latency == 0.55)
            #expect(entry.result == "ok")
        }
    }

    // MARK: - Clear then format

    @Test("Format after clear returns placeholder")
    func formatAfterClear() async {
        let store = MicDiagnosticStore()
        await store.record(
            MicDiagnosticEntry(
                deviceName: "Mic",
                proximity: "near_field",
                ambientRMS: 0.001,
                peakRMS: 0.05,
                gain: 1.0,
                threshold: 0.005,
                duration: 1.0,
                latency: 0.5,
                result: "ok"
            ))
        await store.clear()
        let text = await store.formattedDiagnostics()
        #expect(text == "No dictation sessions recorded yet.")
    }

    // MARK: - Mixed device types

    @Test("Mixed device types show correct per-session data")
    func mixedDevices() async {
        let store = MicDiagnosticStore()

        await store.record(
            MicDiagnosticEntry(
                deviceName: "MacBook Pro Microphone",
                proximity: "far_field",
                ambientRMS: 0.000300,
                peakRMS: 0.045000,
                gain: 12.0,
                threshold: 0.001000,
                duration: 2.5,
                latency: 0.55,
                result: "ok"
            ))

        await store.record(
            MicDiagnosticEntry(
                deviceName: "AirPods",
                proximity: "near_field",
                ambientRMS: 0.000100,
                peakRMS: 0.000050,
                gain: 1.0,
                threshold: 0.005000,
                duration: 0,
                latency: 0,
                result: "silent"
            ))

        await store.record(
            MicDiagnosticEntry(
                deviceName: "Blue Yeti",
                proximity: "far_field",
                ambientRMS: 0.000150,
                peakRMS: 0.032000,
                gain: 15.5,
                threshold: 0.001000,
                duration: 3.2,
                latency: 0.62,
                result: "ok"
            ))

        let text = await store.formattedDiagnostics()

        #expect(text.contains("(3 sessions)"))
        #expect(text.contains("Session 1:"))
        #expect(text.contains("Session 2:"))
        #expect(text.contains("Session 3:"))
        #expect(text.contains("device=\"MacBook Pro Microphone\""))
        #expect(text.contains("device=\"AirPods\""))
        #expect(text.contains("device=\"Blue Yeti\""))
    }

    // MARK: - Pipeline integration

    @Suite("Pipeline integration")
    struct PipelineIntegrationTests {

        /// Build a pipeline wired to a MicDiagnosticStore so we can
        /// verify entries are recorded for each dictation outcome.
        private func makePipeline(
            audioProvider: MockAudioProvider = MockAudioProvider(),
            batchProvider: MockBatchProvider = MockBatchProvider(),
            store: MicDiagnosticStore = MicDiagnosticStore()
        ) -> (DictationPipeline, MockAudioProvider, MockBatchProvider, MicDiagnosticStore) {
            let pipeline = DictationPipeline(
                audioProvider: audioProvider,
                contextProvider: MockAppContextProvider(),
                backend: .cloud(
                    realtime: MockStreamingProvider(),
                    fallback: batchProvider),
                textInjector: MockTextInjector(),
                coordinator: RecordingCoordinator(),
                micDiagnosticStore: store
            )
            return (pipeline, audioProvider, batchProvider, store)
        }

        private func activateAndWaitForCapture(
            _ pipeline: DictationPipeline,
            audioProvider: MockAudioProvider
        ) async {
            let previousReadyCount = audioProvider.captureReadyCount
            guard await pipeline.activate() != nil else {
                Issue.record("Pipeline activation was rejected")
                return
            }

            for _ in 0..<10_000 {
                if audioProvider.captureReadyCount > previousReadyCount {
                    return
                }
                await Task.yield()
            }
            Issue.record("Audio capture did not become ready")
        }

        @Test("Successful dictation records an 'ok' entry")
        func successRecordsOk() async {
            let audio = MockAudioProvider()
            audio.stubbedPeakRMS = 0.1
            audio.stubbedAmbientRMS = 0.001
            audio.stubbedMicProximity = .nearField

            let dictation = MockBatchProvider(stubbedText: "Hello world")
            let store = MicDiagnosticStore()
            let (pipeline, _, _, _) = makePipeline(
                audioProvider: audio,
                batchProvider: dictation,
                store: store
            )

            await activateAndWaitForCapture(pipeline, audioProvider: audio)
            await pipeline.complete()

            let count = await store.count
            #expect(count == 1)

            let text = await store.formattedDiagnostics()
            #expect(text.contains("result=ok"))
            #expect(text.contains("proximity=near_field"))
        }

        @Test("Silent press records a 'silent' entry with zero duration")
        func silentPressRecordsSilent() async {
            let audio = MockAudioProvider()
            // Peak below the early silence threshold (0.005 for near-field
            // with ambient calibration, or 0.001 for far-field).
            audio.stubbedPeakRMS = 0.0001
            audio.stubbedAmbientRMS = 0.0001
            audio.stubbedMicProximity = .farField

            let store = MicDiagnosticStore()
            let (pipeline, _, _, _) = makePipeline(
                audioProvider: audio,
                store: store
            )

            await activateAndWaitForCapture(pipeline, audioProvider: audio)
            await pipeline.complete()

            let count = await store.count
            #expect(count == 1)

            let text = await store.formattedDiagnostics()
            #expect(text.contains("result=silent"))
        }

        @Test("Empty dictation result records an 'empty' entry")
        func emptyResultRecordsEmpty() async {
            let audio = MockAudioProvider()
            audio.stubbedPeakRMS = 0.1
            audio.stubbedAmbientRMS = 0.001
            audio.stubbedMicProximity = .nearField

            // Server returns whitespace-only text.
            let dictation = MockBatchProvider(stubbedText: "   ")
            let store = MicDiagnosticStore()
            let (pipeline, _, _, _) = makePipeline(
                audioProvider: audio,
                batchProvider: dictation,
                store: store
            )

            await activateAndWaitForCapture(pipeline, audioProvider: audio)
            await pipeline.complete()

            let count = await store.count
            #expect(count == 1)

            let text = await store.formattedDiagnostics()
            #expect(text.contains("result=empty"))
        }

        @Test("Multiple dictations accumulate entries in order")
        func multipleSessionsAccumulate() async {
            let audio = MockAudioProvider()
            audio.stubbedPeakRMS = 0.1
            audio.stubbedAmbientRMS = 0.001
            audio.stubbedMicProximity = .nearField

            let dictation = MockBatchProvider(stubbedText: "First")
            let store = MicDiagnosticStore()
            let (pipeline, _, _, _) = makePipeline(
                audioProvider: audio,
                batchProvider: dictation,
                store: store
            )

            // First dictation: success.
            await activateAndWaitForCapture(pipeline, audioProvider: audio)
            await pipeline.complete()

            // Second dictation: success with different text.
            dictation.stubbedText = "Second"
            await activateAndWaitForCapture(pipeline, audioProvider: audio)
            await pipeline.complete()

            let count = await store.count
            #expect(count == 2)

            let text = await store.formattedDiagnostics()
            #expect(text.contains("Session 1:"))
            #expect(text.contains("Session 2:"))
        }

        @Test("Far-field mic records far_field proximity and gain")
        func farFieldProximityAndGain() async {
            let audio = MockAudioProvider()
            audio.stubbedPeakRMS = 0.1
            audio.stubbedAmbientRMS = 0.001
            audio.stubbedMicProximity = .farField

            let dictation = MockBatchProvider(stubbedText: "test")
            let store = MicDiagnosticStore()
            let (pipeline, _, _, _) = makePipeline(
                audioProvider: audio,
                batchProvider: dictation,
                store: store
            )

            await activateAndWaitForCapture(pipeline, audioProvider: audio)
            await pipeline.complete()

            let count = await store.count
            #expect(count == 1)

            let text = await store.formattedDiagnostics()
            #expect(text.contains("proximity=far_field"))
            // MockAudioProvider uses default gainFactor (1.0) from
            // the protocol extension.
            #expect(text.contains("gain=1.0x"))
        }

        @Test("Pipeline without store does not crash")
        func noStoreSafe() async {
            let audio = MockAudioProvider()
            let pipeline = DictationPipeline(
                audioProvider: audio,
                contextProvider: MockAppContextProvider(),
                backend: .cloud(
                    realtime: MockStreamingProvider(),
                    fallback: MockBatchProvider(stubbedText: "safe")),
                textInjector: MockTextInjector(),
                coordinator: RecordingCoordinator()
            )

            await activateAndWaitForCapture(pipeline, audioProvider: audio)
            await pipeline.complete()
            // No crash, no store — just verifying the nil path is safe.
        }
    }
}
