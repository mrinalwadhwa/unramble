import Foundation

/// On-device batch dictation using a local STT engine.
///
/// Take a complete WAV recording, transcribe it locally via the
/// `LocalSTTEngine`, then polish the result through the local
/// `PolishChatClient`. Same polish pipeline as
/// `SpeechAnalyzerDictationProvider` — dictated punctuation
/// substitution, tag stripping, LLM polish, formatting normalization.
public struct LocalModelDictationProvider: DictationProviding {

    private let sttEngine: any LocalSTTEngine
    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String

    public init(
        sttEngine: any LocalSTTEngine,
        polishChatClient: (any PolishChatClient)?,
        polishModel: String = PolishPipeline.polishModel
    ) {
        self.sttEngine = sttEngine
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
    }

    public func dictate(
        audio: Data, context: AppContext
    ) async throws -> String {
        guard audio.count > WAVEncoder.headerSize else {
            throw DictationError.emptyAudio
        }

        if !sttEngine.isReady { try await sttEngine.load() }
        let raw = try await sttEngine.transcribe(audio: audio)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        return await polish(trimmed, context: context)
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
            let polished = try await polishChatClient.complete(
                model: polishModel,
                systemPrompt: systemPrompt,
                userPrompt: stripped)
            if polished.isEmpty {
                return PolishPipeline.normalizeFormatting(
                    stripped, casual: casual)
            }
            if let fallback = PolishPipeline.guardAgainstTruncation(
                polished: polished, preprocessed: stripped) {
                return PolishPipeline.normalizeFormatting(
                    fallback, casual: casual)
            }
            return PolishPipeline.normalizeFormatting(
                polished, casual: casual)
        } catch {
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }
    }
}
