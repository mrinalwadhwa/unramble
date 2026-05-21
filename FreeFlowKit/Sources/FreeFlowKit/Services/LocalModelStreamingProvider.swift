import Foundation

/// On-device streaming dictation using a local STT engine.
///
/// Accumulate PCM audio chunks during recording, then batch-transcribe
/// via the `LocalSTTEngine` when the session ends. Same approach as
/// `SpeechAnalyzerStreamingProvider` — the engine does not support
/// true streaming, so audio is buffered and transcribed on
/// `finishStreaming()`.
public final class LocalModelStreamingProvider: StreamingDictationProviding,
    @unchecked Sendable
{

    // MARK: - Configuration

    private let sttEngine: any LocalSTTEngine
    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String

    // MARK: - State (guarded by lock)

    private let lock = NSLock()
    private var accumulatedAudio = Data()

    // MARK: - Init

    public init(
        sttEngine: any LocalSTTEngine,
        polishChatClient: (any PolishChatClient)?,
        polishModel: String = PolishPipeline.polishModel
    ) {
        self.sttEngine = sttEngine
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
    }

    // MARK: - StreamingDictationProviding

    public var uncommittedAudioDuration: TimeInterval {
        // 16 kHz, 16-bit mono = 32,000 bytes/sec.
        let bytes = lock.withLock { accumulatedAudio.count }
        return Double(bytes) / 32_000.0
    }

    public func startStreaming(
        context: AppContext, language: String?, micProximity: MicProximity
    ) async throws {
        if !sttEngine.isReady {
            Log.debug("[LocalModelStreaming] Loading STT engine \(sttEngine.name)")
            try await sttEngine.load()
            Log.debug("[LocalModelStreaming] STT engine loaded")
        }
        lock.withLock { accumulatedAudio = Data() }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        lock.withLock { accumulatedAudio.append(pcmData) }
    }

    public func finishStreaming() async throws -> String {
        let audio = lock.withLock {
            let d = accumulatedAudio
            accumulatedAudio = Data()
            return d
        }
        guard !audio.isEmpty else {
            Log.debug("[LocalModelStreaming] No audio accumulated")
            return ""
        }

        Log.debug("[LocalModelStreaming] Encoding \(audio.count) bytes as WAV")
        let wav = WAVEncoder.encode(
            pcmData: audio, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        Log.debug("[LocalModelStreaming] Transcribing \(wav.count) byte WAV")
        let raw = try await sttEngine.transcribe(audio: wav)
        Log.debug("[LocalModelStreaming] Raw transcription: '\(raw)'")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        return await polish(trimmed)
    }

    public func cancelStreaming() async {
        lock.withLock { accumulatedAudio = Data() }
    }

    // MARK: - Polishing

    private func polish(_ raw: String) async -> String {
        let substituted = PolishPipeline.substituteDictatedPunctuation(raw)
        let stripped = PolishPipeline.stripKeepTags(substituted)

        guard let polishChatClient else {
            return PolishPipeline.normalizeFormatting(stripped)
        }

        do {
            Log.debug("[LocalModelStreaming] Polishing via LLM...")
            let polished = try await polishChatClient.complete(
                model: polishModel,
                systemPrompt: PolishPipeline.systemPromptLocal,
                userPrompt: stripped)
            if polished.isEmpty {
                Log.debug("[LocalModelStreaming] LLM returned empty, using deterministic")
                return PolishPipeline.normalizeFormatting(stripped)
            }
            Log.debug("[LocalModelStreaming] Polished: '\(polished)'")
            return PolishPipeline.normalizeFormatting(polished)
        } catch {
            Log.debug("[LocalModelStreaming] Polish failed: \(error)")
            return PolishPipeline.normalizeFormatting(stripped)
        }
    }
}
