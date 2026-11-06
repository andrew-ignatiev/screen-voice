import Foundation

/// The RoBERTa-style tokenizer of RUAccent's homograph model (Hugging Face `ByteLevel` pre-tokenizer without a
/// prefix space, `BPE`, `RobertaProcessing`). Its ~10 000 added tokens are whole stressed word forms
/// (`+атлас`, `зам+ок`, `<w>` …); they are matched first, leftmost-longest, as Hugging Face does.
final class ByteLevelBPETokenizer: @unchecked Sendable {
    let bosID: Int
    let eosID: Int
    private let vocabulary: [String: Int]
    private let ranks: [Pair: Int]
    private let addedTokens: Trie
    private let byteToUnicode: [Character]
    private let splitter: NSRegularExpression
    private var cache: [String: [Int]] = [:]
    private let lock = NSLock()

    private struct Pair: Hashable {
        let left: String
        let right: String
    }

    init(vocabularyFile: URL, mergesFile: URL, addedTokensFile: URL) throws {
        let vocabulary = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabularyFile))
        let added = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: addedTokensFile))
        guard let bos = vocabulary["<s>"], let eos = vocabulary["</s>"] else {
            throw RussianStressError.badFile(vocabularyFile.lastPathComponent)
        }
        self.vocabulary = vocabulary
        bosID = bos
        eosID = eos

        var ranks: [Pair: Int] = [:]
        var rank = 0
        for line in try String(contentsOf: mergesFile, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("#version") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            ranks[Pair(left: String(parts[0]), right: String(parts[1]))] = rank
            rank += 1
        }
        self.ranks = ranks

        let trie = Trie()
        for (content, id) in added { trie.insert(Array(content.unicodeScalars), id: id) }
        for special in ["<s>", "</s>", "<pad>", "<unk>", "<mask>"] {
            if let id = vocabulary[special] { trie.insert(Array(special.unicodeScalars), id: id) }
        }
        addedTokens = trie

        byteToUnicode = Self.makeByteToUnicode()
        splitter = try NSRegularExpression(
            pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
        )
    }

    /// `<s> first </s></s> second </s>` ids, as `tokenizer(first, second)` gives them.
    func pairIDs(_ first: String, _ second: String) -> [Int] {
        [bosID] + encode(first) + [eosID, eosID] + encode(second) + [eosID]
    }

    func encode(_ text: String) -> [Int] {
        let scalars = Array(text.unicodeScalars)
        var ids: [Int] = []
        var segmentStart = 0, i = 0
        while i < scalars.count {
            if let (length, id) = addedTokens.longestMatch(in: scalars, at: i) {
                if segmentStart < i { ids += encodePlain(Array(scalars[segmentStart ..< i]).string) }
                ids.append(id)
                i += length
                segmentStart = i
            } else {
                i += 1
            }
        }
        if segmentStart < scalars.count { ids += encodePlain(Array(scalars[segmentStart...]).string) }
        return ids
    }

    private func encodePlain(_ text: String) -> [Int] {
        let ns = text as NSString
        var ids: [Int] = []
        for match in splitter.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: match.range)
            ids += bpe(String(piece.utf8.map { byteToUnicode[Int($0)] }))
        }
        return ids
    }

    private func bpe(_ token: String) -> [Int] {
        lock.lock()
        if let cached = cache[token] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var symbols = token.map { String($0) }
        while symbols.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0 ..< symbols.count - 1 {
                if let rank = ranks[Pair(left: symbols[i], right: symbols[i + 1])], rank < (best?.rank ?? .max) {
                    best = (rank, i)
                }
            }
            guard let best else { break }
            let left = symbols[best.index], right = symbols[best.index + 1]
            var merged: [String] = []
            merged.reserveCapacity(symbols.count)
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1, symbols[i] == left, symbols[i + 1] == right {
                    merged.append(left + right)
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }
        let ids = symbols.compactMap { vocabulary[$0] }
        lock.lock()
        cache[token] = ids
        lock.unlock()
        return ids
    }

    /// GPT-2's reversible byte → printable character table.
    private static func makeByteToUnicode() -> [Character] {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var chars = bytes
        var n = 0
        for b in 0 ..< 256 where !bytes.contains(b) {
            bytes.append(b)
            chars.append(256 + n)
            n += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bytes, chars) { table[b] = Character(Unicode.Scalar(UInt32(c))!) }
        return table
    }

    /// A code-point trie for leftmost-longest matching of the added tokens.
    private final class Trie {
        private final class Node {
            var children: [Unicode.Scalar: Node] = [:]
            var id: Int?
        }

        private let root = Node()

        func insert(_ key: [Unicode.Scalar], id: Int) {
            var node = root
            for s in key {
                if let next = node.children[s] {
                    node = next
                } else {
                    let next = Node()
                    node.children[s] = next
                    node = next
                }
            }
            node.id = id
        }

        func longestMatch(in text: [Unicode.Scalar], at start: Int) -> (Int, Int)? {
            var node = root
            var best: (Int, Int)?
            var i = start
            while i < text.count, let next = node.children[text[i]] {
                node = next
                i += 1
                if let id = node.id { best = (i - start, id) }
            }
            return best
        }
    }
}
