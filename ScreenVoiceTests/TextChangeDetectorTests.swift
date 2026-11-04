import CoreGraphics
import Testing
@testable import ScreenVoice

@Suite("TextChangeDetector")
struct TextChangeDetectorTests {
    /// A subtitle-like line near the bottom of the frame. `row` 0 is the lowest row.
    private func line(_ text: String, row: Int = 0, x: CGFloat = 0.2, width: CGFloat = 0.6, confidence: Float = 0.9) -> RecognizedLine {
        RecognizedLine(
            text: text,
            confidence: confidence,
            boundingBox: CGRect(x: x, y: 0.1 + CGFloat(row) * 0.06, width: width, height: 0.05)
        )
    }

    /// Feeds the same lines for `ticks` ticks, 0.25 s apart, and returns everything emitted.
    private func feed(
        _ detector: inout TextChangeDetector,
        _ lines: [RecognizedLine],
        ticks: Int,
        start: inout Double
    ) -> [String] {
        var emitted: [String] = []
        for _ in 0..<ticks {
            emitted += detector.process(lines, at: start)
            start += 0.25
        }
        return emitted
    }

    @Test func stableLineIsEmittedOnce() {
        var detector = TextChangeDetector()
        var time = 0.0
        let emitted = feed(&detector, [line("Hello there, friend")], ticks: 12, start: &time)
        #expect(emitted == ["Hello there, friend"])
    }

    @Test func singleFrameIsNotConfirmed() {
        var detector = TextChangeDetector()
        #expect(detector.process([line("Flash of text")], at: 0).isEmpty)
        #expect(detector.process([], at: 0.25).isEmpty)
        #expect(detector.process([], at: 0.5).isEmpty)
    }

    @Test func requiresMinimumStableDuration() {
        var detector = TextChangeDetector(configuration: .init(requiredStableFrames: 2, minimumStableDuration: 0.5))
        #expect(detector.process([line("Wait for it")], at: 0).isEmpty)
        #expect(detector.process([line("Wait for it")], at: 0.1).isEmpty)
        #expect(detector.process([line("Wait for it")], at: 0.6) == ["Wait for it"])
    }

    @Test func ocrJitterDoesNotRetrigger() {
        var detector = TextChangeDetector()
        var time = 0.0
        var emitted = feed(&detector, [line("I will see you tomorrow")], ticks: 3, start: &time)
        emitted += feed(&detector, [line("I wi1l see you tomorrow")], ticks: 2, start: &time)
        emitted += feed(&detector, [line("I will see you tomorow")], ticks: 2, start: &time)
        #expect(emitted == ["I will see you tomorrow"])
    }

    @Test func newSubtitleIsEmitted() {
        var detector = TextChangeDetector()
        var time = 0.0
        var emitted = feed(&detector, [line("First subtitle line")], ticks: 4, start: &time)
        emitted += feed(&detector, [line("Something completely different")], ticks: 4, start: &time)
        #expect(emitted == ["First subtitle line", "Something completely different"])
    }

    @Test func flickeringSubtitleIsNotRepeated() {
        var detector = TextChangeDetector()
        var time = 0.0
        var emitted = feed(&detector, [line("Do not repeat me")], ticks: 4, start: &time)
        emitted += feed(&detector, [], ticks: 1, start: &time)
        emitted += feed(&detector, [line("Do not repeat me")], ticks: 4, start: &time)
        #expect(emitted == ["Do not repeat me"])
    }

    @Test func repeatedLineIsSpokenAgainAfterHistoryExpires() {
        var detector = TextChangeDetector(configuration: .init(historyLifetime: 5))
        var time = 0.0
        var emitted = feed(&detector, [line("Yes")], ticks: 4, start: &time)
        emitted += feed(&detector, [], ticks: 1, start: &time)
        time += 10
        emitted += feed(&detector, [line("Yes")], ticks: 4, start: &time)
        #expect(emitted == ["Yes", "Yes"])
    }

    @Test func lowConfidenceAndTooShortLinesAreIgnored() {
        var detector = TextChangeDetector()
        var time = 0.0
        let emitted = feed(&detector, [line("Blurry text", confidence: 0.1), line("—", row: 2)], ticks: 6, start: &time)
        #expect(emitted.isEmpty)
    }

    @Test func multiLineSubtitleIsMergedInReadingOrder() {
        var detector = TextChangeDetector()
        var time = 0.0
        let lines = [line("second line", row: 0), line("This is the first,", row: 1)]
        let emitted = feed(&detector, lines, ticks: 4, start: &time)
        #expect(emitted == ["This is the first, second line"])
    }

    @Test func fragmentsOnOneRowAreJoinedLeftToRight() {
        var detector = TextChangeDetector()
        var time = 0.0
        let lines = [line("world", x: 0.55, width: 0.2), line("Hello", x: 0.3, width: 0.2)]
        let emitted = feed(&detector, lines, ticks: 4, start: &time)
        #expect(emitted == ["Hello world"])
    }

    @Test func distantTextBlocksStaySeparate() {
        var detector = TextChangeDetector()
        var time = 0.0
        let lines = [line("Subtitle at the bottom", row: 0), line("Title at the top", row: 12)]
        let emitted = feed(&detector, lines, ticks: 4, start: &time)
        #expect(emitted == ["Title at the top", "Subtitle at the bottom"])
    }

    @Test func rollingCaptionsEmitOnlyNewRow() {
        var detector = TextChangeDetector()
        var time = 0.0
        var emitted = feed(&detector, [line("we went to the market", row: 0)], ticks: 4, start: &time)
        // The old row scrolls up and a new row appears below it.
        let rolled = [line("we went to the market", row: 1), line("and bought fresh bread", row: 0)]
        emitted += feed(&detector, rolled, ticks: 4, start: &time)
        #expect(emitted == ["we went to the market", "and bought fresh bread"])
    }

    @Test func whitespaceIsNormalized() {
        #expect(TextChangeDetector.normalizeDisplayText("  Hello \n  world\t ") == "Hello world")
    }

    @Test func comparisonKeyIgnoresCaseAndPunctuation() {
        #expect(TextChangeDetector.comparisonKey("Hello, World!") == "hello world")
        #expect(TextChangeDetector.comparisonKey("— ...") == "")
        #expect(TextChangeDetector.comparisonKey("こんにちは、世界") == "こんにちは 世界")
    }

    @Test func similarityBounds() {
        #expect(TextChangeDetector.similarity("abc", "abc") == 1)
        #expect(TextChangeDetector.similarity("abc", "") == 0)
        #expect(TextChangeDetector.similarity("kitten", "sitting") > 0.5)
        #expect(TextChangeDetector.similarity("kitten", "sitting") < 0.6)
    }
}
