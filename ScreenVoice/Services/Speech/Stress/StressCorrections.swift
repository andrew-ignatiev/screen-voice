import Foundation

/// Words RUAccent marks wrong whatever the context, with the right mark (`+` before the stressed vowel).
/// They are applied on top of the models, to the word as typed, so «нёбо» typed with ё keeps its own reading.
///
/// Only for words whose other reading is rare in subtitles. Words that need the context (мука, дома, все/всё,
/// узнаем/узнаём) can't be fixed here.
///
/// The research reference `ruaccent_fixed.py` reads this table from this file: keep one `"word": "mark",` per line.
enum StressCorrections {
    static let words: [String: String] = [
        // The ё model reads the sky as «нёбо» (the palate).
        "небо": "н+ебо",
        "небом": "н+ебом",
        // Dictionary stress on the stem; the norm is on the ending.
        "щавель": "щав+ель",
        "щавеля": "щавел+я",
        "щавелю": "щавел+ю",
        "щавелем": "щавел+ём",
        "щавеле": "щавел+е",
        "начался": "началс+я",
        "поняла": "понял+а",
        "подняла": "поднял+а",
        "обняла": "обнял+а",
        "наняла": "нанял+а",
        // ё left out by the translator and not restored.
        "свекла": "св+ёкла",
        "свеклы": "св+ёклы",
        "свекле": "св+ёкле",
        "свеклу": "св+ёклу",
        "свеклой": "св+ёклой",
        "федор": "ф+ёдор",
        "федора": "ф+ёдора",
        "федору": "ф+ёдору",
        "федором": "ф+ёдором",
        "федоре": "ф+ёдоре",
        "алена": "ал+ёна",
        "алены": "ал+ёны",
        "алене": "ал+ёне",
        "алену": "ал+ёну",
        "аленой": "ал+ёной",
    ]

    /// `word` with the correction's letters and mark, in the word's own case.
    static func apply(_ correction: String, to word: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let marked = Array(correction.unicodeScalars)
        let cased = StressText.fixCapital(source: word, target: marked.filter { $0 != StressText.plus })
        return StressText.transferPlus(from: marked, to: cased)
    }
}
