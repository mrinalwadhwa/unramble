import AVFoundation
import Foundation
import MLX
import MLXAudioTTS
import MLXLMCommon

#if canImport(HuggingFace)
    import HuggingFace
#endif

/// Speaks read-aloud scripts through the local Kokoro MLX voice.
///
/// The model and its English G2P resources load lazily from the app's
/// verified model pack on the first speak; nothing downloads at runtime.
/// Scripts synthesize in sentence chunks so playback of the first chunk
/// overlaps generation of the rest, keeping first audio near the warm
/// per-chunk generation time instead of the whole script's. Stopping
/// silences playback immediately and cancels remaining generation at its
/// next cancellation checkpoint.
public final class KokoroSpeechSynthesizer: SpeechSynthesizing,
    @unchecked Sendable
{

    private let modelDirectory: URL
    private let g2pResourcesDirectory: URL
    private let voice: String
    private let speed: Float
    private let farEndHub: FarEndPlaybackHub?

    private let lock = NSLock()
    private var loadTask: Task<KokoroModel, Error>?
    private var speechTask: Task<Void, Never>?
    private var activePlayback: PCMChunkPlayback?

    public init(
        modelDirectory: URL,
        g2pResourcesDirectory: URL,
        voice: String = "af_heart",
        speed: Float = 1.2,
        farEndHub: FarEndPlaybackHub? = nil
    ) {
        self.modelDirectory = modelDirectory
        self.g2pResourcesDirectory = g2pResourcesDirectory
        self.voice = voice
        self.speed = speed
        self.farEndHub = farEndHub
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // One utterance at a time; a straggling session must never speak
        // over its replacement.
        stopSpeaking()

        let task = Task { await self.run(text: trimmed) }
        lock.withLock { speechTask = task }
        await task.value
        lock.withLock {
            if speechTask == task {
                speechTask = nil
            }
        }
    }

    public func stopSpeaking() {
        let (task, playback): (Task<Void, Never>?, PCMChunkPlayback?) =
            lock.withLock {
                let stoppedTask = speechTask
                speechTask = nil
                let stoppedPlayback = activePlayback
                activePlayback = nil
                return (stoppedTask, stoppedPlayback)
            }
        task?.cancel()
        playback?.stop()
    }

    // MARK: - Session

    private func run(text: String) async {
        do {
            let model = try await loadedModel()
            try Task.checkCancellation()

            let playback = PCMChunkPlayback(
                sampleRate: 24_000, farEndHub: farEndHub)
            lock.withLock { activePlayback = playback }
            defer {
                lock.withLock {
                    if activePlayback === playback {
                        activePlayback = nil
                    }
                }
            }

            try await Self.scheduleSpeech(text, into: playback) { chunk in
                let audio = try await model.generate(
                    text: chunk,
                    voice: voice,
                    refAudio: nil,
                    refText: nil,
                    language: nil,
                    generationParameters: GenerateParameters())
                return audio.asArray(Float.self)
            }
            await playback.drain()
        } catch is CancellationError {
            // Stopped; playback was silenced by stopSpeaking.
        } catch {
            Log.debug("[KokoroTTS] Speech failed: \(error)")
        }
    }

    /// Keep paragraph timing in the audio queue so generation of the next
    /// chunk can overlap playback, including the pause.
    static func scheduleSpeech(
        _ text: String,
        into playback: PCMChunkPlayback,
        generate: (String) async throws -> [Float]
    ) async throws {
        let script = KokoroTextNormalizer.normalize(text)
        var hasScheduledAudio = false
        var pausePending = false
        let chunks = KokoroSpeechChunker.paragraphChunks(from: script)
        let diagnosticID = UUID().uuidString
        Log.debug(
            "[KokoroTTS] run=\(diagnosticID) normalized "
                + SpeechDiagnostics.textStructure(script)
                + " chunks=\(chunks.count) paragraphBreaks=\(chunks.filter(\.pauseAfter).count)")
        var pauseCount = 0
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let samples = try await generate(chunk.text)
            try Task.checkCancellation()
            Log.debug(
                "[KokoroTTS] run=\(diagnosticID) chunk=\(index + 1) "
                    + "chars=\(chunk.text.count) frames=\(samples.count) "
                    + "paragraphEnd=\(chunk.pauseAfter)")
            if !samples.isEmpty {
                if pausePending {
                    pauseCount += 1
                    try playback.scheduleSilence(
                        duration: 0.3,
                        diagnosticLabel: "run=\(diagnosticID) pause=\(pauseCount) beforeChunk=\(index + 1)")
                }
                try playback.schedule(samples: samples)
                hasScheduledAudio = true
                pausePending = false
            }
            // A boundary belongs to the text even when its final chunk
            // produces no audio. Queue silence only once more speech exists.
            if chunk.pauseAfter && hasScheduledAudio {
                pausePending = true
            }
        }
        Log.debug("[KokoroTTS] run=\(diagnosticID) schedulingFinished pauses=\(pauseCount)")
    }

    private func loadedModel() async throws -> KokoroModel {
        let task: Task<KokoroModel, Error> = lock.withLock {
            if let loadTask {
                return loadTask
            }
            let modelDirectory = modelDirectory
            let g2pDirectory = g2pResourcesDirectory
            let speed = speed
            let created = Task { () throws -> KokoroModel in
                try KokoroG2PResourceInstaller.install(
                    from: g2pDirectory,
                    intoHubCacheDirectory: HubCache.default.cacheDirectory)
                let processor = MisakiTextProcessor()
                try await processor.prepare()
                let model = try await KokoroModel.fromModelDirectory(
                    modelDirectory, textProcessor: processor)
                model.speed = speed
                return model
            }
            loadTask = created
            return created
        }
        return try await task.value
    }

    deinit {
        speechTask?.cancel()
        activePlayback?.stop()
    }
}
