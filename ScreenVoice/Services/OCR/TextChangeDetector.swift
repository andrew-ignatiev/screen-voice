import CoreGraphics
import Foundation

/// Decides which recognized text is new, stable, and not yet spoken.
///
/// Pipeline per tick:
/// 1. Filter OCR lines by confidence and length, normalize whitespace.
/// 2. Merge fragments on the same row, then merge adjacent rows into blocks (one subtitle = one block).
/// 3. Track each block across ticks with fuzzy matching, so small OCR jitter does not look like new text.
/// 4. Confirm a block once it has been seen in enough consecutive ticks for long enough.
/// 5. Drop rows that were spoken recently (handles flicker and rolling captions), emit the rest.
///
/// The type is a pure value with no clock or I/O, so it is fully unit-testable.
struct TextChangeDetector: Sendable {
    struct Configuration: Equatable, Sendable {
        /// Lines below this Vision confidence are ignored.
        var minimumConfidence: Float = 0.4
        /// Lines whose comparison key is shorter than this are ignored.
        var minimumLength: Int = 2
        /// A block must be seen in at least this many consecutive ticks.
        var requiredStableFrames: Int = 2
        /// And must have been visible at least this long (seconds).
        var minimumStableDuration: TimeInterval = 0.3
        /// Normalized edit-distance similarity above which two texts count as "the same".
        var similarityThreshold: Double = 0.8
        /// How many spoken rows are remembered.
        var historyLimit: Int = 40
        /// How long a spoken row suppresses repeats (seconds).
        var historyLifetime: TimeInterval = 20
        /// Rows closer than `rowGapFactor × lineHeight` are merged into one block.
        var rowGapFactor: CGFloat = 1.0
    }

    struct Block: Equatable, Sendable {
        var rows: [String]
        var boundingBox: CGRect
        var confidence: Float

        var text: String { rows.joined(separator: " ") }
    }

    private struct Candidate {
        var block: Block
        var key: String
        var firstSeen: TimeInterval
        var frames: Int
        var handled: Bool
    }

    private struct HistoryEntry {
        let key: String
        let time: TimeInterval
    }

    var configuration: Configuration
    private var candidates: [Candidate] = []
    private var history: [HistoryEntry] = []

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Forgets tracked blocks but keeps the spoken history, e.g. after a pause.
    mutating func resetCandidates() {
        candidates.removeAll()
    }

    mutating func reset() {
        candidates.removeAll()
        history.removeAll()
    }

    /// Feeds the OCR result of one tick. Returns phrases that should be translated and spoken, in reading order.
    mutating func process(_ lines: [RecognizedLine], at now: TimeInterval) -> [String] {
        history.removeAll { now - $0.time > configuration.historyLifetime }

        let usable: [RecognizedLine] = lines.compactMap { line in
            let text = Self.normalizeDisplayText(line.text)
            guard line.confidence >= configuration.minimumConfidence,
                  Self.comparisonKey(text).count >= configuration.minimumLength else { return nil }
            var cleaned = line
            cleaned.text = text
            return cleaned
        }

        let blocks = Self.groupIntoBlocks(usable, rowGapFactor: configuration.rowGapFactor)

        // Match current blocks to tracked candidates. Candidates not seen this tick are dropped:
        // the block disappeared, so if it comes back it is treated as new (and filtered by history).
        var remaining = candidates
        var updated: [Candidate] = []
        for block in blocks {
            let key = Self.comparisonKey(block.text)
            if let index = remaining.firstIndex(where: { Self.similarity($0.key, key) >= configuration.similarityThreshold }) {
                var candidate = remaining.remove(at: index)
                candidate.frames += 1
                candidate.block = block
                candidate.key = key
                updated.append(candidate)
            } else {
                updated.append(Candidate(block: block, key: key, firstSeen: now, frames: 1, handled: false))
            }
        }

        var confirmed: [String] = []
        for index in updated.indices where !updated[index].handled {
            let candidate = updated[index]
            guard candidate.frames >= configuration.requiredStableFrames,
                  now - candidate.firstSeen >= configuration.minimumStableDuration else { continue }

            updated[index].handled = true

            let newRows = candidate.block.rows.filter { !isRecentlySpoken(Self.comparisonKey($0)) }
            for row in candidate.block.rows {
                history.append(HistoryEntry(key: Self.comparisonKey(row), time: now))
            }
            if !newRows.isEmpty {
                confirmed.append(newRows.joined(separator: " "))
            }
        }

        if history.count > configuration.historyLimit {
            history.removeFirst(history.count - configuration.historyLimit)
        }
        candidates = updated
        return confirmed
    }

    private func isRecentlySpoken(_ key: String) -> Bool {
        history.contains { Self.similarity($0.key, key) >= configuration.similarityThreshold }
    }

    // MARK: - Text helpers

    /// Collapses all whitespace (including line breaks) into single spaces and trims the ends.
    static func normalizeDisplayText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Lowercased letters and digits separated by single spaces. Used only for comparisons.
    static func comparisonKey(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace && !result.isEmpty { result.append(" ") }
                result.append(scalar)
                pendingSpace = false
            } else {
                pendingSpace = true
            }
        }
        return String(result)
    }

    /// 1 − normalized Levenshtein distance, in 0...1.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[b.count]) / Double(Swift.max(a.count, b.count))
    }

    // MARK: - Layout grouping

    /// Groups OCR lines into rows (fragments on the same baseline) and rows into blocks
    /// (vertically adjacent, horizontally overlapping rows — typically one multi-line subtitle).
    static func groupIntoBlocks(_ lines: [RecognizedLine], rowGapFactor: CGFloat) -> [Block] {
        struct Row {
            var parts: [RecognizedLine]
            var box: CGRect
            var confidence: Float
        }

        // Vision uses a bottom-left origin, so higher midY means higher on screen.
        let sorted = lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var rows: [Row] = []
        for line in sorted {
            if let last = rows.indices.last {
                let tolerance = Swift.min(rows[last].box.height, line.boundingBox.height) * 0.5
                if abs(rows[last].box.midY - line.boundingBox.midY) <= tolerance {
                    rows[last].parts.append(line)
                    rows[last].box = rows[last].box.union(line.boundingBox)
                    rows[last].confidence = Swift.min(rows[last].confidence, line.confidence)
                    continue
                }
            }
            rows.append(Row(parts: [line], box: line.boundingBox, confidence: line.confidence))
        }

        var blocks: [Block] = []
        var previousRowBox: CGRect?
        for row in rows {
            let text = row.parts
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map(\.text)
                .joined(separator: " ")

            if let previous = previousRowBox, let lastIndex = blocks.indices.last {
                let gap = previous.minY - row.box.maxY
                let lineHeight = Swift.max(previous.height, row.box.height)
                let overlapsHorizontally = previous.minX <= row.box.maxX && row.box.minX <= previous.maxX
                if gap <= lineHeight * rowGapFactor && overlapsHorizontally {
                    blocks[lastIndex].rows.append(text)
                    blocks[lastIndex].boundingBox = blocks[lastIndex].boundingBox.union(row.box)
                    blocks[lastIndex].confidence = Swift.min(blocks[lastIndex].confidence, row.confidence)
                    previousRowBox = row.box
                    continue
                }
            }
            blocks.append(Block(rows: [text], boundingBox: row.box, confidence: row.confidence))
            previousRowBox = row.box
        }
        return blocks
    }
}
