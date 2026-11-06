import Foundation

/// Source languages offered in the MVP. Support for each pair is still verified at runtime.
enum SourceLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case japanese = "ja"

    var id: String { rawValue }

    /// Language name in the user's interface language, provided by the system.
    var displayName: String {
        AppSettings.languageName(rawValue)
    }

    /// Language used by the Translation framework.
    var localeLanguage: Locale.Language { Locale.Language(identifier: rawValue) }

    /// Language code used by Vision text recognition.
    var recognitionLanguageCode: String {
        switch self {
        case .english: "en-US"
        case .german: "de-DE"
        case .french: "fr-FR"
        case .spanish: "es-ES"
        case .japanese: "ja-JP"
        }
    }

    /// Vision's fast recognition path only supports Latin-script languages.
    var supportsFastRecognition: Bool { self != .japanese }
}

enum OCRAccuracy: String, CaseIterable, Codable, Identifiable, Sendable {
    case accurate
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accurate: String(localized: "Accurate", comment: "OCR mode")
        case .fast: String(localized: "Fast", comment: "OCR mode")
        }
    }
}

/// Which synthesizer speaks the translations.
enum SpeechEngineKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Installed ru-RU system voice via AVSpeechSynthesizer.
    case system
    /// Local Qwen3-TTS neural model via MLX. Falls back to the system voice while unavailable.
    case qwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: "System voice")
        case .qwen: String(localized: "Qwen3-TTS (neural)")
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    /// The MVP always translates into Russian.
    static let targetLanguage = Locale.Language(identifier: "ru")

    /// "Russian" in the user's interface language.
    static var targetLanguageName: String { languageName("ru") }

    /// Capitalized language name in the current locale, e.g. "German" or "Немецкий".
    static func languageName(_ code: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased(with: .current) + name.dropFirst()
    }

    var sourceLanguage: SourceLanguage = .english
    var speechEngine: SpeechEngineKind = .system
    /// The Qwen3-TTS voice: gender, style description and seed.
    var neuralVoice: NeuralVoice = .defaultMale
    /// Sampling temperature of the Qwen3-TTS voice while speaking.
    var neuralDelivery: NeuralDelivery = .calm
    /// Mark Russian stress for the Qwen3-TTS voice when the stress pack is installed.
    var russianStress: Bool = true
    /// What Listen/Preview speaks. Empty means `SpeechService.previewText`.
    var previewText: String = ""
    /// Voices saved by the user. Built-in presets are not stored.
    var voicePresets: [VoicePreset] = []
    /// Identifier of the chosen ru-RU voice. `nil` means "best installed Russian voice".
    var voiceIdentifier: String?
    /// AVSpeechUtterance rate, between AVSpeechUtteranceMinimumSpeechRate and Maximum.
    var speechRate: Float = 0.5
    var speechVolume: Float = 1.0
    var framesPerSecond: Double = 4
    var ocrAccuracy: OCRAccuracy = .accurate
    var minimumConfidence: Float = 0.4
    var maxQueuedPhrases: Int = 3
    /// Speak faster while phrases are waiting (see `SpeechService.catchUpFactor`).
    var speedUpWhenBehind: Bool = true
    var showOverlay: Bool = true
    /// Do not speak speaker labels such as "Датч:" at the start of a line.
    var skipSpeakerLabels: Bool = true

    static let framesPerSecondRange: ClosedRange<Double> = 1...10
    static let queueRange: ClosedRange<Int> = 1...10
}

extension AppSettings {
    /// Decodes leniently so that settings saved by older builds keep working when fields are added.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        sourceLanguage = (try? container.decodeIfPresent(SourceLanguage.self, forKey: .sourceLanguage)) ?? defaults.sourceLanguage
        speechEngine = (try? container.decodeIfPresent(SpeechEngineKind.self, forKey: .speechEngine)) ?? defaults.speechEngine
        neuralVoice = (try? container.decodeIfPresent(NeuralVoice.self, forKey: .neuralVoice)) ?? defaults.neuralVoice
        neuralDelivery = (try? container.decodeIfPresent(NeuralDelivery.self, forKey: .neuralDelivery)) ?? defaults.neuralDelivery
        russianStress = (try? container.decodeIfPresent(Bool.self, forKey: .russianStress)) ?? defaults.russianStress
        previewText = (try? container.decodeIfPresent(String.self, forKey: .previewText)) ?? defaults.previewText
        voicePresets = (try? container.decodeIfPresent([VoicePreset].self, forKey: .voicePresets)) ?? defaults.voicePresets
        voiceIdentifier = try? container.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        speechRate = (try? container.decodeIfPresent(Float.self, forKey: .speechRate)) ?? defaults.speechRate
        speechVolume = (try? container.decodeIfPresent(Float.self, forKey: .speechVolume)) ?? defaults.speechVolume
        framesPerSecond = (try? container.decodeIfPresent(Double.self, forKey: .framesPerSecond)) ?? defaults.framesPerSecond
        ocrAccuracy = (try? container.decodeIfPresent(OCRAccuracy.self, forKey: .ocrAccuracy)) ?? defaults.ocrAccuracy
        minimumConfidence = (try? container.decodeIfPresent(Float.self, forKey: .minimumConfidence)) ?? defaults.minimumConfidence
        maxQueuedPhrases = (try? container.decodeIfPresent(Int.self, forKey: .maxQueuedPhrases)) ?? defaults.maxQueuedPhrases
        speedUpWhenBehind = (try? container.decodeIfPresent(Bool.self, forKey: .speedUpWhenBehind)) ?? defaults.speedUpWhenBehind
        showOverlay = (try? container.decodeIfPresent(Bool.self, forKey: .showOverlay)) ?? defaults.showOverlay
        skipSpeakerLabels = (try? container.decodeIfPresent(Bool.self, forKey: .skipSpeakerLabels)) ?? defaults.skipSpeakerLabels
    }
}

// MARK: Voice presets

extension AppSettings {
    /// Built-in presets first, then the user's.
    var allVoicePresets: [VoicePreset] { VoicePreset.builtIn + voicePresets }

    /// Recordings used by the current voice or a saved preset.
    var usedRecordings: Set<UUID> {
        Set(([neuralVoice] + voicePresets.map(\.voice)).compactMap { $0.recording?.id })
    }

    /// The preset matching the current voice exactly, if any.
    var selectedVoicePreset: VoicePreset? {
        allVoicePresets.first { $0.voice == neuralVoice }
    }

    /// Saves the current voice. A user preset with the same name is overwritten.
    @discardableResult
    mutating func saveVoicePreset(named rawName: String) -> VoicePreset? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let index = voicePresets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            voicePresets[index].voice = neuralVoice
            return voicePresets[index]
        }
        let preset = VoicePreset(id: UUID(), name: name, voice: neuralVoice)
        voicePresets.append(preset)
        return preset
    }

    mutating func deleteVoicePreset(id: UUID) {
        voicePresets.removeAll { $0.id == id }
    }

    mutating func applyVoicePreset(id: UUID) {
        if let preset = allVoicePresets.first(where: { $0.id == id }) {
            neuralVoice = preset.voice
        }
    }
}
