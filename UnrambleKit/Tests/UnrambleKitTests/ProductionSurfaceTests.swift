import Foundation
import Testing

@testable import UnrambleKit

@Suite("Production source ownership")
struct ProductionSurfaceTests {

    @Test("Production target contains no test doubles or orphan permission provider")
    func excludesTestOnlyTypes() throws {
        let sources = try productionSwiftSources()
        let relativePaths = sources.map(relativeProductionPath)

        #expect(!relativePaths.contains { $0.hasPrefix("Mocks/") })
        #expect(!relativePaths.contains("Services/AccessibilityPermissionProvider.swift"))
    }

    @Test("Release build collects no raw speech or dictated content")
    func excludesRawContentCollection() throws {
        // Scan only what a Release build compiles: strip `#if DEBUG` regions so
        // the debug-only diagnostics (the sample-capture hook, the polish/unit
        // content traces) may live in the source yet never reach the shipping
        // app. Their markers must not appear outside a `#if DEBUG` block.
        let corpus = try (productionSwiftSources() + applicationSwiftSources())
            .map { try releaseVisibleSource(of: $0) }
            .joined(separator: "\n")

        let forbiddenMarkers = [
            "Application Support/Unramble/recordings",
            "/tmp/unramble-stt-confidence",
            "/tmp/unramble-stt-confidence.log",
            "/tmp/unramble-unit-trace",
            "[[POLISH]]",
            "[[UNIT]]",
        ]
        for marker in forbiddenMarkers {
            #expect(!corpus.contains(marker), "Release source contains \(marker)")
        }
    }

    @Test("The release-visibility filter strips debug regions, not everything")
    func releaseVisibilityFilterHasTeeth() throws {
        // The capture hook's marker is in the raw source but must be gone once
        // `#if DEBUG` regions are stripped — proving the filter removes debug
        // code rather than trivially passing everything. The surrounding
        // signature must survive so it isn't over-stripping.
        let url = packageRoot.appendingPathComponent(
            "Sources/UnrambleKit/Services/DictationPipeline.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let visible = try releaseVisibleSource(of: url)
        #expect(raw.contains("Application Support/Unramble/recordings"))
        #expect(!visible.contains("Application Support/Unramble/recordings"))
        #expect(visible.contains("func saveCapturedSample"))
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

    /// Return the file's source with every `#if DEBUG ... #endif` region
    /// removed, so a check sees only what a Release build compiles. Handles a
    /// nested `#if` inside a DEBUG region; assumes the DEBUG regions carry no
    /// `#else` (the diagnostics add code, they don't replace it).
    private func releaseVisibleSource(of url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        var kept: [Substring] = []
        var inDebug = false
        var nesting = 0
        for line in source.split(
            separator: "\n", omittingEmptySubsequences: false)
        {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if !inDebug {
                if trimmed.hasPrefix("#if DEBUG") {
                    inDebug = true
                    nesting = 0
                } else {
                    kept.append(line)
                }
            } else if trimmed.hasPrefix("#if") {
                nesting += 1
            } else if trimmed.hasPrefix("#endif") {
                if nesting > 0 { nesting -= 1 } else { inDebug = false }
            }
        }
        return kept.joined(separator: "\n")
    }

    private func productionSwiftSources() throws -> [URL] {
        try swiftSources(
            under: packageRoot.appendingPathComponent("Sources/UnrambleKit"))
    }

    private func applicationSwiftSources() throws -> [URL] {
        try swiftSources(
            under: packageRoot.deletingLastPathComponent()
                .appendingPathComponent("UnrambleApp/Sources"))
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
                .appendingPathComponent("Sources/UnrambleKit")
                .appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private func relativeProductionPath(_ url: URL) -> String {
        let prefix = packageRoot
            .appendingPathComponent("Sources/UnrambleKit")
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
