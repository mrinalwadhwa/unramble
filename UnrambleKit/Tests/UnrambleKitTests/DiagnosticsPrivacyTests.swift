import Foundation
import Testing

@testable import UnrambleKit

@Suite("Diagnostics privacy")
struct DiagnosticsPrivacyTests {

    @Test("Issue report excludes arbitrary debug messages")
    func issueReportExcludesDebugMessages() throws {
        let secret = "dictated-secret-\(UUID().uuidString)"
        Log.debug(secret)

        let report = try #require(IssueDiagnostics.issueURL())

        #expect(!report.diagnostics.contains(secret))
        #expect(!report.url.absoluteString.contains(secret))
    }

    @Test("Release logging does not evaluate message expressions")
    func releaseLoggingDoesNotEvaluateMessages() {
        #if !DEBUG
            var evaluationCount = 0
            func message() -> String {
                evaluationCount += 1
                return "content"
            }

            Log.debug(message())

            #expect(evaluationCount == 0)
        #endif
    }

    @Test("Mic report contains no device-name field or arbitrary outcome")
    func micReportIsContentFree() async {
        let store = MicDiagnosticStore()
        await store.record(
            MicDiagnosticEntry(
                proximity: .nearField,
                ambientRMS: 0.001,
                peakRMS: 0.1,
                gain: 1,
                threshold: 0.005,
                duration: 2,
                latency: 1,
                result: .successRealtime))

        let report = await store.formattedDiagnostics()

        #expect(!report.contains("device="))
        #expect(report.contains("result=ok_realtime"))
    }

    @Test("Mic telemetry capacity has a fixed upper bound")
    func micTelemetryCapacityIsCapped() async {
        let store = MicDiagnosticStore(maxEntries: 10_000)
        for _ in 0..<150 {
            await store.record(
                MicDiagnosticEntry(
                    proximity: .farField,
                    ambientRMS: 0.001,
                    peakRMS: 0.1,
                    gain: 2,
                    threshold: 0.005,
                    duration: 2,
                    latency: 1,
                    result: .successLocal))
        }

        #expect(await store.count == MicDiagnosticStore.maximumCapacity)
    }
}
