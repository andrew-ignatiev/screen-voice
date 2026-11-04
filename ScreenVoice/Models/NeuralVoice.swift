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

/// A Qwen3-TTS VoiceDesign voice: a description plus a seed. The model invents a voice that matches the
/// description; the seed picks one of those voices. The same voice and text always give the same audio.
struct NeuralVoice: Codable, Hashable, Sendable {
    var gender: VoiceGender
    /// Free-form English description of timbre, age, accent and delivery.
    var style: String
    var seed: UInt64

    /// Variants offered in Settings. Any seed works; the range just keeps the field readable.
    static let seedRange: ClosedRange<UInt64> = 1...99_999

    /// Seeds 6 and 2 kept the most even pitch across different phrases in a scan of seeds 1–8.
    static let defaultMale = NeuralVoice(gender: .male, style: VoiceGender.male.defaultStyle, seed: 6)
    static let defaultFemale = NeuralVoice(gender: .female, style: VoiceGender.female.defaultStyle, seed: 2)

    /// Full description passed to the model as its `instruct` prompt.
    var instruct: String {
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        return style.isEmpty ? gender.descriptionLine : gender.descriptionLine + "\n" + style
    }

    /// Switches gender. An untouched default style follows the gender; an edited style is kept.
    mutating func setGender(_ newGender: VoiceGender) {
        guard newGender != gender else { return }
        if style == gender.defaultStyle {
            style = newGender.defaultStyle
        }
        gender = newGender
    }
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
