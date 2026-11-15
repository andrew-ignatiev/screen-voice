import Foundation

/// Rewrites what the neural voice misreads into plain Russian words before the text is spoken: numbers, dates,
/// times, money, units, symbols and a few abbreviations. «Это стоит 1500 руб.» becomes «Это стоит тысячу
/// пятьсот рублей.»
///
/// Qwen3-TTS reads bare digits passably but stumbles on everything around them («5-м», «18:05», «2,5 кг»,
/// «км/ч», «т.е.»), and RUAccent deletes the characters it doesn't know (%, $, °, /) before the model sees them.
/// Latin words and initialisms (iPhone, США, МЧС) are left alone: the model reads them correctly.
///
/// The rules guess the grammatical case from the neighbouring words. Where there is nothing to go by, the
/// number is spelled in the nominative.
enum SpokenTextNormalizer {
    typealias Numerals = RussianNumerals
    typealias Case = RussianNumerals.Case
    typealias Gender = RussianNumerals.Gender
    typealias Noun = RussianNumerals.Noun

    static func normalize(_ text: String) -> String {
        // Most subtitle lines have nothing to rewrite.
        guard text.unicodeScalars.contains(where: { triggers.contains($0) }) else { return text }
        var spoken = text
        for pass in passes { spoken = pass(spoken) }
        return spoken == text ? text : tidy(spoken)
    }

    /// Digits, symbols, Roman numerals, and the dot or hyphen of an abbreviation.
    private static let triggers = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "№&%$€£₽°IVXLC.-"))

    private static let passes: [@Sendable (String) -> String] = [
        spaces, abbreviations, symbols, numericDates, times, headings, centuries, compounds, suffixed,
        years, bareYears, monthDates, money, quantities,
    ]

    // MARK: Regular expressions

    /// A match with the text around it.
    private struct Match {
        let groups: [String?]
        let before: Substring
        let after: Substring

        subscript(_ index: Int) -> String? { groups[index] }
        var whole: String { groups[0] ?? "" }

        /// The word before the match, lowercased («на» in «на 15 марта»).
        var previousWord: String? {
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            guard let last = trimmed.split(omittingEmptySubsequences: false, whereSeparator: { !$0.isLetter && $0 != "-" }).last,
                  !last.isEmpty else { return nil }
            return last.lowercased()
        }

        /// The word after the match, lowercased, when only spaces separate them.
        var nextWord: String? {
            let trimmed = after.drop(while: { $0 == " " })
            let word = trimmed.prefix(while: \.isLetter)
            return word.isEmpty ? nil : word.lowercased()
        }

        /// Whether the match starts a sentence.
        var startsSentence: Bool {
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            guard let last = trimmed.last else { return true }
            return ".!?…".contains(last) || (trimmed.allSatisfy { !$0.isLetter && !$0.isNumber })
        }

        /// Whether a sentence ends right after the match, so an abbreviation's own dot was also the full stop.
        var endsSentence: Bool {
            let rest = after.drop(while: { "»”\")".contains($0) })
            guard let first = rest.first else { return true }
            guard first.isWhitespace else { return false }
            guard let next = rest.drop(while: \.isWhitespace).first else { return true }
            return next.isUppercase || next == "-" || next == "—" || next == "«"
        }
    }

    private static func regex(_ pattern: String, caseSensitive: Bool = false) -> NSRegularExpression {
        // The patterns are constants, checked by the tests.
        try! NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    /// `text` with every match replaced by what `body` returns; nil keeps the match as it is.
    private static func replace(_ text: String, _ regex: NSRegularExpression, _ body: (Match) -> String?) -> String {
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var position = 0
        for match in matches {
            let groups = (0 ..< match.numberOfRanges).map { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            let end = match.range.location + match.range.length
            let context = Match(
                groups: groups,
                before: Substring(source.substring(to: match.range.location)),
                after: Substring(source.substring(from: end))
            )
            out += source.substring(with: NSRange(location: position, length: match.range.location - position))
            if var replacement = body(context) {
                if context.startsSentence, let first = groups[0]?.first, !first.isLowercase, first != "-" {
                    replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
                }
                out += replacement
            } else {
                out += groups[0] ?? ""
            }
            position = end
        }
        return out + source.substring(from: position)
    }

    /// Not part of a longer word or number.
    private static let start = #"(?<![\p{L}\d])"#
    private static let end = #"(?![\p{L}\d])"#

    // MARK: Grammar from context

    private static let genitiveWords: Set<String> = [
        "без", "до", "из", "от", "у", "около", "после", "более", "менее", "больше", "меньше", "свыше", "для",
        "кроме", "против", "вместо", "среди", "из-за", "порядка", "старше", "младше", "дольше", "ниже", "выше", "ок",
    ]
    private static let accusativeWords: Set<String> = [
        "через", "за", "на", "в", "во", "про", "спустя", "стоит", "стоят", "стоил", "стоила", "стоило", "стоили",
        "дай", "дайте", "дам", "дал", "дала", "дали", "заплати", "заплатил", "заплатила", "плачу", "получил",
        "получила", "потратил", "потратила", "взял", "взяла", "возьми", "должен", "должна", "должны", "жди",
        "ждал", "ждала", "подожди", "подождите",
    ]
    private static let notInstrumental: Set<String> = ["цунами", "оригами", "салями"]

    /// The case of a number from the words around it.
    private static func numberCase(_ match: Match) -> Case {
        let previous = match.previousWord
        if let next = match.nextWord, next.count >= 4 {
            if next.hasSuffix("ами") || next.hasSuffix("ями"), !notInstrumental.contains(next) { return .instrumental }
            if next.hasSuffix("ах") || next.hasSuffix("ях"), let previous, ["в", "во", "на", "о", "об", "при"].contains(previous) {
                return .prepositional
            }
            if next.hasSuffix("ам") || next.hasSuffix("ям"), let previous, ["к", "ко", "по"].contains(previous) { return .dative }
        }
        guard let previous else { return .nominative }
        if genitiveWords.contains(previous) { return .genitive }
        // «с 5 до 7».
        if previous == "с" || previous == "со", match.after.prefix(30).contains(" до ") { return .genitive }
        if previous == "к" || previous == "ко" { return .dative }
        if accusativeWords.contains(previous) { return .accusative }
        return .nominative
    }

    /// Common feminine and neuter nouns, to say «одна минута», «две недели», «одно слово»: stems of long words
    /// and whole forms of short ones (so «пара» doesn't catch «парня»).
    private static let feminineStems = [
        "минут", "секунд", "недел", "тысяч", "копейк", "копеек", "тонн", "страниц", "комнат", "книг", "девушк",
        "женщин", "девочк", "сестр", "дочер", "машин", "ракет", "бомб", "бутылк", "таблетк", "капл", "попытк",
        "штук", "сторон", "групп", "команд", "жертв", "ошибк", "проблем", "причин", "двер", "звезд", "звёзд",
        "планет", "строк", "строч", "букв", "цифр", "песн", "монет", "квартир", "улиц", "дорог",
    ]
    private static let feminineWords: Set<String> = [
        "миля", "мили", "милю", "дочь", "дочка", "дочки", "дочку", "пуля", "пули", "пулю", "ночь", "ночи", "жизнь",
        "жизни", "вещь", "вещи", "часть", "части", "рука", "руки", "руку", "нога", "ноги", "ногу", "голова", "головы",
        "голову", "серия", "серии", "серию", "глава", "главы", "главу", "игра", "игры", "игру", "карта", "карты",
        "карту", "пара", "пары", "пару", "семья", "семьи", "семью",
    ]
    private static let neuterWords: Set<String> = [
        "слово", "дело", "место", "окно", "правило", "условие", "желание", "сообщение", "письмо", "тело", "яйцо",
        "сердце", "задание", "предложение", "решение", "утро", "поле", "море", "ведро", "кольцо", "пятно",
    ]

    private static func gender(of word: String?) -> Gender {
        guard let word else { return .masculine }
        if feminineWords.contains(word) || feminineStems.contains(where: { word.hasPrefix($0) && word.count - $0.count <= 3 }) {
            return .feminine
        }
        return neuterWords.contains(word) ? .neuter : .masculine
    }

    // MARK: Passes

    /// Unusual spaces become ordinary ones; digit groups join: «1 500» → «1500», «10,000» → «10000».
    private static func spaces(_ text: String) -> String {
        var text = text
        for space in ["\u{A0}", "\u{202F}", "\u{2009}"] { text = text.replacingOccurrences(of: space, with: " ") }
        text = replace(text, grouped) { $0.whole.replacingOccurrences(of: " ", with: "") }
        return replace(text, englishThousands) { $0.whole.replacingOccurrences(of: ",", with: "") }
    }
    private static let grouped = regex(#"(?<![\p{L}\d.,:-])\d{1,3}(?: \d{3})+(?![\d])"#)
    private static let englishThousands = regex(#"(?<![\p{L}\d.,])(?:\d{1,3}(?:,\d{3}){2,}|\d{1,3},000)(?![\d,])"#)

    /// Pattern, spoken words, and whether the abbreviation can end a sentence (its dot is then the full stop too).
    private static let abbreviationRules: [(NSRegularExpression, String, Bool)] = [
        (#"(?<![\p{L}])т\.\s?е\."#, "то есть", false),
        (#"(?<![\p{L}])т\.\s?д\."#, "так далее", true),
        (#"(?<![\p{L}])т\.\s?п\."#, "тому подобное", true),
        (#"(?<![\p{L}])т\.\s?к\."#, "так как", false),
        (#"(?<=\bи\s)др\."#, "другие", true),
        (#"(?<=\bи\s)пр\."#, "прочее", true),
        (#"(?<![\p{L}])напр\."#, "например", false),
        (#"(?<![\p{L}])г-н(?![\p{L}])"#, "господин", false),
        (#"(?<![\p{L}])г-жа(?![\p{L}])"#, "госпожа", false),
        (#"(?<![\p{L}])д-р(?![\p{L}])"#, "доктор", false),
        (#"(?<![\p{L}])проф\."#, "профессор", false),
        (#"(?<![\p{L}])ул\."#, "улица", false),
        (#"(?<![\p{L}])стр\."#, "страница", false),
        (#"(?<![\p{L}])тел\."#, "телефон", false),
        (#"(?<![\p{L}])им\."#, "имени", false),
        (#"(?<![\p{L}])ок\.(?=\s?\d)"#, "около", false),
    ].map { (regex($0.0), $0.1, $0.2) }

    private static func abbreviations(_ text: String) -> String {
        var text = text
        for (rule, words, canEnd) in abbreviationRules {
            text = replace(text, rule) { match in
                let capital = match.whole.first?.isUppercase ?? false
                let spoken = capital ? words.prefix(1).uppercased() + words.dropFirst() : words
                return spoken + (canEnd && match.endsSentence ? "." : "")
            }
        }
        return text
    }

    /// «№ 7» → «номер 7», «5+3» → «5 плюс 3», «Том & Джерри» → «Том и Джерри».
    private static func symbols(_ text: String) -> String {
        var text = replace(text, numeroSign) { _ in "номер " }
        text = replace(text, ampersand) { _ in " и " }
        text = replace(text, plus) { _ in " плюс " }
        text = replace(text, equals) { _ in " равно " }
        return replace(text, multiplySign) { _ in " на " }
    }
    private static let numeroSign = regex(#"№\s?"#)
    private static let ampersand = regex(#"\s?&\s?"#)
    private static let plus = regex(#"(?<=\d)\s?\+\s?(?=\d)"#)
    private static let equals = regex(#"(?<=\d)\s?=\s?(?=\d)"#)
    private static let multiplySign = regex(#"(?<=\d)\s?[x×х]\s?(?=\d)"#)

    private static let months = [
        "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]

    /// The case of a date's day: «на пятнадцатое», «к пятнадцатому», «сегодня пятнадцатое», else «пятнадцатого».
    private static func dayCase(_ previous: String?) -> Case {
        switch previous {
        case "на", "по", "сегодня", "завтра", "вчера", "послезавтра", "было", "будет", "наступило", "наступает": .nominative
        case "к", "ко": .dative
        default: .genitive
        }
    }

    /// «15.03.2024» → «пятнадцатого марта две тысячи двадцать четвёртого года».
    private static func numericDates(_ text: String) -> String {
        replace(text, numericDate) { match in
            guard let day = Int(match[1]!), let month = Int(match[2]!), let year = Int(match[3]!),
                  (1 ... 31).contains(day), (1 ... 12).contains(month),
                  let dayWords = Numerals.ordinal(day, gender: .neuter, case: dayCase(match.previousWord)),
                  let yearWords = Numerals.ordinal(year, case: .genitive) else { return nil }
            return "\(dayWords) \(months[month - 1]) \(yearWords) года"
        }
    }
    private static let numericDate = regex(#"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4})(?![\d])"#)

    private static let hour = Noun.hard("час")

    /// «9:30» → «девять тридцать», «18:05» → «восемнадцать ноль пять», «7:00» → «семь часов».
    /// Other pairs are scores: «3:2» → «3 2».
    private static func times(_ text: String) -> String {
        let text = replace(text, time) { match in
            guard let hours = Int(match[1]!), let minutes = Int(match[2]!) else { return nil }
            let hourCase: Case = match.previousWord.map { genitiveWords.contains($0) } == true ? .genitive : .nominative
            if minutes == 0 {
                return hours == 1 ? hour.counted(1, hourCase) : Numerals.cardinal(hours, case: hourCase) + " " + hour.counted(hours, hourCase)
            }
            let spokenMinutes = minutes < 10 ? "ноль " + Numerals.cardinal(minutes) : Numerals.cardinal(minutes)
            return Numerals.cardinal(hours) + " " + spokenMinutes
        }
        return replace(text, score) { "\($0[1]!) \($0[2]!)" }
    }
    private static let time = regex(#"(?<![\d:.,])([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?(?![\d:])"#)
    private static let score = regex(#"(?<![\d:])(\d{1,3}):(\d{1,3})(?![\d:])"#)

    private static let headingGenders: [String: Gender] = [
        "глава": .feminine, "часть": .feminine, "серия": .feminine, "книга": .feminine,
        "том": .masculine, "эпизод": .masculine, "сезон": .masculine, "акт": .masculine, "раздел": .masculine, "урок": .masculine,
    ]

    /// «Глава 21» → «Глава двадцать первая», «Эпизод IV» → «Эпизод четвёртый».
    private static func headings(_ text: String) -> String {
        replace(text, heading) { match in
            let word = match[1]!, value = match[2]!
            guard let gender = headingGenders[word.lowercased()],
                  let number = Int(value) ?? (value == value.uppercased() ? Numerals.roman(value) : nil),
                  let spoken = Numerals.ordinal(number, gender: gender) else { return nil }
            return word + " " + spoken
        }
    }
    private static let heading = regex(start + #"(глава|часть|серия|книга|том|эпизод|сезон|акт|раздел|урок)\s(\d{1,3}|[IVXLC]+)"# + end + #"(?![.,:-]\d)"#)

    /// «XX века» → «двадцатого века», «в XIX в.» → «в девятнадцатом веке».
    private static func centuries(_ text: String) -> String {
        replace(text, century) { match in
            guard let number = Numerals.roman(match[1]!) else { return nil }
            let noun = match[2]!.lowercased()
            let previous = match.previousWord
            let (word, grammaticalCase): (String, Case) = switch noun {
            case "век": ("век", .nominative)
            case "века": ("века", .genitive)
            case "веку": ("веку", .dative)
            case "веком": ("веком", .instrumental)
            case "веке": ("веке", .prepositional)
            default: previous == "в" ? ("веке", .prepositional) : ("века", .genitive)
            }
            guard let spoken = Numerals.ordinal(number, case: grammaticalCase) else { return nil }
            return spoken + " " + word + (noun == "в." && match.endsSentence ? "." : "")
        }
    }
    private static let century = regex(start + #"([IVXLC]{1,7})\s(веком|веке|веку|века|век|в\.)(?![\p{L}])"#, caseSensitive: true)

    /// «5-летний» → «пятилетний», «3-комнатная» → «трёхкомнатная».
    private static func compounds(_ text: String) -> String {
        replace(text, compound) { match in
            guard let number = Int(match[1]!), let prefix = Numerals.compoundPrefix(number) else { return nil }
            return prefix + match[2]!
        }
    }
    private static let compound = regex(start + #"(\d{1,4})-([а-яё]{5,})"# + end)

    /// Numbers with a written ending: «5-м» → «пятом», «3-го» → «третьего», «90-х» → «девяностых», «2-х» → «двух».
    private static func suffixed(_ text: String) -> String {
        replace(text, suffixedNumber) { match in
            guard let number = Int(match[1]!) else { return nil }
            let suffix = match[2]!.lowercased()
            let next = match.nextWord ?? ""
            func ordinal(_ gender: Gender, _ grammaticalCase: Case, plural: Bool = false) -> String? {
                Numerals.ordinal(number, gender: gender, plural: plural, case: grammaticalCase)
            }
            switch suffix {
            case "й", "ый": return ordinal(.masculine, .nominative)
            case "ой":
                // «2-ой» is «второй»; «5-ой» is «пятой».
                let masculine = ordinal(.masculine, .nominative)
                return masculine?.hasSuffix("ой") == true ? masculine : ordinal(.feminine, .genitive)
            case "го", "ого": return ordinal(.masculine, .genitive)
            case "му", "ому": return ordinal(.masculine, .dative)
            case "ом": return ordinal(.masculine, .prepositional)
            case "ым": return ordinal(.masculine, .instrumental)
            case "м":
                let instrumental = ["с", "со", "под", "над", "перед", "за", "между"].contains(match.previousWord ?? "")
                return ordinal(.masculine, instrumental ? .instrumental : .prepositional)
            case "я", "ая": return ordinal(.feminine, .nominative)
            case "ю", "ую": return ordinal(.feminine, .accusative)
            case "е", "ое":
                // «90-е годы».
                let decade = number % 10 == 0 && (20 ... 90).contains(number % 100)
                return next.hasPrefix("год") || decade ? ordinal(.masculine, .nominative, plural: true) : ordinal(.neuter, .nominative)
            case "ые": return ordinal(.masculine, .nominative, plural: true)
            case "х" where (2 ... 4).contains(number): return Numerals.cardinal(number, case: .genitive)
            case "х", "ых": return ordinal(.masculine, .genitive, plural: true)
            case "ыми": return ordinal(.masculine, .instrumental, plural: true)
            case "ти", "ми", "ка": return Numerals.cardinal(number, case: .genitive)
            case "мя": return Numerals.cardinal(number, case: .instrumental)
            default: return nil
            }
        }
    }
    private static let suffixedNumber = regex(start + #"(\d{1,6})-(ого|ому|ыми|ый|ой|ая|ое|ые|ым|ом|ую|ых|го|му|ми|мя|ти|ка|й|я|е|х|ю|м)(?![\p{L}\d-])"#)

    private static func isYear(_ number: Int) -> Bool { (1000 ... 2999).contains(number) }

    /// «в 1984 году» → «в тысяча девятьсот восемьдесят четвёртом году», «2024 года» → «…четвёртого года».
    private static func years(_ text: String) -> String {
        replace(text, year) { match in
            guard let number = Int(match[1]!), isYear(number) else { return nil }
            let noun = match[2]!.lowercased()
            let previous = match.previousWord ?? ""
            let (word, grammaticalCase): (String, Case) = switch noun {
            case "год": ("год", .nominative)
            case "года": ("года", .genitive)
            case "году": ("году", ["к", "ко", "по"].contains(previous) ? .dative : .prepositional)
            case "годом": ("годом", .instrumental)
            case "годе": ("годе", .prepositional)
            default:
                switch previous {
                case "в", "во": ("году", .prepositional)
                case "к", "ко": ("году", .dative)
                default: ("года", .genitive)
                }
            }
            guard let spoken = Numerals.ordinal(number, case: grammaticalCase) else { return nil }
            return spoken + " " + word + (noun == "г." && match.endsSentence ? "." : "")
        }
    }
    private static let year = regex(start + #"(\d{4})\s?(годом|годе|году|года|год|г\.)(?![\p{L}])"#)

    /// A year with no «год» after it: «в 2019» → «в две тысячи девятнадцатом», «15 марта 2024» → «… четвёртого года».
    private static func bareYears(_ text: String) -> String {
        replace(text, bareYear) { match in
            guard let number = Int(match[1]!) else { return nil }
            let previous = match.previousWord ?? ""
            func ordinal(_ grammaticalCase: Case) -> String? { Numerals.ordinal(number, case: grammaticalCase) }
            if months.contains(previous) { return ordinal(.genitive).map { $0 + " года" } }
            // After «в» any year; after the others only recent ones, which are rarely amounts.
            let recent = (1900 ... 2099).contains(number)
            switch previous {
            case "в", "во": return ordinal(.prepositional)
            case "с", "со", "до", "от", "после", "около": return recent ? ordinal(.genitive) : nil
            case "к", "ко": return recent ? ordinal(.dative) : nil
            default: return nil
            }
        }
    }
    private static let bareYear = regex(start + #"(1[5-9]\d\d|20\d\d)(?=\s*(?:[.,;!?…)»"]|$|—|–))(?![.,]\d)"#)

    /// «15 марта» → «пятнадцатого марта», «на 15 марта» → «на пятнадцатое марта».
    private static func monthDates(_ text: String) -> String {
        replace(text, monthDate) { match in
            guard let day = Int(match[1]!), (1 ... 31).contains(day),
                  let spoken = Numerals.ordinal(day, gender: .neuter, case: dayCase(match.previousWord)) else { return nil }
            return spoken + " " + match[2]!
        }
    }
    private static let monthDate = regex(start + #"(\d{1,2})\s("# + months.joined(separator: "|") + #")(?![\p{L}])"#)

    // MARK: Quantities

    private static let scales: [String: Noun] = ["тыс": Numerals.thousand, "млн": Numerals.million, "млрд": Numerals.billion]

    private static let ruble = Noun(gender: .masculine,
                                    singular: ["рубль", "рубля", "рублю", "рубль", "рублём", "рубле"],
                                    plural: ["рублей", "рублям", "рублями", "рублях"])
    private static let kopeck = Noun(gender: .feminine,
                                     singular: ["копейка", "копейки", "копейке", "копейку", "копейкой", "копейке"],
                                     plural: ["копеек", "копейкам", "копейками", "копейках"])
    private static let euro = Noun(gender: .masculine, singular: [String](repeating: "евро", count: 6), plural: [String](repeating: "евро", count: 4))
    private static let degree = Noun.hard("градус")

    private static let dollar = Noun.hard("доллар")
    private static let pound = Noun.hard("фунт")
    private static let cent = Noun.hard("цент")

    private struct Unit {
        let noun: Noun
        /// The hundredth part of a currency: «9,99 $» is «девять долларов девяносто девять центов».
        var minor: Noun?
    }

    /// Units written before or after a number, lowercased and without the dot.
    private static let units: [String: Unit] = [
        "$": Unit(noun: dollar, minor: cent), "€": Unit(noun: euro, minor: cent), "£": Unit(noun: pound, minor: .hard("пенс")),
        "₽": Unit(noun: ruble, minor: kopeck), "руб": Unit(noun: ruble, minor: kopeck), "р": Unit(noun: ruble, minor: kopeck),
        "коп": Unit(noun: kopeck), "%": Unit(noun: .hard("процент")),
        "°": Unit(noun: degree), "°c": Unit(noun: .hard("градус", tail: " Цельсия")), "°с": Unit(noun: .hard("градус", tail: " Цельсия")),
        "°f": Unit(noun: .hard("градус", tail: " Фаренгейта")),
        "км/ч": Unit(noun: .hard("километр", tail: " в час")), "м/с": Unit(noun: .hard("метр", tail: " в секунду")),
        "км": Unit(noun: .hard("километр")), "м": Unit(noun: .hard("метр")), "см": Unit(noun: .hard("сантиметр")),
        "мм": Unit(noun: .hard("миллиметр")), "кг": Unit(noun: .hard("килограмм")), "г": Unit(noun: .hard("грамм")),
        "мг": Unit(noun: .hard("миллиграмм")), "л": Unit(noun: .hard("литр")), "мл": Unit(noun: .hard("миллилитр")),
        "ч": Unit(noun: hour), "мин": Unit(noun: .feminine("минут")), "сек": Unit(noun: .feminine("секунд")),
    ]

    private static func unit(_ written: String?) -> Unit? {
        written.flatMap { units[$0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))] }
    }

    /// «$200» → «двести долларов», «$3 млн» → «три миллиона долларов».
    private static func money(_ text: String) -> String {
        replace(text, prefixedMoney) { match in
            quantity(match, integer: match[2]!, fraction: match[3], scale: match[4], unit: unit(match[1]))
        }
    }
    private static let prefixedMoney = regex(#"([$€£₽])\s?(\d+)(?:[.,](\d+))?(?:\s?(тыс|млн|млрд)\.?)?"# + end)

    /// Every number still written in digits, with its sign, scale and unit: «-15°C», «2,5 кг», «3 млн», «25%».
    private static func quantities(_ text: String) -> String {
        replace(text, quantityPattern) { match in
            let unit = unit(match[5])
            var spoken = quantity(match, integer: match[2]!, fraction: match[3], scale: match[4], unit: unit)
            if let sign = match[1] {
                // A sign only at the start of a token («5-7» is a range), and not a dialogue dash opening a sentence.
                let attached = match.before.last.map { !$0.isWhitespace && $0 != "(" } ?? false
                let dash = match.startsSentence && sign != "+" && match[5]?.hasPrefix("°") != true
                if dash {
                    spoken = sign + spoken.prefix(1).uppercased() + spoken.dropFirst()
                } else {
                    spoken = attached ? sign + spoken : (sign == "+" ? "плюс " : "минус ") + spoken
                }
            }
            return spoken + (match.whole.hasSuffix(".") && match.endsSentence ? "." : "")
        }
    }
    private static let quantityPattern = regex(
        #"(?<![\p{L}\d])([-−+])?(\d+)(?:[.,](\d+))?"#
            + #"(?:\s?(тыс|млн|млрд)(?:\.|(?![\p{L}])))?"#
            + #"(?:\s?(°[CСF]?|%|[$€£₽]|км/ч|м/с|(?:руб|коп|мин|сек)(?:\.|(?![\p{L}]))|(?:кг|км|см|мм|мг|мл|р\.|[гмлч])(?![\p{L}/])))?"#
            + #"(?![\p{L}\d])"#
    )

    /// The words of one quantity. Fractions are always read in the nominative.
    private static func quantity(_ match: Match, integer: String, fraction: String?, scale: String?, unit: Unit?) -> String {
        let scaleNoun = scale.flatMap { scales[$0.lowercased()] }
        // The noun the number agrees with, and what follows it: «три миллиона» + «долларов».
        let counted = scaleNoun ?? unit?.noun
        let trailer = scaleNoun != nil ? unit.map { " " + $0.noun.genitivePlural } ?? "" : ""
        guard let number = Int(integer), number < Numerals.limit, !(integer.hasPrefix("0") && integer.count > 1) else {
            return Numerals.digits(integer) + (fraction.map { " " + Numerals.digits($0) } ?? "")
                + (counted.map { " " + $0.genitivePlural } ?? "") + trailer
        }
        let nounGender = counted?.gender ?? gender(of: match.nextWord)

        if let fraction, let value = Int(fraction) {
            let half = fraction == "5" || fraction == "50"
            let words: String
            let noun: String?
            if let unit, let minor = unit.minor, scaleNoun == nil, fraction.count == 2 {
                return Numerals.cardinal(number, gender: unit.noun.gender) + " " + unit.noun.counted(number)
                    + " " + Numerals.cardinal(value, gender: minor.gender) + " " + minor.counted(value)
            } else if half, number == 1 {
                words = nounGender == .feminine ? "полторы" : "полтора"
                noun = counted?.genitiveSingular
            } else if half, number > 1 {
                words = Numerals.cardinal(number, gender: nounGender) + " с половиной"
                noun = counted?.counted(number)
            } else if fraction.count <= 3 {
                let part = ["десят", "сот", "тысячн"][fraction.count - 1]
                func single(_ n: Int) -> Bool { n % 10 == 1 && n % 100 != 11 }
                words = Numerals.cardinal(number, gender: .feminine) + (single(number) ? " целая " : " целых ")
                    + Numerals.cardinal(value, gender: .feminine) + " " + part + (single(value) ? "ая" : "ых")
                noun = counted?.genitiveSingular
            } else {
                words = Numerals.cardinal(number) + " запятая " + Numerals.digits(fraction)
                noun = counted?.genitiveSingular
            }
            return words + (noun.map { " " + $0 } ?? "") + trailer
        }

        var grammaticalCase = numberCase(match)
        // «ждал 1 минуту»: the noun shows the accusative.
        if counted == nil, grammaticalCase == .nominative, nounGender == .feminine, number % 10 == 1, number % 100 != 11,
           let next = match.nextWord, next.hasSuffix("у") || next.hasSuffix("ю") {
            grammaticalCase = .accusative
        }
        let words = Numerals.cardinal(number, gender: nounGender, case: grammaticalCase)
        return words + (counted.map { " " + $0.counted(number, grammaticalCase) } ?? "") + trailer
    }

    /// Spaces left by the rules.
    private static func tidy(_ text: String) -> String {
        var text = text
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: " ,", with: ",")
    }
}
