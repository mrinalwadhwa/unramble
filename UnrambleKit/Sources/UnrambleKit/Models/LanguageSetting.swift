import Foundation

/// Supported dictation languages with their ISO-639-1 codes and display names.
///
/// The language setting controls two things:
/// 1. The transcription language hint sent to the OpenAI Realtime API,
///    which improves recognition accuracy for non-English speech.
/// 2. The polish pipeline path on the server: English uses the full
///    regex + LLM pipeline with formatting commands; non-English uses
///    a minimal LLM-only cleanup prompt.
///
/// Persisted in UserDefaults. On first launch, defaults to the macOS
/// preferred language if supported, otherwise English.
///
/// Languages sourced from OpenAI's speech-to-text documentation:
/// https://platform.openai.com/docs/guides/speech-to-text
/// These are the 57 languages with <50% word error rate.
public enum LanguageSetting: String, CaseIterable, Sendable {
    case afrikaans = "af"
    case arabic = "ar"
    case azerbaijani = "az"
    case belarusian = "be"
    case bosnian = "bs"
    case bulgarian = "bg"
    case catalan = "ca"
    case chinese = "zh"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case english = "en"
    case estonian = "et"
    case finnish = "fi"
    case french = "fr"
    case galician = "gl"
    case german = "de"
    case greek = "el"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case icelandic = "is"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case kannada = "kn"
    case kazakh = "kk"
    case korean = "ko"
    case latvian = "lv"
    case lithuanian = "lt"
    case macedonian = "mk"
    case malay = "ms"
    case marathi = "mr"
    case maori = "mi"
    case nepali = "ne"
    case norwegian = "no"
    case persian = "fa"
    case polish = "pl"
    case portuguese = "pt"
    case romanian = "ro"
    case russian = "ru"
    case serbian = "sr"
    case slovak = "sk"
    case slovenian = "sl"
    case spanish = "es"
    case swahili = "sw"
    case swedish = "sv"
    case tagalog = "tl"
    case tamil = "ta"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case urdu = "ur"
    case vietnamese = "vi"
    case welsh = "cy"

    /// Human-readable name for display in the menu bar.
    public var displayName: String {
        switch self {
        case .afrikaans: return "Afrikaans"
        case .arabic: return "Arabic"
        case .azerbaijani: return "Azerbaijani"
        case .belarusian: return "Belarusian"
        case .bosnian: return "Bosnian"
        case .bulgarian: return "Bulgarian"
        case .catalan: return "Catalan"
        case .chinese: return "Chinese"
        case .croatian: return "Croatian"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .dutch: return "Dutch"
        case .english: return "English"
        case .estonian: return "Estonian"
        case .finnish: return "Finnish"
        case .french: return "French"
        case .galician: return "Galician"
        case .german: return "German"
        case .greek: return "Greek"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .hungarian: return "Hungarian"
        case .icelandic: return "Icelandic"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .kannada: return "Kannada"
        case .kazakh: return "Kazakh"
        case .korean: return "Korean"
        case .latvian: return "Latvian"
        case .lithuanian: return "Lithuanian"
        case .macedonian: return "Macedonian"
        case .malay: return "Malay"
        case .marathi: return "Marathi"
        case .maori: return "Māori"
        case .nepali: return "Nepali"
        case .norwegian: return "Norwegian"
        case .persian: return "Persian"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese"
        case .romanian: return "Romanian"
        case .russian: return "Russian"
        case .serbian: return "Serbian"
        case .slovak: return "Slovak"
        case .slovenian: return "Slovenian"
        case .spanish: return "Spanish"
        case .swahili: return "Swahili"
        case .swedish: return "Swedish"
        case .tagalog: return "Tagalog"
        case .tamil: return "Tamil"
        case .thai: return "Thai"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .urdu: return "Urdu"
        case .vietnamese: return "Vietnamese"
        case .welsh: return "Welsh"
        }
    }

    /// The ISO-639-1 code sent to the server.
    public var languageCode: String {
        return rawValue
    }

    // MARK: - System locale mapping

    /// Map the macOS preferred language to a supported language setting.
    /// Returns nil if the system language is not in our supported set.
    public static func settingFromSystemLocale() -> LanguageSetting? {
        guard let preferred = Locale.preferredLanguages.first else { return nil }
        // Locale identifiers can be "en-US", "fr-FR", "zh-Hans", etc.
        // Extract the base language code (before the first hyphen).
        let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
        let lower = base.lowercased()

        // Check if the base code matches any supported language.
        for setting in LanguageSetting.allCases {
            if setting.rawValue == lower {
                return setting
            }
        }

        return nil
    }
}
