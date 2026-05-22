import Foundation

/// On-device streaming dictation using a local STT engine.
///
/// Accumulate PCM audio chunks during recording, then batch-transcribe
/// via the `LocalSTTEngine` when the session ends. The engine does not
/// support true streaming, so audio is buffered and transcribed on
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
    private var currentContext: AppContext = .empty

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
        lock.withLock {
            accumulatedAudio = Data()
            currentContext = context
        }
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
        let sttStart = CFAbsoluteTimeGetCurrent()
        let raw = try await sttEngine.transcribe(audio: wav)
        let sttElapsed = CFAbsoluteTimeGetCurrent() - sttStart
        Log.debug("[LocalModelStreaming] Raw transcription: '\(raw)' (stt=\(String(format: "%.2f", sttElapsed))s)")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let context = lock.withLock { currentContext }
        return await polish(trimmed, context: context)
    }

    public func cancelStreaming() async {
        lock.withLock { accumulatedAudio = Data() }
    }

    // MARK: - Polishing

    private func polish(_ raw: String, context: AppContext) async -> String {
        let casual = PolishPipeline.toneLabel(for: context.bundleID) == "casual"
        let substituted = PolishPipeline.substituteDictatedPunctuation(
            raw, casual: casual,
            precedingText: context.focusedFieldContent)
        let stripped = PolishPipeline.stripKeepTags(
            substituted, casual: casual)

        guard let polishChatClient else {
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }

        let systemPrompt = PolishPipeline.buildQwenSystemPrompt(
            context: context)

        do {
            Log.debug("[LocalModelStreaming] Polishing via LLM...")
            let polishStart = CFAbsoluteTimeGetCurrent()
            let polished = try await polishChatClient.complete(
                model: polishModel,
                systemPrompt: systemPrompt,
                userPrompt: stripped)
            let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart
            if polished.isEmpty {
                Log.debug("[LocalModelStreaming] LLM returned empty, using deterministic")
                return PolishPipeline.normalizeFormatting(
                    stripped, casual: casual)
            }
            if let fallback = PolishPipeline.guardAgainstTruncation(
                polished: polished, preprocessed: stripped) {
                return PolishPipeline.normalizeFormatting(
                    fallback, casual: casual)
            }
            Log.debug("[LocalModelStreaming] Polished: '\(polished)' (polish=\(String(format: "%.2f", polishElapsed))s)")
            return PolishPipeline.normalizeFormatting(
                polished, casual: casual)
        } catch {
            Log.debug("[LocalModelStreaming] Polish failed: \(error)")
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }
    }
}
