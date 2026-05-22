import AVFoundation
import Foundation
import Speech

/// On-device batch dictation using SFSpeechRecognizer.
///
/// Takes a complete WAV recording, transcribes it locally via
/// `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, then
/// polishes the result. Uses the legacy SFSpeechRecognizer API
/// (not SpeechAnalyzer) so it can run concurrently with a
/// SpeechAnalyzer streaming session without conflicts.
@available(macOS 26, *)
public struct SpeechAnalyzerDictationProvider: BatchDictationProviding {

    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String
    private let locale: Locale

    public init(
        polishChatClient: (any PolishChatClient)?,
        polishModel: String = PolishPipeline.polishModel,
        language: String? = nil
    ) {
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
        self.locale = Self.resolveLocale(language: language)
    }

    public func dictate(
        audio: Data, context: AppContext
    ) async throws -> String {
        guard audio.count > 44 else {
            throw DictationError.emptyAudio
        }

        let rawTranscript = try await transcribe(audio: audio)
        let trimmed = rawTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        return await polish(trimmed, context: context)
    }

    // MARK: - Transcription

    private func transcribe(audio: Data) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw DictationError.networkError(
                "Speech recognizer unavailable for locale \(locale.identifier)")
        }
        guard recognizer.isAvailable else {
            throw DictationError.networkError(
                "On-device speech recognition not available")
        }

        // Write WAV to a temp file for SFSpeechURLRecognitionRequest.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try audio.write(to: tempURL)

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await SafeRecognitionContinuation.run { handler in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    handler(nil, error)
                    return
                }
                guard let result, result.isFinal else {
                    handler(nil, nil)
                    return
                }
                handler(result.bestTranscription.formattedString, nil)
            }
        }
    }

    // MARK: - Polishing

    private func polish(
        _ raw: String, context: AppContext
    ) async -> String {
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
            return PolishPipeline.normalizeFormatting(
                polished, casual: casual)
        } catch {
            return PolishPipeline.normalizeFormatting(
                stripped, casual: casual)
        }
    }

    // MARK: - Locale resolution

    /// Map an ISO-639-1 language code to a full locale identifier.
    ///
    /// SpeechAnalyzer requires a region-qualified locale (e.g. "en-US")
    /// to find the correct on-device model. Bare language codes like
    /// "en" fail with "No Assistant asset for language en".
    static func resolveLocale(language: String?) -> Locale {
        guard let language, !language.isEmpty else {
            return .current
        }
        // Already region-qualified (e.g. "en-US" or "zh-TW").
        if language.contains("-") || language.contains("_") {
            return Locale(identifier: language)
        }
        // Map common language codes to default regions.
        let regionMap: [String: String] = [
            "en": "en-US", "zh": "zh-CN", "es": "es-ES",
            "fr": "fr-FR", "de": "de-DE", "it": "it-IT",
            "ja": "ja-JP", "ko": "ko-KR", "pt": "pt-BR",
            "ru": "ru-RU", "ar": "ar-SA", "nl": "nl-NL",
            "sv": "sv-SE", "da": "da-DK", "nb": "nb-NO",
            "no": "nb-NO", "fi": "fi-FI", "tr": "tr-TR",
            "pl": "pl-PL", "th": "th-TH", "vi": "vi-VN",
            "ms": "ms-MY", "he": "he-IL", "hi": "hi-IN",
        ]
        if let mapped = regionMap[language.lowercased()] {
            return Locale(identifier: mapped)
        }
        // Fallback: use Locale's own resolution.
        return Locale(identifier: language)
    }
}
