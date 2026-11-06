import Foundation

/// The text rules of RUAccent 1.5.8.3, ported scalar for scalar so the output matches the Python library
/// (with the fixes listed in `RussianStressMarker`). Python strings index code points, so everything here works
/// on `Unicode.Scalar` arrays.
enum StressText {
    typealias Scalars = [Unicode.Scalar]

    static let acute: Unicode.Scalar = "\u{0301}"
    static let plus: Unicode.Scalar = "+"

    // MARK: Character classes

    /// Python's `str.isspace()`, which is what `\s` matches in RUAccent's regular expressions.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            true
        default:
            false
        }
    }

    static func isCyrillic(_ s: Unicode.Scalar) -> Bool {
        (0x410...0x44F).contains(s.value) || s.value == 0x401 || s.value == 0x451
    }

    /// `\w` on normalized text, which contains only ASCII letters and digits, Russian letters, whitespace
    /// and the punctuation `normalize` keeps.
    static func isWord(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: isCyrillic(s)
        }
    }

    private static let keptPunctuation = Set(".,!?:;'(){}[]«»„“”-—".unicodeScalars)

    /// RUAccent's `normalize` pattern: `[^a-zA-Z0-9\sа-яА-ЯёЁ—.,!?:;''(){}\[\]«»„“”-]` is removed.
    static func isKept(_ s: Unicode.Scalar) -> Bool {
        isWord(s) || isSpace(s) || keptPunctuation.contains(s)
    }

    static func normalize(_ text: Scalars) -> Scalars {
        text.filter(isKept)
    }

    private static let vowels = Set("аеёиоуыэюяАЕЁИОУЫЭЮЯ".unicodeScalars)
    static func countVowels(_ text: Scalars) -> Int { text.reduce(0) { $0 + (vowels.contains($1) ? 1 : 0) } }

    private static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)
    static func hasPunctuation(_ text: Scalars) -> Bool { text.contains(where: asciiPunctuation.contains) }

    // MARK: Case

    static func lower(_ text: Scalars) -> Scalars { Array(String(String.UnicodeScalarView(text)).lowercased().unicodeScalars) }
    static func upper(_ text: Scalars) -> Scalars { Array(String(String.UnicodeScalarView(text)).uppercased().unicodeScalars) }

    /// Python `str.isupper()` for one code point.
    static func isUpper(_ s: Unicode.Scalar) -> Bool { s.properties.isUppercase }

    /// Python `str.islower()`: at least one cased character and no uppercase or titlecase one.
    static func isLowerPython(_ text: Scalars) -> Bool {
        var cased = false
        for s in text {
            if s.properties.isUppercase || s.properties.generalCategory == .titlecaseLetter { return false }
            if s.properties.isLowercase { cased = true }
        }
        return cased
    }

    /// RUAccent's `fix_capital`: the target in the source's letter case, position by position; an unchanged
    /// target if the lengths differ.
    static func fixCapital(source: Scalars, target: Scalars) -> Scalars {
        guard source.count == target.count else { return target }
        var out = Scalars()
        out.reserveCapacity(target.count)
        for (s, t) in zip(source, target) {
            out += isUpper(s) ? upper([t]) : lower([t])
        }
        return out
    }

    // MARK: Splitting

    static func replace(_ text: Scalars, _ pattern: Scalars, with replacement: Scalars) -> Scalars {
        guard !pattern.isEmpty, text.count >= pattern.count else { return text }
        var out = Scalars()
        out.reserveCapacity(text.count)
        var i = 0
        while i < text.count {
            if i + pattern.count <= text.count, text[i ..< i + pattern.count].elementsEqual(pattern) {
                out += replacement
                i += pattern.count
            } else {
                out.append(text[i])
                i += 1
            }
        }
        return out
    }

    /// A word of `split_by_words`: a run of word characters or a run of other non-space characters.
    struct Token {
        let start: Int
        let end: Int
    }

    /// The tokens of `re.finditer(r"\w*(?:\+\w+)*|[^\w\s]+", text)` that are not empty. `+` never reaches it
    /// (normalize removes it), so a word is a plain run of word characters.
    static func tokens(_ text: Scalars) -> [Token] {
        var result: [Token] = []
        var i = 0
        while i < text.count {
            let s = text[i]
            if isSpace(s) {
                i += 1
                continue
            }
            let word = isWord(s)
            var j = i + 1
            while j < text.count, !isSpace(text[j]), isWord(text[j]) == word { j += 1 }
            result.append(Token(start: i, end: j))
            i = j
        }
        return result
    }

    /// `TextPreprocessor.split_by_words`: the words (from the text with " - " turned into " ~ ") and the text
    /// before, between and after them, so that `gaps[0] + words[0] + gaps[1] + … + gaps[n]` rebuilds it.
    static func splitByWords(_ sentence: Scalars) -> (words: [Scalars], gaps: [Scalars]) {
        let text = replace(sentence, Array(" - ".unicodeScalars), with: Array(" ~ ".unicodeScalars))
        let tokens = tokens(text)
        guard !tokens.isEmpty else { return ([], [[], []]) }
        var words: [Scalars] = [], gaps: [Scalars] = []
        var previousEnd = 0
        for token in tokens {
            gaps.append(Array(text[previousEnd ..< token.start]))
            words.append(Array(text[token.start ..< token.end]))
            previousEnd = token.end
        }
        gaps.append(Array(text[previousEnd...]))
        return (words, gaps)
    }

    /// Start offsets of `splitByWords` words in `sentence`.
    static func wordStarts(_ sentence: Scalars) -> [Int] {
        tokens(replace(sentence, Array(" - ".unicodeScalars), with: Array(" ~ ".unicodeScalars))).map(\.start)
    }

    private static let sentenceEnders = Set(".!?…".unicodeScalars)
    private static let closers = Set("»\"”)]".unicodeScalars)

    /// Sentences for `[.!?…]+[»"”)\]]*(?=\s)`: each piece ends after such a run; leading whitespace goes with
    /// the following sentence. (RUAccent uses razdel here; see `RussianStressMarker`.)
    static func splitSentences(_ text: Scalars) -> [Scalars] {
        var pieces: [Scalars] = []
        var start = 0, i = 0
        while i < text.count {
            guard sentenceEnders.contains(text[i]) else {
                i += 1
                continue
            }
            var j = i
            while j < text.count, sentenceEnders.contains(text[j]) { j += 1 }
            while j < text.count, closers.contains(text[j]) { j += 1 }
            if j < text.count, isSpace(text[j]) {
                pieces.append(Array(text[start ..< j]))
                start = j
                i = j
            } else {
                i += 1
            }
        }
        if start < text.count { pieces.append(Array(text[start...])) }
        return pieces.filter { !$0.isEmpty }
    }

    /// RUAccent's `delete_spaces_before_punc`, replacement by replacement.
    static func deleteSpacesBeforePunctuation(_ text: Scalars) -> Scalars {
        var t = text
        let space: Unicode.Scalar = " "
        for p in "!\"#$%&'()*,./:;<=>?@[\\]^_`{|}-".unicodeScalars {
            if p == "-" {
                t = replace(t, [space, p], with: [p])
                t = replace(t, [p, space], with: [p])
            }
            t = replace(t, [space, p], with: [p])
        }
        return replace(t, ["~"], with: ["-"])
    }

    /// `re.sub(r'\s+(?=(?:[,.?!:;…]))', '', text)`: whitespace runs right before punctuation are removed.
    static func removeSpacesBeforeSentencePunctuation(_ text: Scalars) -> Scalars {
        let marks = Set(",.?!:;…".unicodeScalars)
        var out = Scalars()
        var i = 0
        while i < text.count {
            if isSpace(text[i]) {
                var j = i
                while j < text.count, isSpace(text[j]) { j += 1 }
                if j < text.count, marks.contains(text[j]) {
                    i = j
                    continue
                }
                out += text[i ..< j]
                i = j
            } else {
                out.append(text[i])
                i += 1
            }
        }
        return out
    }

    // MARK: Marks

    /// `re.sub(r'\+(.)', '\1́', text)`: a plus before a character becomes an acute accent after it.
    static func plusToAcute(_ text: Scalars) -> Scalars {
        var out = Scalars()
        out.reserveCapacity(text.count)
        var i = 0
        while i < text.count {
            if text[i] == plus, i + 1 < text.count, text[i + 1] != "\n" {
                out.append(text[i + 1])
                out.append(acute)
                i += 2
            } else {
                out.append(text[i])
                i += 1
            }
        }
        return out
    }

    /// RUAccent's transfer of the dictionary form's `+` marks onto the word as written (keeps its letter case).
    static func transferPlus(from stressed: Scalars, to word: Scalars) -> Scalars {
        var fixed = word
        var j = 0
        for (index, s) in stressed.enumerated() where s == plus {
            fixed = Array(fixed.prefix(index + j)) + [plus] + Array(word.dropFirst(index))
            j += 1
        }
        return fixed
    }
}

extension Array where Element == Unicode.Scalar {
    init(_ string: String) { self = Array(string.unicodeScalars) }
    var string: String { String(String.UnicodeScalarView(self)) }
}
