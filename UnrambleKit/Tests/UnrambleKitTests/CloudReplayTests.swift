import Foundation
import Testing

@testable import UnrambleKit

// Replay a directory of saved WAVs through the REAL cloud dictation path —
// OpenAI Realtime streaming STT (gpt-realtime-2.1) plus the on-connection cloud
// polish — and record the raw transcript and polished output per file. This is
// the cloud analogue of StreamingReplay (local on-device path), so the two can
// be compared file by file.
//
// Hits the live OpenAI API, so it is gated and inert unless explicitly enabled:
//   /tmp/unramble-test-cloud-replay   must exist to run at all
//   OPENAI_API_KEY                    must be set in the environment
//   UNRAMBLE_TEST_OPENAI=1            opens the test bundle's network guard
//
// Run via swift test (forwards environment; no Metal needed):
//   touch /tmp/unramble-test-cloud-replay
//   echo <wavdir> >/tmp/unramble-replay-dir
//   OPENAI_API_KEY=sk-... UNRAMBLE_TEST_OPENAI=1 \
//     swift test --filter CloudReplay
//
// Inputs (flag files, matching StreamingReplay):
//   /tmp/unramble-replay-dir    directory of sample WAVs (required)
//   /tmp/unramble-replay-only   a single WAV basename to replay alone
//
// Output: /tmp/unramble-cloud-replay.log — one [[CLOUD]] JSON record per WAV
//   {"wav","items","secs","raw","out"} (or {"wav","error"} on failure).

@Suite("Cloud replay", .serialized)
struct CloudReplay {

    @Test("Replay saved WAVs through the cloud path")
    func replay() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/unramble-test-cloud-replay")
        else { return }

        let readFlag = { (path: String) -> String? in
            guard let s = try? String(contentsOfFile: path, encoding: .utf8)
            else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            !apiKey.isEmpty
        else {
            Issue.record("set OPENAI_API_KEY to replay through the cloud path")
            return
        }
        guard let dirPath = readFlag("/tmp/unramble-replay-dir") else {
            Issue.record(
                "set /tmp/unramble-replay-dir to a directory of sample WAVs")
            return
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let only = readFlag("/tmp/unramble-replay-only")

        var wavs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))
            ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        if let only { wavs = wavs.filter { $0 == only } }
        guard !wavs.isEmpty else {
            Issue.record("no matching WAVs under \(dir.path)")
            return
        }

        let log = CloudReplayLog(path: "/tmp/unramble-cloud-replay.log")
        let realtimeModel = OpenAIStreamingProvider.defaultRealtimeModel
        let sttModel = "gpt-4o-mini-transcribe"
        log.log(
            "=== cloud replay (\(wavs.count) files, model=\(realtimeModel), "
                + "policy=default) ===")

        for name in wavs {
            Log.debug("[[WAV]] \(name)")
            let started = Date()
            do {
                let data = try Data(contentsOf: dir.appendingPathComponent(name))
                let fixture = try WAVFixture(data: data)

                let recorder = CloudReplayRecorder()
                let provider = OpenAIStreamingProvider(
                    apiKeyProvider: { apiKey },
                    realtimeModel: realtimeModel,
                    sttModel: sttModel,
                    commitPolicy: RealtimeCommitPolicy(),
                    maxUnresolvedItems: 2,
                    evidenceObserver: { await recorder.record($0) })
                let sessionID = DictationSessionID()

                do {
                    try await provider.startStreaming(
                        sessionID: sessionID,
                        context: .empty,
                        language: "en",
                        micProximity: .nearField)
                    for chunk in fixture.pcm.replayChunks(maximumByteCount: 4_096) {
                        try await provider.sendAudio(chunk, sessionID: sessionID)
                    }
                    let polished = try await provider.finishStreaming(
                        sessionID: sessionID)
                    let snapshots = await recorder.snapshots()
                    await provider.disconnect()

                    let raw = snapshots.last?.items
                        .map(\.transcript)
                        .joined(separator: " ") ?? ""
                    let items = snapshots.last?.items.count ?? 0
                    let secs = Date().timeIntervalSince(started)
                    log.record(
                        wav: name, items: items, secs: secs, raw: raw,
                        out: polished)
                } catch {
                    await provider.disconnect()
                    throw error
                }
            } catch {
                log.recordError(wav: name, error: "\(error)")
            }
        }
    }
}

/// Serialized recorder for Realtime evidence snapshots (mirrors the live
/// harness's recorder; the last snapshot holds the full committed item set).
private actor CloudReplayRecorder {
    private var values: [OpenAIRealtimeCommitSession.EvidenceSnapshot] = []
    func record(_ value: OpenAIRealtimeCommitSession.EvidenceSnapshot) {
        values.append(value)
    }
    func snapshots() -> [OpenAIRealtimeCommitSession.EvidenceSnapshot] { values }
}

/// Append-only line logger writing one record per WAV.
private final class CloudReplayLog {
    private let handle: FileHandle?
    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }
    func log(_ message: String) {
        write(message + "\n")
    }
    func record(wav: String, items: Int, secs: Double, raw: String, out: String) {
        emit([
            "wav": wav, "items": items,
            "secs": (secs * 100).rounded() / 100,
            "raw": raw, "out": out,
        ])
    }
    func recordError(wav: String, error: String) {
        emit(["wav": wav, "error": error])
    }
    private func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.withoutEscapingSlashes]),
            let json = String(data: data, encoding: .utf8)
        else { return }
        let line = "[[CLOUD]] " + json
        write(line + "\n")
        Log.debug(line)
    }
    private func write(_ s: String) {
        guard let handle, let d = s.data(using: .utf8) else { return }
        handle.seekToEndOfFile()
        handle.write(d)
    }
}

private extension Data {
    func replayChunks(maximumByteCount: Int) -> [Data] {
        precondition(maximumByteCount > 0)
        var result: [Data] = []
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + maximumByteCount, count)
            result.append(subdata(in: offset..<end))
            offset = end
        }
        return result
    }
}
