import Foundation
import Testing

@testable import UnrambleKit

// ---------------------------------------------------------------------------
// Latency benchmarks for the OpenAI Realtime API streaming provider.
//
// Measures:
//   * startStreaming duration (connection open + session.update)
//   * sendAudio latency per chunk
//   * finishStreaming duration (commit → polished response)
//   * Total session time
//
// Gated by UNRAMBLE_TEST_OPENAI_BENCH=1 since they hit the real API and
// take a few seconds each. Run with:
//   OPENAI_API_KEY=... UNRAMBLE_TEST_OPENAI=1 UNRAMBLE_TEST_OPENAI_BENCH=1 \
//     swift test --filter "OpenAIStreamingBenchmark"
// ---------------------------------------------------------------------------

private func silentPCM(seconds: Double = 0.5, sampleRate: Int = 16000) -> Data {
    let sampleCount = Int(seconds * Double(sampleRate))
    return Data(count: sampleCount * 2)
}

/// Split a PCM buffer into chunks of `chunkSizeMs` milliseconds.
private func chunked(_ pcm: Data, chunkSizeMs: Int, sampleRate: Int = 16000) -> [Data] {
    let samplesPerChunk = (sampleRate * chunkSizeMs) / 1000
    let bytesPerChunk = samplesPerChunk * 2
    var chunks: [Data] = []
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + bytesPerChunk, pcm.count)
        chunks.append(pcm.subdata(in: offset..<end))
        offset = end
    }
    return chunks
}

@Suite(
    "OpenAIStreamingProvider – benchmark",
    .disabled(
        if: ProcessInfo.processInfo.environment["UNRAMBLE_TEST_OPENAI"] != "1"
            || ProcessInfo.processInfo.environment["UNRAMBLE_TEST_OPENAI_BENCH"] != "1"))
struct OpenAIStreamingBenchmarkTests {

    private var apiKey: String {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    /// Measure a single full session and print a breakdown.
    @Test("bench: single session breakdown")
    func singleSessionBreakdown() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let provider = OpenAIStreamingProvider(apiKey: apiKey)

        let pcm = silentPCM(seconds: 1.0)
        let chunks = chunked(pcm, chunkSizeMs: 100)
        let sessionID = DictationSessionID()

        let t0 = Date()
        try await provider.startStreaming(
            sessionID: sessionID,
            context: AppContext.empty,
            language: "en",
            micProximity: .nearField)
        let tStart = Date()

        for chunk in chunks {
            try await provider.sendAudio(chunk, sessionID: sessionID)
        }
        let tSent = Date()

        _ = try await provider.finishStreaming(sessionID: sessionID)
        let tFinish = Date()

        print("""
            ── OpenAIStreamingProvider single session breakdown ──
            startStreaming:  \(String(format: "%.3f", tStart.timeIntervalSince(t0)))s
            sendAudio total: \(String(format: "%.3f", tSent.timeIntervalSince(tStart)))s (\(chunks.count) chunks)
            finishStreaming: \(String(format: "%.3f", tFinish.timeIntervalSince(tSent)))s
            total:           \(String(format: "%.3f", tFinish.timeIntervalSince(t0)))s
            ─────────────────────────────────────────────────────
            """)
    }

    /// Run N sequential sessions and report min/p50/p95/max for each phase.
    @Test("bench: 5 sequential sessions")
    func fiveSequentialSessions() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }

        let provider = OpenAIStreamingProvider(apiKey: apiKey)

        let pcm = silentPCM(seconds: 1.0)
        let chunks = chunked(pcm, chunkSizeMs: 100)
        let runs = 5

        var startTimes: [Double] = []
        var sendTimes: [Double] = []
        var finishTimes: [Double] = []
        var totalTimes: [Double] = []

        for _ in 0..<runs {
            let sessionID = DictationSessionID()
            let t0 = Date()
            try await provider.startStreaming(
                sessionID: sessionID,
                context: AppContext.empty,
                language: "en",
                micProximity: .nearField)
            let tStart = Date()

            for chunk in chunks {
                try await provider.sendAudio(chunk, sessionID: sessionID)
            }
            let tSent = Date()

            _ = try await provider.finishStreaming(sessionID: sessionID)
            let tFinish = Date()

            startTimes.append(tStart.timeIntervalSince(t0))
            sendTimes.append(tSent.timeIntervalSince(tStart))
            finishTimes.append(tFinish.timeIntervalSince(tSent))
            totalTimes.append(tFinish.timeIntervalSince(t0))
        }

        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            let p50 = sorted[sorted.count / 2]
            let min = sorted.first!
            let max = sorted.last!
            let mean = values.reduce(0, +) / Double(values.count)
            return String(format: "min=%.3f p50=%.3f mean=%.3f max=%.3f",
                min, p50, mean, max)
        }

        print("""
            ── OpenAIStreamingProvider \(runs) sessions (1s silent PCM) ──
            startStreaming:  \(stats(startTimes))
            sendAudio total: \(stats(sendTimes))
            finishStreaming: \(stats(finishTimes))
            total:           \(stats(totalTimes))
            ──────────────────────────────────────────────────────────────
            """)
    }

    /// Run N sessions with a realistic gap between them so the backup
    /// connection has time to warm up. This better reflects actual
    /// user behavior than the tight back-to-back loop.
    @Test("bench: 5 sessions with 1.5s gap")
    func fiveSessionsWithGap() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }

        let provider = OpenAIStreamingProvider(apiKey: apiKey)

        let pcm = silentPCM(seconds: 1.0)
        let chunks = chunked(pcm, chunkSizeMs: 100)
        let runs = 5

        var startTimes: [Double] = []
        var sendTimes: [Double] = []
        var finishTimes: [Double] = []
        var totalTimes: [Double] = []

        for i in 0..<runs {
            if i > 0 {
                // Let the backup warm up between sessions.
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }

            let sessionID = DictationSessionID()
            let t0 = Date()
            try await provider.startStreaming(
                sessionID: sessionID,
                context: AppContext.empty,
                language: "en",
                micProximity: .nearField)
            let tStart = Date()

            for chunk in chunks {
                try await provider.sendAudio(chunk, sessionID: sessionID)
            }
            let tSent = Date()

            _ = try await provider.finishStreaming(sessionID: sessionID)
            let tFinish = Date()

            startTimes.append(tStart.timeIntervalSince(t0))
            sendTimes.append(tSent.timeIntervalSince(tStart))
            finishTimes.append(tFinish.timeIntervalSince(tSent))
            totalTimes.append(tFinish.timeIntervalSince(t0))
        }

        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            let p50 = sorted[sorted.count / 2]
            let min = sorted.first!
            let max = sorted.last!
            let mean = values.reduce(0, +) / Double(values.count)
            return String(format: "min=%.3f p50=%.3f mean=%.3f max=%.3f",
                min, p50, mean, max)
        }

        print("""
            ── OpenAIStreamingProvider \(runs) sessions with 1.5s gap (warm backup) ──
            startStreaming:  \(stats(startTimes))
            sendAudio total: \(stats(sendTimes))
            finishStreaming: \(stats(finishTimes))
            total:           \(stats(totalTimes))
            ───────────────────────────────────────────────────────────────────────
            """)
    }
}
