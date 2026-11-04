import Foundation
import Testing
@testable import ScreenVoice

@Suite("SpeakerLabelFilter")
struct SpeakerLabelFilterTests {
    @Test(arguments: [
        ("Датч: Что-то там", "Что-то там"),
        ("ДАТЧ: Что-то там", "Что-то там"),
        ("Артур Морган: Поехали.", "Поехали."),
        ("Mr. Smith: Hello there", "Hello there"),
        ("- Датч: Что-то там", "Что-то там"),
        ("Солдат 2: Стоять!", "Стоять!"),
        ("Датч: Привет. Артур: Пока.", "Привет. Пока."),
        ("Датч:", ""),
    ])
    func removesSpeakerLabels(input: String, expected: String) {
        #expect(SpeakerLabelFilter.strip(input) == expected)
    }

    @Test(arguments: [
        "Я скажу: да",
        "Встреча в 10:30 у входа",
        "Что-то там без имени",
        "Список покупок: хлеб, молоко",
    ])
    func keepsOrdinaryText(input: String) {
        #expect(SpeakerLabelFilter.strip(input) == input)
    }

    @Test func settingIsOnByDefaultAndDecodesFromOldSettings() throws {
        #expect(AppSettings().skipSpeakerLabels)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sourceLanguage":"en"}"#.utf8))
        #expect(old.skipSpeakerLabels)
    }
}
