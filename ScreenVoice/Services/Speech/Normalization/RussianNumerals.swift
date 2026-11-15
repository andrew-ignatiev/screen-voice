import Foundation

/// Russian numbers in words: cardinals and ordinals in any case, and nouns counted by them.
enum RussianNumerals {
    enum Gender: Sendable { case masculine, feminine, neuter }

    /// The raw value indexes a `Forms` array.
    enum Case: Int, Sendable { case nominative, genitive, dative, accusative, instrumental, prepositional }

    /// One word in the six cases, in `Case` order.
    typealias Forms = [String]

    /// The largest number spelled out; longer digit strings are read digit by digit.
    static let limit = 1_000_000_000_000

    // MARK: Nouns

    /// A noun counted by a number: «один рубль, два рубля, пять рублей, к пяти рублям».
    struct Noun: Sendable {
        let gender: Gender
        let singular: Forms
        /// Genitive, dative, instrumental and prepositional plural.
        let plural: [String]
        /// Words that follow the noun unchanged («километр в час»).
        var tail = ""

        func counted(_ number: Int, _ grammaticalCase: Case = .nominative) -> String {
            let word: String
            let one = number % 10 == 1 && number % 100 != 11
            let few = (2 ... 4).contains(number % 10) && !(12 ... 14).contains(number % 100)
            switch grammaticalCase {
            case .nominative, .accusative:
                word = one ? singular[grammaticalCase.rawValue] : few ? singular[Case.genitive.rawValue] : plural[0]
            case .genitive: word = one ? singular[1] : plural[0]
            case .dative: word = one ? singular[2] : plural[1]
            case .instrumental: word = one ? singular[4] : plural[2]
            case .prepositional: word = one ? singular[5] : plural[3]
            }
            return word + tail
        }

        /// After a fraction or «полтора»: «полтора литра», «две целых пять десятых литра».
        var genitiveSingular: String { singular[1] + tail }
        var genitivePlural: String { plural[0] + tail }

        /// «доллар»: доллара, долларов.
        static func hard(_ stem: String, tail: String = "") -> Noun {
            Noun(gender: .masculine,
                 singular: [stem, stem + "а", stem + "у", stem, stem + "ом", stem + "е"],
                 plural: [stem + "ов", stem + "ам", stem + "ами", stem + "ах"], tail: tail)
        }

        /// «минута» from the stem «минут»: минуты, минут.
        static func feminine(_ stem: String, tail: String = "") -> Noun {
            Noun(gender: .feminine,
                 singular: [stem + "а", stem + "ы", stem + "е", stem + "у", stem + "ой", stem + "е"],
                 plural: [stem, stem + "ам", stem + "ами", stem + "ах"], tail: tail)
        }
    }

    static let thousand = Noun(gender: .feminine,
                               singular: ["тысяча", "тысячи", "тысяче", "тысячу", "тысячей", "тысяче"],
                               plural: ["тысяч", "тысячам", "тысячами", "тысячах"])
    static let million = Noun.hard("миллион")
    static let billion = Noun.hard("миллиард")

    // MARK: Cardinals

    private static func soft(_ word: String, stem: String? = nil) -> Forms {
        let stem = stem ?? String(word.dropLast())
        return [word, stem + "и", stem + "и", word, stem + "ью", stem + "и"]
    }

    private static let zero: Forms = ["ноль", "ноля", "нолю", "ноль", "нолём", "ноле"]
    private static let one: [Gender: Forms] = [
        .masculine: ["один", "одного", "одному", "один", "одним", "одном"],
        .feminine: ["одна", "одной", "одной", "одну", "одной", "одной"],
        .neuter: ["одно", "одного", "одному", "одно", "одним", "одном"],
    ]
    private static let two: Forms = ["два", "двух", "двум", "два", "двумя", "двух"]
    /// 3...19.
    private static let small: [Forms] = [
        ["три", "трёх", "трём", "три", "тремя", "трёх"],
        ["четыре", "четырёх", "четырём", "четыре", "четырьмя", "четырёх"],
        soft("пять"), soft("шесть"), soft("семь"),
        ["восемь", "восьми", "восьми", "восемь", "восемью", "восьми"],
        soft("девять"), soft("десять"), soft("одиннадцать"), soft("двенадцать"), soft("тринадцать"),
        soft("четырнадцать"), soft("пятнадцать"), soft("шестнадцать"), soft("семнадцать"),
        soft("восемнадцать"), soft("девятнадцать"),
    ]
    /// 20, 30 ... 90.
    private static let tens: [Forms] = [
        soft("двадцать"), soft("тридцать"),
        ["сорок", "сорока", "сорока", "сорок", "сорока", "сорока"],
        ["пятьдесят", "пятидесяти", "пятидесяти", "пятьдесят", "пятьюдесятью", "пятидесяти"],
        ["шестьдесят", "шестидесяти", "шестидесяти", "шестьдесят", "шестьюдесятью", "шестидесяти"],
        ["семьдесят", "семидесяти", "семидесяти", "семьдесят", "семьюдесятью", "семидесяти"],
        ["восемьдесят", "восьмидесяти", "восьмидесяти", "восемьдесят", "восемьюдесятью", "восьмидесяти"],
        ["девяносто", "девяноста", "девяноста", "девяносто", "девяноста", "девяноста"],
    ]
    /// 100, 200 ... 900.
    private static let hundreds: [Forms] = [
        ["сто", "ста", "ста", "сто", "ста", "ста"],
        ["двести", "двухсот", "двумстам", "двести", "двумястами", "двухстах"],
        ["триста", "трёхсот", "трёмстам", "триста", "тремястами", "трёхстах"],
        ["четыреста", "четырёхсот", "четырёмстам", "четыреста", "четырьмястами", "четырёхстах"],
        ["пятьсот", "пятисот", "пятистам", "пятьсот", "пятьюстами", "пятистах"],
        ["шестьсот", "шестисот", "шестистам", "шестьсот", "шестьюстами", "шестистах"],
        ["семьсот", "семисот", "семистам", "семьсот", "семьюстами", "семистах"],
        ["восемьсот", "восьмисот", "восьмистам", "восемьсот", "восемьюстами", "восьмистах"],
        ["девятьсот", "девятисот", "девятистам", "девятьсот", "девятьюстами", "девятистах"],
    ]

    /// The words of 1...999.
    private static func triple(_ number: Int, _ gender: Gender, _ grammaticalCase: Case) -> [String] {
        let c = grammaticalCase.rawValue
        var words: [String] = []
        if number >= 100 { words.append(hundreds[number / 100 - 1][c]) }
        let rest = number % 100
        if rest >= 20 {
            words.append(tens[rest / 10 - 2][c])
        }
        let unit = rest >= 20 ? rest % 10 : rest
        switch unit {
        case 0: break
        case 1: words.append(one[gender]![c])
        case 2:
            let direct = grammaticalCase == .nominative || grammaticalCase == .accusative
            words.append(direct && gender == .feminine ? "две" : two[c])
        default: words.append(small[unit - 3][c])
        }
        return words
    }

    /// `number` (0 ..< `limit`) in words: «тысяча пятьсот», «двадцати одной».
    static func cardinal(_ number: Int, gender: Gender = .masculine, case grammaticalCase: Case = .nominative) -> String {
        guard number > 0 else { return zero[grammaticalCase.rawValue] }
        var words: [String] = []
        var rest = number
        for (value, noun) in [(1_000_000_000, billion), (1_000_000, million), (1000, thousand)] {
            let count = rest / value
            rest %= value
            guard count > 0 else { continue }
            // «тысяча», not «одна тысяча».
            if count > 1 { words += triple(count, noun.gender, grammaticalCase) }
            words.append(noun.counted(count, grammaticalCase))
        }
        words += triple(rest, gender, grammaticalCase)
        return words.joined(separator: " ")
    }

    /// Digits read one by one: phone numbers, codes, numbers that start with zero.
    static func digits(_ text: String) -> String {
        text.compactMap { $0.wholeNumberValue }.map { cardinal($0) }.joined(separator: " ")
    }

    /// The number as the first part of a compound word: «пяти» + «летний», «одно» + «комнатная».
    static func compoundPrefix(_ number: Int) -> String? {
        guard (1 ..< 1000).contains(number) else { return number == 1000 ? "тысяче" : nil }
        var prefix = ""
        if number >= 100 { prefix += number / 100 == 1 ? "сто" : hundreds[number / 100 - 1][1] }
        let rest = number % 100
        if rest >= 20 { prefix += rest / 10 == 9 ? "девяносто" : tens[rest / 10 - 2][1] }
        let unit = rest >= 20 ? rest % 10 : rest
        switch unit {
        case 0: break
        case 1: prefix += "одно"
        case 2: prefix += "двух"
        default: prefix += small[unit - 3][1]
        }
        return prefix
    }

    // MARK: Ordinals

    /// Masculine nominative of the last word of an ordinal.
    private static let ordinalUnits = [
        "первый", "второй", "третий", "четвёртый", "пятый", "шестой", "седьмой", "восьмой", "девятый", "десятый",
        "одиннадцатый", "двенадцатый", "тринадцатый", "четырнадцатый", "пятнадцатый", "шестнадцатый",
        "семнадцатый", "восемнадцатый", "девятнадцатый",
    ]
    private static let ordinalTens = [
        "двадцатый", "тридцатый", "сороковой", "пятидесятый", "шестидесятый", "семидесятый", "восьмидесятый", "девяностый",
    ]
    private static let ordinalHundreds = [
        "сотый", "двухсотый", "трёхсотый", "четырёхсотый", "пятисотый", "шестисотый", "семисотый", "восьмисотый", "девятисотый",
    ]

    private static let hardEndings: [Gender: Forms] = [
        .masculine: ["ый", "ого", "ому", "ый", "ым", "ом"],
        .feminine: ["ая", "ой", "ой", "ую", "ой", "ой"],
        .neuter: ["ое", "ого", "ому", "ое", "ым", "ом"],
    ]
    private static let hardPlural: Forms = ["ые", "ых", "ым", "ые", "ыми", "ых"]
    private static let third: [Gender: Forms] = [
        .masculine: ["третий", "третьего", "третьему", "третий", "третьим", "третьем"],
        .feminine: ["третья", "третьей", "третьей", "третью", "третьей", "третьей"],
        .neuter: ["третье", "третьего", "третьему", "третье", "третьим", "третьем"],
    ]
    private static let thirdPlural: Forms = ["третьи", "третьих", "третьим", "третьи", "третьими", "третьих"]

    private static func decline(_ ordinal: String, _ gender: Gender, plural: Bool, _ grammaticalCase: Case) -> String {
        let c = grammaticalCase.rawValue
        if ordinal == "третий" { return plural ? thirdPlural[c] : third[gender]![c] }
        let direct = grammaticalCase == .nominative || grammaticalCase == .accusative
        // «второй», «сороковой» keep their stressed ending.
        if !plural, gender == .masculine, direct { return ordinal }
        return String(ordinal.dropLast(2)) + (plural ? hardPlural[c] : hardEndings[gender]![c])
    }

    /// `number` (0 ..< 1 000 000) as an ordinal: «тысяча девятьсот восемьдесят четвёртом», «двухтысячного».
    /// Nil for numbers it can't spell.
    static func ordinal(
        _ number: Int, gender: Gender = .masculine, plural: Bool = false, case grammaticalCase: Case = .nominative
    ) -> String? {
        guard (0 ..< 1_000_000).contains(number) else { return nil }
        if number == 0 { return decline("нулевой", gender, plural: plural, grammaticalCase) }
        let last: String
        let head: Int
        if (1 ... 19).contains(number % 100) {
            last = ordinalUnits[number % 100 - 1]
            head = number - number % 100
        } else if number % 10 != 0 {
            last = ordinalUnits[number % 10 - 1]
            head = number - number % 10
        } else if number % 100 != 0 {
            last = ordinalTens[number % 100 / 10 - 2]
            head = number - number % 100
        } else if number % 1000 != 0 {
            last = ordinalHundreds[number % 1000 / 100 - 1]
            head = number - number % 1000
        } else {
            let thousands = number / 1000
            guard let prefix = thousands == 1 ? "" : compoundPrefix(thousands) else { return nil }
            last = prefix + "тысячный"
            head = 0
        }
        let word = decline(last, gender, plural: plural, grammaticalCase)
        return head == 0 ? word : cardinal(head) + " " + word
    }

    /// The value of a Roman numeral up to 399 (I, V, X, L, C), nil if it isn't one.
    static func roman(_ text: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
        var total = 0
        var previous = 0
        for character in text.reversed() {
            guard let value = values[character] else { return nil }
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        return total > 0 && total < 400 ? total : nil
    }
}
