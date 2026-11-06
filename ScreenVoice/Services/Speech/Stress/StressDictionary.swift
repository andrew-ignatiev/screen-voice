import Compression
import Foundation

/// RUAccent's main dictionary (3.2 million lowercase word forms, each with one `+` before the stressed vowel)
/// as a memory-mapped sorted table. Loading the JSON as a Swift dictionary would take ~400 MB and seconds on
/// every launch; the table is built once from `accents.json.gz` (~5 s) and then opens instantly.
///
/// File: magic, count, then `count + 1` UInt32 key offsets, `count` stress positions (code-point index of the
/// stressed vowel, 255 = none) and the UTF-8 keys, sorted by bytes.
final class StressDictionary: @unchecked Sendable {
    private static let magic = Array("SVACCNT1".utf8)

    private let data: Data
    private let count: Int
    private let offsetsStart: Int
    private let positionsStart: Int
    private let keysStart: Int

    init(table: URL) throws {
        data = try Data(contentsOf: table, options: .alwaysMapped)
        guard data.count >= 12, Array(data.prefix(8)) == Self.magic else {
            throw RussianStressError.badFile(table.lastPathComponent)
        }
        count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
        offsetsStart = 12
        positionsStart = offsetsStart + (count + 1) * 4
        keysStart = positionsStart + count
        guard data.count >= keysStart else { throw RussianStressError.badFile(table.lastPathComponent) }
    }

    /// Opens the table next to `source`, building it first if it is missing or stale.
    static func open(source: URL) throws -> StressDictionary {
        let table = source.deletingLastPathComponent().appending(path: "accents.table")
        if let dictionary = try? StressDictionary(table: table) { return dictionary }
        try build(source: source, table: table)
        return try StressDictionary(table: table)
    }

    /// The dictionary form with `+` (`accents.get(word, word)` in RUAccent), or nil.
    func stressed(_ word: [Unicode.Scalar]) -> [Unicode.Scalar]? {
        let key = Array(word.string.utf8)
        return data.withUnsafeBytes { raw -> [Unicode.Scalar]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            func offset(_ i: Int) -> Int {
                Int(raw.loadUnaligned(fromByteOffset: offsetsStart + i * 4, as: UInt32.self))
            }
            var low = 0, high = count - 1
            while low <= high {
                let mid = (low + high) / 2
                let start = keysStart + offset(mid), end = keysStart + offset(mid + 1)
                let order = key.withUnsafeBufferPointer { k -> Int in
                    let n = min(k.count, end - start)
                    let c = memcmp(k.baseAddress!, bytes.baseAddress! + start, n)
                    if c != 0 { return Int(c) }
                    return k.count - (end - start)
                }
                if order == 0 {
                    let position = Int(bytes[positionsStart + mid])
                    guard position != 255, position <= word.count else { return word }
                    return Array(word[..<position]) + [StressText.plus] + Array(word[position...])
                }
                if order < 0 { high = mid - 1 } else { low = mid + 1 }
            }
            return nil
        }
    }

    // MARK: Building

    static func build(source: URL, table: URL) throws {
        let json = try gunzip(Data(contentsOf: source))
        var keys: [UInt8] = []
        keys.reserveCapacity(json.count / 3)
        var offsets: [UInt32] = [0]
        var positions: [UInt8] = []

        try json.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            func string() throws -> [UInt8] {
                while i < b.count, b[i] != UInt8(ascii: "\"") { i += 1 }
                i += 1
                var out: [UInt8] = []
                while i < b.count, b[i] != UInt8(ascii: "\"") {
                    if b[i] == UInt8(ascii: "\\") {
                        i += 1
                        guard i < b.count else { break }
                        switch b[i] {
                        case UInt8(ascii: "u"):
                            guard i + 4 < b.count, let code = UInt32(String(decoding: b[(i + 1)...(i + 4)], as: UTF8.self), radix: 16),
                                  let scalar = Unicode.Scalar(code) else { throw RussianStressError.badFile(source.lastPathComponent) }
                            out += Array(String(scalar).utf8)
                            i += 4
                        case UInt8(ascii: "n"): out.append(10)
                        case UInt8(ascii: "t"): out.append(9)
                        default: out.append(b[i])
                        }
                    } else {
                        out.append(b[i])
                    }
                    i += 1
                }
                i += 1
                return out
            }
            while i < b.count {
                while i < b.count, b[i] != UInt8(ascii: "\""), b[i] != UInt8(ascii: "}") { i += 1 }
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { break }
                let key = try string()
                let value = try string()
                // The value is the key with one "+" inserted; keep only its code-point position.
                let valueScalars = Array(String(decoding: value, as: UTF8.self).unicodeScalars)
                let position = valueScalars.firstIndex(of: StressText.plus).map { min($0, 254) } ?? 255
                keys += key
                offsets.append(UInt32(keys.count))
                positions.append(UInt8(position))
            }
        }

        // Sort by key bytes (Python sorted the JSON by insertion, not by bytes). Later duplicates win, as in a
        // Python dict, so a stable sort keeps the last of equal keys.
        let n = positions.count
        var order = Array(0 ..< n)
        keys.withUnsafeBufferPointer { k in
            func compare(_ a: Int, _ b: Int) -> Int {
                let sa = Int(offsets[a]), la = Int(offsets[a + 1]) - sa
                let sb = Int(offsets[b]), lb = Int(offsets[b + 1]) - sb
                let c = memcmp(k.baseAddress! + sa, k.baseAddress! + sb, min(la, lb))
                return c != 0 ? Int(c) : la - lb
            }
            order.sort { a, b in
                let c = compare(a, b)
                return c != 0 ? c < 0 : a < b
            }
            var unique: [Int] = []
            unique.reserveCapacity(n)
            for index in order {
                if let last = unique.last, compare(last, index) == 0 {
                    unique[unique.count - 1] = index
                } else {
                    unique.append(index)
                }
            }
            order = unique
        }

        var out = Data(magic)
        var count = UInt32(order.count)
        out.append(Data(bytes: &count, count: 4))
        var sortedOffsets: [UInt32] = [0]
        sortedOffsets.reserveCapacity(order.count + 1)
        var sortedKeys: [UInt8] = []
        sortedKeys.reserveCapacity(keys.count)
        var sortedPositions: [UInt8] = []
        sortedPositions.reserveCapacity(order.count)
        for index in order {
            sortedKeys += keys[Int(offsets[index]) ..< Int(offsets[index + 1])]
            sortedOffsets.append(UInt32(sortedKeys.count))
            sortedPositions.append(positions[index])
        }
        sortedOffsets.withUnsafeBytes { out.append(contentsOf: $0) }
        out.append(contentsOf: sortedPositions)
        out.append(contentsOf: sortedKeys)
        let partial = table.appendingPathExtension("partial")
        try out.write(to: partial)
        _ = try FileManager.default.replaceItemAt(table, withItemAt: partial)
    }

    /// Decompresses a gzip file (one member, raw deflate inside).
    static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 8 else {
            throw RussianStressError.badFile("gzip")
        }
        let flags = data[3]
        var start = 10
        if flags & 0x04 != 0 { start += 2 + Int(data[start]) | Int(data[start + 1]) << 8 }
        if flags & 0x08 != 0 { while data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x10 != 0 { while data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x02 != 0 { start += 2 }
        let size = data.suffix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        let deflated = data.subdata(in: start ..< data.count - 8)
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            deflated.withUnsafeBytes { input in
                compression_decode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, size,
                    input.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw RussianStressError.badFile("gzip") }
        return output
    }
}
