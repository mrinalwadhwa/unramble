import Foundation
import Testing

@testable import FreeFlowKit

// Explicit developer-only collection harness. The output contains raw speech:
// keep it out of source control and review it before sharing. To replay a saved
// file through the local streaming pipeline, see StreamingReplayTests.swift.
//
// Enable for one test process with FREEFLOW_TEST_SAMPLE_COLLECTION=1. Set
// FREEFLOW_SAMPLE_DIR to an existing output directory. Optionally set
// FREEFLOW_SAMPLE_DURATION to a positive number of seconds; capture defaults
// to 10 seconds.
@Suite("Developer microphone WAV collector")
struct MicrophoneWAVCollectorTests {
    private static let gateVariable = "FREEFLOW_TEST_SAMPLE_COLLECTION"
    private static let outputDirectoryVariable = "FREEFLOW_SAMPLE_DIR"
    private static let durationVariable = "FREEFLOW_SAMPLE_DURATION"

    enum Failure: Error, Equatable {
        case missingOutputDirectory(String)
        case invalidDuration(String)
        case emptyCapture
        case couldNotWrite(String)
    }

    @Test("Collect microphone speech as an encoded WAV")
    func collect() async throws {
        guard ProcessInfo.processInfo.environment[Self.gateVariable] == "1" else {
            return
        }

        let outputDirectory = try Self.outputDirectory()
        let duration = try Self.captureDuration()
        let audio = AudioCaptureProvider()
        defer { audio.shutdown() }

        let buffer: AudioBuffer
        do {
            try await audio.startRecording()
            try await Task.sleep(for: .seconds(duration))
            audio.closeRecordingBoundary()
            buffer = try await audio.stopRecording()
        } catch {
            audio.closeRecordingBoundary()
            _ = try? await audio.stopRecording()
            throw error
        }

        guard !buffer.data.isEmpty else { throw Failure.emptyCapture }
        let output = outputDirectory.appendingPathComponent(
            "microphone-\(Self.timestamp())-\(UUID().uuidString.prefix(8)).wav")
        try Self.writePrivateWAV(buffer.data, to: output)
        print("Captured raw speech WAV: \(output.path)")
    }

    @Test("Collected WAV files are owner-readable only")
    func privateFilePermissions() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "freeflow-private-wav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }

        try Self.writePrivateWAV(Data("RIFF-test".utf8), to: output)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: output.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    private static func outputDirectory() throws -> URL {
        guard
            let path = ProcessInfo.processInfo.environment[outputDirectoryVariable],
            !path.isEmpty
        else {
            throw Failure.missingOutputDirectory(outputDirectoryVariable)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw Failure.missingOutputDirectory(path)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func captureDuration() throws -> TimeInterval {
        guard let value = ProcessInfo.processInfo.environment[durationVariable]
        else {
            return 10
        }
        guard let duration = TimeInterval(value), duration.isFinite, duration > 0
        else {
            throw Failure.invalidDuration(value)
        }
        return duration
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func writePrivateWAV(_ data: Data, to output: URL) throws {
        let temporary = output.deletingLastPathComponent().appendingPathComponent(
            ".\(output.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let created = FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600])
        guard created else { throw Failure.couldNotWrite(temporary.path) }
        do {
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            throw Failure.couldNotWrite(output.path)
        }
    }
}
