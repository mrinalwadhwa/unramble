import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Production source ownership")
struct ProductionSurfaceTests {

    @Test("Production target contains no test doubles or orphan permission provider")
    func excludesTestOnlyTypes() throws {
        let sources = try productionSwiftSources()
        let relativePaths = sources.map(relativeProductionPath)

        #expect(!relativePaths.contains { $0.hasPrefix("Mocks/") })
        #expect(!relativePaths.contains("Services/AccessibilityPermissionProvider.swift"))
    }

    @Test("Production target contains no raw speech or transcript collectors")
    func excludesRawContentCollection() throws {
        let corpus = try (productionSwiftSources() + applicationSwiftSources())
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        let forbiddenMarkers = [
            "/tmp/freeflow-collect",
            "/tmp/freeflow-samples",
            "/tmp/freeflow-stt-confidence",
            "/tmp/freeflow-stt-confidence.log",
        ]
        for marker in forbiddenMarkers {
            #expect(!corpus.contains(marker), "production source contains \(marker)")
        }
    }

    @Test("Production streaming surface is session scoped")
    func streamingSurfaceIsSessionScoped() throws {
        let protocolSource = try source("Protocols/StreamingDictationProviding.swift")
        let localSource = try source("Services/LocalStreamingProvider.swift")

        #expect(!protocolSource.contains("setChunkHandler"))
        #expect(!protocolSource.contains("func startStreaming(context:"))
        #expect(!protocolSource.contains("func sendAudio(_ pcmData: Data) async throws"))
        #expect(!protocolSource.contains("func finishStreaming() async throws"))
        #expect(!localSource.contains("func replay("))
        #expect(!localSource.contains("lastRawTranscript"))
        #expect(!localSource.contains("lastPolishedTranscript"))
    }

    @Test("Nemotron exposes only incremental recognition")
    func nemotronHasNoBatchTestFacade() throws {
        let sttSource = try source("Engines/LocalSTTEngine.swift")
        let nemotronSource = try source("Engines/NemotronEngine.swift")

        #expect(!sttSource.contains("func transcribe(audio:"))
        #expect(!nemotronSource.contains("func transcribe(audio:"))
        #expect(!nemotronSource.contains("func transcribeStreaming(audio:"))
        #expect(!nemotronSource.contains("public final class NemotronStreamingState"))
    }

    @Test("Release logging retains no arbitrary message history")
    func releaseLoggingIsNonRetaining() throws {
        let logSource = try source("Services/Log.swift")

        #expect(logSource.contains("#if DEBUG"))
        #expect(!logSource.contains("formattedHistory"))
        #expect(!logSource.contains("private static var entries"))
    }

    @Test("Core dictation logs contain metadata rather than dictated content")
    func coreLogsAreContentFree() throws {
        let cloudSource = try source("Services/OpenAIStreamingProvider.swift")
        let pipelineSource = try source("Services/DictationPipeline.swift")

        #expect(!cloudSource.contains("transcript.prefix"))
        #expect(!cloudSource.contains("realtime-polished"))
        #expect(!cloudSource.contains("session.update JSON"))
        #expect(!cloudSource.contains("raw response.done"))
        #expect(!cloudSource.contains("var error: String?"))
        #expect(!pipelineSource.contains("injecting text: \""))
        #expect(!pipelineSource.contains("local polished: \""))
    }

    @Test("Microphone telemetry has no arbitrary content fields")
    func microphoneTelemetryIsContentFree() throws {
        let diagnosticsSource = try source("Services/MicDiagnosticStore.swift")

        #expect(!diagnosticsSource.contains("deviceName"))
        #expect(!diagnosticsSource.contains("result: String"))
        #expect(diagnosticsSource.contains("maximumCapacity"))
    }

    private func productionSwiftSources() throws -> [URL] {
        try swiftSources(
            under: packageRoot.appendingPathComponent("Sources/FreeFlowKit"))
    }

    private func applicationSwiftSources() throws -> [URL] {
        try swiftSources(
            under: packageRoot.deletingLastPathComponent()
                .appendingPathComponent("FreeFlowApp/Sources"))
    }

    private func swiftSources(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SurfaceFailure.unreadableDirectory(root.path)
        }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "swift" else {
                return nil
            }
            return url
        }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/FreeFlowKit")
                .appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private func relativeProductionPath(_ url: URL) -> String {
        let prefix = packageRoot
            .appendingPathComponent("Sources/FreeFlowKit")
            .path + "/"
        return String(url.path.dropFirst(prefix.count))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum SurfaceFailure: Error {
    case unreadableDirectory(String)
}
