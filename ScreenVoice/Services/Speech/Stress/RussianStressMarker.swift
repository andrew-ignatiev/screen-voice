import Foundation

/// Marks stress in Russian text for the stress LoRA: a port of RUAccent 1.5.8.3 (`process_all`, homograph model
/// turbo3.1, full dictionary) on ONNX Runtime, with three fixes, mirrored by the research reference
/// `ruaccent_fixed.py` the tests compare against:
/// 1. Model labels are matched to words by character offset. RUAccent matched them by list index, but its BERT
///    tokenizer splits "..." or "?!" into one token per character while its word splitter keeps them together,
///    so every label after such punctuation landed on the wrong word.
/// 2. Each homograph variant is scored on its own with a per-row softmax (the batched path normalised over the
///    whole batch, which changes the choice).
/// 3. Sentences are split after `[.!?…]+` (plus closing quotes or brackets) before whitespace, instead of razdel.
///
/// On top, as the LoRA's authors recommend: capitalized words are lowercased before marking (RUAccent stresses
/// them worse) and the `+` before a vowel becomes U+0301 after it.
final class RussianStressMarker: @unchecked Sendable {
    private let stressUsage: TokenClassifier
    private let yoResolver: TokenClassifier
    private let homographModel: ONNXModel
    private let homographTokenizer: ByteLevelBPETokenizer
    private let accentModel: ONNXModel
    private let accentVocabulary: [Unicode.Scalar: Int]
    private let accentIDs: (bos: Int, eos: Int, unknown: Int)
    private let accentPrimaryLabel: Int
    private let accents: StressDictionary
    private let homographs: [String: [String]]
    private let yoWords: [String: String]
    private let yoHomographs: [String: String]

    /// Loads the RUAccent files from `directory` (the stress pack's layout). Builds the dictionary table on
    /// first use, which takes a few seconds.
    init(directory: URL) throws {
        let nn = directory.appending(path: "nn", directoryHint: .isDirectory)
        let dictionary = directory.appending(path: "dictionary", directoryHint: .isDirectory)

        stressUsage = try TokenClassifier(directory: nn.appending(path: "nn_stress_usage_predictor"))
        yoResolver = try TokenClassifier(directory: nn.appending(path: "nn_yo_homograph_resolver"))

        let homographDirectory = nn.appending(path: "nn_omograph/turbo3.1")
        homographModel = try ONNXModel(file: homographDirectory.appending(path: "model.onnx"))
        homographTokenizer = try ByteLevelBPETokenizer(
            vocabularyFile: homographDirectory.appending(path: "vocab.json"),
            mergesFile: homographDirectory.appending(path: "merges.txt"),
            addedTokensFile: homographDirectory.appending(path: "added_tokens.json")
        )

        let accentDirectory = nn.appending(path: "nn_accent")
        accentModel = try ONNXModel(file: accentDirectory.appending(path: "model.onnx"))
        var vocabulary: [Unicode.Scalar: Int] = [:]
        var specials: [String: Int] = [:]
        let lines = try String(contentsOf: accentDirectory.appending(path: "vocab.txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let scalars = Array(line.unicodeScalars)
            if scalars.count == 1 {
                vocabulary[scalars[0]] = vocabulary[scalars[0]] ?? index
            } else if !scalars.isEmpty {
                specials[String(line)] = index
            }
        }
        guard let bos = specials["[bos]"], let eos = specials["[eos]"], let unknown = specials["[unk]"] else {
            throw RussianStressError.badFile("nn_accent/vocab.txt")
        }
        accentVocabulary = vocabulary
        accentIDs = (bos, eos, unknown)
        let accentLabels = try TokenClassifier.labels(accentDirectory.appending(path: "config.json"))
        guard let primary = accentLabels.firstIndex(of: "STRESS_PRIMARY") else {
            throw RussianStressError.badFile("nn_accent/config.json")
        }
        accentPrimaryLabel = primary

        accents = try StressDictionary.open(source: dictionary.appending(path: "accents.json.gz"))
        var homographs = try Self.json([String: [String]].self, dictionary.appending(path: "omographs.json.gz"))
        homographs["коса"] = ["к+оса", "кос+а"]
        self.homographs = homographs
        yoWords = try Self.json([String: String].self, dictionary.appending(path: "yo_words.json.gz"))
        yoHomographs = try Self.json([String: String].self, dictionary.appending(path: "yo_homographs.json.gz"))
    }

    private static func json<T: Decodable>(_ type: T.Type, _ file: URL) throws -> T {
        try JSONDecoder().decode(type, from: StressDictionary.gunzip(Data(contentsOf: file)))
    }

    // MARK: App entry point

    /// `text` with U+0301 after every stressed vowel RUAccent finds.
    func mark(_ text: String) throws -> String {
        let words = Self.split(Array(text.unicodeScalars), on: " ")
        let title = words.map { $0.count > 1 && StressText.isUpper($0[0]) && StressText.isLowerPython(Array($0.dropFirst())) }
        let lowered = zip(words, title).map { $1 ? StressText.lower($0) : $0 }
        let raw = try processAll(Array(lowered.joined(separator: [" "])))
        var marked = Self.split(raw, on: " ")
        if marked.count == words.count {
            for k in marked.indices where title[k] {
                var m = marked[k]
                m = StressText.upper(Array(m.prefix(1))) + Array(m.dropFirst())
                if m.first == StressText.plus {
                    m = [StressText.plus] + StressText.upper(Array(m.dropFirst().prefix(1))) + Array(m.dropFirst(2))
                }
                marked[k] = m
            }
        }
        return StressText.plusToAcute(Array(marked.joined(separator: [" "]))).string
    }

    private static func split(_ text: [Unicode.Scalar], on separator: Unicode.Scalar) -> [[Unicode.Scalar]] {
        text.split(separator: separator, omittingEmptySubsequences: false).map(Array.init)
    }

    // MARK: RUAccent

    /// `RUAccent.process_all` with the fixes in the type comment; `+` before stressed vowels.
    func processAll(_ text: [Unicode.Scalar]) throws -> [Unicode.Scalar] {
        var output: [Unicode.Scalar] = []
        for sentence in StressText.splitSentences(StressText.normalize(text)) {
            let (words, gaps) = StressText.splitByWords(sentence)
            if words.isEmpty {
                output += gaps.joined()
                continue
            }
            let starts = StressText.wordStarts(sentence)
            let usages = try stressUsage.labels(sentence, wordStarts: starts)
            var processed = try processYo(words, sentence: sentence, wordStarts: starts)
            processed = try processHomographs(processed)
            processed = try processAccent(processed, usages: usages)
            var rebuilt: [Unicode.Scalar] = []
            for (gap, word) in zip(gaps, processed) { rebuilt += gap + word }
            rebuilt += gaps[gaps.count - 1]
            output += StressText.deleteSpacesBeforePunctuation(rebuilt)
        }
        return output
    }

    private func processYo(_ words: [[Unicode.Scalar]], sentence: [Unicode.Scalar], wordStarts: [Int]) throws -> [[Unicode.Scalar]] {
        let lower = StressText.lower(sentence)
        let predictions = lower.contains("е") ? try yoResolver.labels(lower, wordStarts: wordStarts) : nil
        return words.enumerated().map { i, word in
            let key = StressText.lower(word).string
            var result = StressText.fixCapital(source: word, target: yoWords[key].map { Array($0.unicodeScalars) } ?? word)
            if predictions?[i] == "YO" {
                result = StressText.fixCapital(source: word, target: yoHomographs[key].map { Array($0.unicodeScalars) } ?? word)
            }
            return result
        }
    }

    private func processHomographs(_ words: [[Unicode.Scalar]]) throws -> [[Unicode.Scalar]] {
        var result = words
        for (position, word) in words.enumerated() {
            guard let variants = homographs[word.string], !variants.isEmpty else { continue }
            var context = words
            context[position] = Array(" <w>".unicodeScalars) + word + Array("</w> ".unicodeScalars)
            let text = StressText.removeSpacesBeforeSentencePunctuation(
                StressText.deleteSpacesBeforePunctuation(Array(context.joined(separator: [" "])))
            ).string
            var best = (probability: -Float.infinity, index: 0)
            for (index, variant) in variants.enumerated() {
                var ids = homographTokenizer.pairIDs(text, variant)
                if ids.count > 512 { ids = Array(ids.prefix(511)) + [homographTokenizer.eosID] }
                let probabilities = ONNXModel.softmaxRows(try homographModel.logits(inputIDs: ids).values, width: 2)[0]
                if probabilities[1] > best.probability { best = (probabilities[1], index) }
            }
            result[position] = Array(variants[best.index].unicodeScalars)
        }
        return result
    }

    private func processAccent(_ words: [[Unicode.Scalar]], usages: [String]) throws -> [[Unicode.Scalar]] {
        var result = words
        for (i, word) in words.enumerated() {
            guard !word.contains(StressText.plus), usages[i] == "STRESS" else { continue }
            let lower = StressText.lower(word)
            let stressed = lower == ["о"] ? Array("+о".unicodeScalars) : (accents.stressed(lower) ?? lower)
            if stressed == lower, !StressText.hasPunctuation(lower), StressText.countVowels(lower) > 1 {
                result[i] = try putAccent(word)
            } else {
                result[i] = StressText.transferPlus(from: stressed, to: word)
            }
        }
        return result
    }

    /// RUAccent's character model for words missing from the dictionary.
    private func putAccent(_ word: [Unicode.Scalar]) throws -> [Unicode.Scalar] {
        let lower = StressText.lower(word)
        guard lower.count == word.count, lower.count + 2 <= 60 else { return word }
        let ids = [accentIDs.bos] + lower.map { accentVocabulary[StressText.lower([$0]).first ?? $0] ?? accentIDs.unknown } + [accentIDs.eos]
        let (values, shape) = try accentModel.logits(inputIDs: ids)
        let rows = ONNXModel.softmaxRows(values, width: shape.last ?? 3)
        var marks = [Int](repeating: 0, count: word.count)
        for (i, row) in rows.enumerated() {
            guard let score = row.max(), let label = row.firstIndex(of: score),
                  label == accentPrimaryLabel, score >= 0.55 else { continue }
            // Python's text[i - 1]: the [bos] row (-1) wraps to the last character; the [eos] row is past the end.
            let index = i == 0 ? word.count - 1 : i - 1
            if index >= 0, index < word.count { marks[index] += 1 }
        }
        var out: [Unicode.Scalar] = []
        for (index, s) in word.enumerated() {
            out += [Unicode.Scalar](repeating: StressText.plus, count: marks[index])
            out.append(s)
        }
        return out
    }
}

/// A BERT token classifier of RUAccent (stress usage, ё homographs): one label per word, averaged over the
/// word's WordPiece tokens like the Hugging Face pipeline's "average" aggregation.
private struct TokenClassifier {
    let model: ONNXModel
    let tokenizer: WordPieceTokenizer
    let labels: [String]

    init(directory: URL) throws {
        model = try ONNXModel(file: directory.appending(path: "model.onnx"))
        tokenizer = try WordPieceTokenizer(vocabularyFile: directory.appending(path: "vocab.txt"))
        labels = try Self.labels(directory.appending(path: "config.json"))
    }

    static func labels(_ config: URL) throws -> [String] {
        struct Config: Decodable { let id2label: [String: String] }
        let map = try JSONDecoder().decode(Config.self, from: Data(contentsOf: config)).id2label
        return try (0 ..< map.count).map { i in
            guard let label = map[String(i)] else { throw RussianStressError.badFile(config.lastPathComponent) }
            return label
        }
    }

    /// The label of the word starting at each of `wordStarts` (offsets in `text`).
    func labels(_ text: [Unicode.Scalar], wordStarts: [Int]) throws -> [String] {
        var tokens = tokenizer.tokenize(text)
        if tokens.count > 510 { tokens = Array(tokens.prefix(510)) }
        guard !tokens.isEmpty else { return wordStarts.map { _ in "" } }
        let (values, shape) = try model.logits(inputIDs: tokenizer.inputIDs(tokens))
        let width = shape.last ?? labels.count
        let rows = ONNXModel.softmaxRows(values, width: width)

        var byStart: [Int: String] = [:]
        var group: [[Float]] = []
        var groupStart = 0
        func close() {
            guard !group.isEmpty else { return }
            var mean = [Float](repeating: 0, count: width)
            for row in group { for k in 0 ..< width { mean[k] += row[k] } }
            var best = 0
            for k in 1 ..< width where mean[k] > mean[best] { best = k }
            byStart[groupStart] = labels[best]
            group = []
        }
        for (index, token) in tokens.enumerated() {
            if group.isEmpty || !token.isSubword {
                close()
                groupStart = token.start
            }
            group.append(rows[index + 1])
        }
        close()
        return wordStarts.map { byStart[$0] ?? "" }
    }
}
