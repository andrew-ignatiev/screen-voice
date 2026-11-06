import Foundation
import Testing
@testable import ScreenVoice

/// The UI is written in English (development language) and translated through `Localizable.xcstrings`.
@Suite("Localization")
struct LocalizationTests {
    private static func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "\(language).lproj missing from the app")
        return try #require(Bundle(path: path))
    }

    private static func russian(_ key: String) throws -> String {
        try bundle("ru").localizedString(forKey: key, value: "⟨missing⟩", table: "Localizable")
    }

    @Test func developmentLanguageIsEnglish() {
        #expect(Bundle.main.developmentLocalization == "en")
        #expect(Bundle.main.localizations.contains("ru"))
    }

    @Test(arguments: [
        ("Start", "Старт"),
        ("Choose Region or Window…", "Выбрать область/окно…"),
        ("Speech", "Озвучка"),
        ("Qwen3-TTS (neural)", "Qwen3-TTS (нейросеть)"),
        ("Download Model", "Загрузить модель"),
        ("Save as Preset…", "Сохранить как пресет…"),
        ("Narrator, male", "Диктор, мужской"),
        ("Voice designer", "Конструктор голосов"),
        ("Reference length", "Длина эталона"),
        ("Calm (0.7)", "Спокойная (0.7)"),
        ("Text to listen", "Текст для прослушивания"),
    ])
    func russianTranslationExists(key: String, expected: String) throws {
        #expect(try Self.russian(key) == expected)
    }

    @Test func russianFormatStringsKeepArgumentOrder() throws {
        let region = String(format: try Self.russian("Region %lld×%lld on display %u"), 1920, 200, UInt32(2))
        #expect(region == "Область 1920×200 на дисплее 2")

        let model = String(format: try Self.russian("The “%@ → %@” translation model isn’t downloaded to this Mac yet."), "Английский", "Русский")
        #expect(model == "Модель перевода «Английский → Русский» ещё не загружена на этот Mac.")

        let confidence = String(format: try Self.russian("Min. OCR confidence: %lld%%"), 40)
        #expect(confidence == "Мин. уверенность OCR: 40%")
    }

    @Test func languageNamesComeFromTheSystemAndAreCapitalized() {
        let name = AppSettings.languageName("de")
        #expect(!name.isEmpty && name != "de")
        #expect(name.first?.isUppercase == true)
        #expect(SourceLanguage.german.displayName == name)
    }

    @Test @MainActor func spokenTextStaysRussian() {
        // Content the app speaks is in the target language regardless of the interface language.
        #expect(SpeechService.previewText.contains("Привет"))
        // The voice description is model input and stays English in every interface language.
        #expect(NeuralVoice.defaultMale.instruct.hasPrefix("Native Russian male speaker."))
    }
}
