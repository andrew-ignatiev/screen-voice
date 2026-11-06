import Foundation

/// The BERT tokenizer of RUAccent's token-classification models (Hugging Face `BertNormalizer` with
/// `lowercase: false, strip_accents: null`, `BertPreTokenizer`, `WordPiece` with `##`), with character offsets.
struct WordPieceTokenizer: Sendable {
    struct Token: Equatable {
        let id: Int
        /// Code-point offsets in the input.
        let start: Int
        let end: Int
        /// A `##` continuation of the previous token's word.
        let isSubword: Bool
    }

    let clsID: Int
    let sepID: Int
    let unknownID: Int
    private let vocabulary: [String: Int]
    private let maxCharactersPerWord = 100

    init(vocabularyFile: URL) throws {
        let text = try String(contentsOf: vocabularyFile, encoding: .utf8)
        var vocabulary: [String: Int] = [:]
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let token = String(line.hasSuffix("\r") ? line.dropLast() : line)
            if vocabulary[token] == nil { vocabulary[token] = index }
        }
        guard let cls = vocabulary["[CLS]"], let sep = vocabulary["[SEP]"], let unk = vocabulary["[UNK]"] else {
            throw RussianStressError.badFile(vocabularyFile.lastPathComponent)
        }
        self.vocabulary = vocabulary
        clsID = cls
        sepID = sep
        unknownID = unk
    }

    /// Tokens of `text` without `[CLS]`/`[SEP]`.
    func tokenize(_ text: [Unicode.Scalar]) -> [Token] {
        var tokens: [Token] = []
        for word in preTokenize(text) {
            tokens += wordPiece(word)
        }
        return tokens
    }

    /// `[CLS] tokens [SEP]` ids.
    func inputIDs(_ tokens: [Token]) -> [Int] { [clsID] + tokens.map(\.id) + [sepID] }

    // MARK: Steps

    private struct Word {
        var scalars: [Unicode.Scalar] = []
        var offsets: [Int] = []
    }

    /// BertNormalizer (clean_text) + BertPreTokenizer: control characters are dropped, whitespace splits,
    /// every punctuation character is a word of its own.
    private func preTokenize(_ text: [Unicode.Scalar]) -> [Word] {
        var words: [Word] = []
        var current = Word()
        func flush() {
            if !current.scalars.isEmpty { words.append(current) }
            current = Word()
        }
        for (offset, s) in text.enumerated() {
            if s.value == 0 || s.value == 0xFFFD || Self.isControl(s) { continue }
            if Self.isWhitespace(s) {
                flush()
            } else if Self.isPunctuation(s) {
                flush()
                words.append(Word(scalars: [s], offsets: [offset]))
            } else {
                current.scalars.append(s)
                current.offsets.append(offset)
            }
        }
        flush()
        return words
    }

    private func wordPiece(_ word: Word) -> [Token] {
        let chars = word.scalars
        let wordStart = word.offsets[0], wordEnd = word.offsets[chars.count - 1] + 1
        guard chars.count <= maxCharactersPerWord else {
            return [Token(id: unknownID, start: wordStart, end: wordEnd, isSubword: false)]
        }
        var pieces: [Token] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int?
            while start < end {
                let piece = (start > 0 ? "##" : "") + Array(chars[start ..< end]).string
                if let id = vocabulary[piece] {
                    found = id
                    break
                }
                end -= 1
            }
            guard let id = found else {
                return [Token(id: unknownID, start: wordStart, end: wordEnd, isSubword: false)]
            }
            pieces.append(Token(id: id, start: word.offsets[start], end: word.offsets[end - 1] + 1, isSubword: start > 0))
            start = end
        }
        return pieces
    }

    // MARK: Character classes (Hugging Face tokenizers)

    static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\r" || s.properties.isWhitespace
    }

    static func isControl(_ s: Unicode.Scalar) -> Bool {
        if s == "\t" || s == "\n" || s == "\r" { return false }
        switch s.properties.generalCategory {
        case .control, .format, .unassigned, .privateUse: return true
        default: return false
        }
    }

    static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 33...47, 58...64, 91...96, 123...126: return true
        default: break
        }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }
}
