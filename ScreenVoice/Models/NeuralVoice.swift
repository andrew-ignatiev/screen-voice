import CryptoKit
import Foundation

enum VoiceGender: String, CaseIterable, Codable, Identifiable, Sendable {
    case male
    case female

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .male: String(localized: "Male", comment: "Voice gender")
        case .female: String(localized: "Female", comment: "Voice gender")
        }
    }

    /// First line of the voice description sent to the model. Model input, not UI: never localized.
    var descriptionLine: String {
        switch self {
        case .male: "Native Russian male speaker."
        case .female: "Native Russian female speaker."
        }
    }

    /// Style the voice starts with for this gender. Model input, not UI: never localized.
    var defaultStyle: String {
        let timbre = switch self {
        case .male: "Deep, warm, resonant baritone."
        case .female: "Warm, clear, pleasant mezzo-soprano."
        }
        return """
        Audiobook narrator.
        \(timbre)
        Mature adult voice, natural Moscow pronunciation.
        Excellent Russian articulation.
        Calm, confident, intelligent delivery.
        Natural breathing and sentence pauses.
        Subtle emotional expression.
        No robotic intonation.
        No exaggerated theatrical acting.
        Professional audiobook quality.
        """
    }
}

/// How freely Base samples speech. Lower temperature keeps pitch and timbre steadier; higher sounds livelier.
/// Used only for speaking: references are always created at the model default (0.9), so built-in and created
/// voices match.
enum NeuralDelivery: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 0.7: pitch range 82–111 Hz vs 80–126 Hz at 0.9 on the same 25 lines, same intelligibility.
    case calm
    /// 0.9: the model's default.
    case lively

    var id: String { rawValue }

    var temperature: Float {
        switch self {
        case .calm: 0.7
        case .lively: 0.9
        }
    }

    var displayName: String {
        switch self {
        case .calm: String(localized: "Calm (0.7)", comment: "Neural voice delivery")
        case .lively: String(localized: "Lively (0.9)", comment: "Neural voice delivery")
        }
    }
}

/// A voice described in words. Qwen3-TTS VoiceDesign turns the description and seed into a short reference
/// recording once; the Base model then clones that recording for every phrase. The same voice and text always
/// give the same audio.
struct NeuralVoice: Codable, Hashable, Sendable {
    var gender: VoiceGender
    /// Free-form English description of timbre, age, accent and delivery.
    var style: String
    var seed: UInt64
    /// Approximate length of the reference recording the voice is cloned from.
    var referenceSeconds: Int = NeuralVoice.defaultReferenceSeconds
    /// A person's recording to clone instead of a designed voice. When set, style and reference length are unused.
    var recording: RecordedVoice?

    /// Variants offered in Settings. Any seed works; the range just keeps the field readable.
    static let seedRange: ClosedRange<UInt64> = 1...99_999
    static let referenceSecondsRange: ClosedRange<Int> = 5...12
    /// 11 s gave the deepest, steadiest male voice in listening tests.
    static let defaultReferenceSeconds = 11

    /// Seed 6 (male) and 3 (female): references with exact transcripts at every length and an even pitch.
    static let defaultMale = NeuralVoice(gender: .male, style: VoiceGender.male.defaultStyle, seed: 6)
    static let defaultFemale = NeuralVoice(gender: .female, style: VoiceGender.female.defaultStyle, seed: 3)

    init(
        gender: VoiceGender,
        style: String,
        seed: UInt64,
        referenceSeconds: Int = NeuralVoice.defaultReferenceSeconds,
        recording: RecordedVoice? = nil
    ) {
        self.gender = gender
        self.style = style
        self.seed = seed
        self.referenceSeconds = referenceSeconds
        self.recording = recording
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gender = try container.decode(VoiceGender.self, forKey: .gender)
        style = try container.decode(String.self, forKey: .style)
        seed = try container.decode(UInt64.self, forKey: .seed)
        // Presets saved before the reference length existed get the default.
        let seconds = try container.decodeIfPresent(Int.self, forKey: .referenceSeconds) ?? Self.defaultReferenceSeconds
        referenceSeconds = min(max(seconds, Self.referenceSecondsRange.lowerBound), Self.referenceSecondsRange.upperBound)
        recording = try container.decodeIfPresent(RecordedVoice.self, forKey: .recording)
    }

    /// Full description passed to VoiceDesign as its `instruct` prompt.
    var instruct: String {
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        return style.isEmpty ? gender.descriptionLine : gender.descriptionLine + "\n" + style
    }

    /// What the reference recording says. Base needs the exact transcript of the recording it clones.
    var referenceText: String { recording?.text ?? VoiceReference.text(seconds: referenceSeconds) }

    /// Switches gender. An untouched default style follows the gender; an edited style is kept.
    mutating func setGender(_ newGender: VoiceGender) {
        guard newGender != gender else { return }
        if style == gender.defaultStyle {
            style = newGender.defaultStyle
        }
        gender = newGender
    }
}

/// A voice recorded by the user with the microphone, cloned by Base like a designed reference.
struct RecordedVoice: Codable, Hashable, Sendable {
    /// Names the file `recorded-<id>.wav` in the reference directory.
    var id: UUID
    /// Exactly what was said in the recording. Base needs the transcript to clone well.
    var text: String
    var seconds: Double

    /// Passages to read aloud: complete sentences, calm narration, every Russian letter and a question and an
    /// exclamation between them, about 10–15 s each. Model input, not UI: never localized.
    static let passages = [
        "Добрый вечер. Сейчас мы начнём. Пожалуйста, внимательно выслушайте меня до конца. Сегодня я расскажу вам одну короткую, но очень важную историю.",
        "Съешь же ещё этих мягких французских булок, да выпей чаю. В чащах юга жил бы цитрус? Да, но фальшивый экземпляр!",
        "Утром над рекой стоял густой туман, и рыбаки не спешили выходить в море. Только старый капитан спокойно чинил сети и тихо напевал знакомую песню.",
        "Широкая электрификация южных губерний даст мощный толчок подъёму сельского хозяйства. Как вы думаете, это случится скоро? Посмотрим!",
    ]

    /// Recordings shorter than this clone poorly; longer ones only slow down every phrase.
    static let secondsRange: ClosedRange<Double> = 3...20
    static let recommendedSeconds: ClosedRange<Double> = 8...15
}

/// A named voice the user can switch back to.
struct VoicePreset: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var voice: NeuralVoice

    static let builtIn: [VoicePreset] = [
        VoicePreset(
            id: UUID(uuidString: "6B1F0C2E-4D1A-4E8B-9C11-6D2B7A0E5F01")!,
            name: String(localized: "Narrator, male", comment: "Built-in voice preset"),
            voice: .defaultMale
        ),
        VoicePreset(
            id: UUID(uuidString: "6B1F0C2E-4D1A-4E8B-9C11-6D2B7A0E5F02")!,
            name: String(localized: "Narrator, female", comment: "Built-in voice preset"),
            voice: .defaultFemale
        ),
    ]

    var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }
}

/// Where the reference recording of a voice lives. Built-in narrators ship in the app bundle; other voices are
/// created on this Mac with VoiceDesign and kept in Application Support.
enum VoiceReference {
    /// Texts of growing length, one per second of `NeuralVoice.referenceSecondsRange`. They share an opening, so
    /// a longer reference mostly adds material. Model input, not UI: never localized. Changing a text changes
    /// every voice made from it, so add new texts rather than edit these.
    static let texts: [Int: String] = {
        let opening = "Добрый вечер. Сейчас мы начнём. Пожалуйста, внимательно выслушайте меня до конца."
        return [
            5: "Добрый вечер. Сейчас мы начнём. Пожалуйста, слушайте внимательно.",
            6: opening,
            7: opening + " Это очень важно.",
            8: opening + " Сегодня у нас короткая история.",
            9: opening + " Сегодня я расскажу вам одну короткую историю.",
            10: opening + " Сегодня я расскажу вам одну короткую, но важную историю.",
            11: opening + " Сегодня я расскажу вам одну короткую, но очень важную историю.",
            12: opening + " Сегодня я расскажу вам одну короткую, но очень важную историю о дружбе.",
        ]
    }()

    static func text(seconds: Int) -> String {
        let clamped = min(max(seconds, NeuralVoice.referenceSecondsRange.lowerBound), NeuralVoice.referenceSecondsRange.upperBound)
        return texts[clamped]!
    }

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "ScreenVoice/VoiceReferences", directoryHint: .isDirectory)
    }

    /// Bundled recording for a built-in narrator, e.g. `narrator-male-11`.
    static func bundledURL(for voice: NeuralVoice, bundle: Bundle = .main) -> URL? {
        let builtIn: String
        switch voice.gender {
        case .male: builtIn = "narrator-male"
        case .female: builtIn = "narrator-female"
        }
        var base = voice.gender == .male ? NeuralVoice.defaultMale : NeuralVoice.defaultFemale
        base.referenceSeconds = voice.referenceSeconds
        guard voice == base else { return nil }
        return bundle.url(forResource: String(format: "%@-%02d", builtIn, voice.referenceSeconds), withExtension: "wav")
    }

    /// Where a created recording of `voice` is stored. The name hashes everything that shapes the recording.
    static func createdURL(for voice: NeuralVoice, directory: URL = defaultDirectory) -> URL {
        let recipe = [QwenModelSpec.voiceDesign8bit.revision, String(voice.seed), voice.instruct, voice.referenceText]
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(recipe.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).wav")
    }

    static func recordedURL(for recording: RecordedVoice, directory: URL = defaultDirectory) -> URL {
        directory.appending(path: "recorded-\(recording.id.uuidString).wav")
    }

    /// Deletes recordings no voice refers to any more.
    static func removeUnusedRecordings(keeping used: Set<UUID>, directory: URL = defaultDirectory) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("recorded-") {
            let id = UUID(uuidString: String(file.deletingPathExtension().lastPathComponent.dropFirst("recorded-".count)))
            if let id, !used.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// The recording to clone, if the voice has one yet.
    static func existingURL(for voice: NeuralVoice, directory: URL = defaultDirectory, bundle: Bundle = .main) -> URL? {
        if let recording = voice.recording {
            let url = recordedURL(for: recording, directory: directory)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let url = bundledURL(for: voice, bundle: bundle) { return url }
        let url = createdURL(for: voice, directory: directory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
