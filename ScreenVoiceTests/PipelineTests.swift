import CoreGraphics
import Foundation
import Testing
@testable import ScreenVoice

@Suite("Pipeline building blocks")
struct PipelineTests {
    // MARK: Speech queue

    @Test func speechQueueIsFIFO() {
        var queue = SpeechQueue(capacity: 3, maxAge: 10)
        queue.enqueue("one", at: 0)
        queue.enqueue("two", at: 0)
        #expect(queue.next(at: 1)?.text == "one")
        #expect(queue.next(at: 1)?.text == "two")
        #expect(queue.next(at: 1) == nil)
    }

    @Test func speechQueueDropsOldestWhenFull() {
        var queue = SpeechQueue(capacity: 2, maxAge: 10)
        queue.enqueue("one", at: 0)
        queue.enqueue("two", at: 0)
        queue.enqueue("three", at: 0)
        #expect(queue.items.map(\.text) == ["two", "three"])
    }

    @Test func speechQueueSkipsStalePhrases() {
        var queue = SpeechQueue(capacity: 5, maxAge: 5)
        queue.enqueue("old", at: 0)
        queue.enqueue("fresh", at: 8)
        #expect(queue.next(at: 9)?.text == "fresh")
    }

    @Test func shrinkingCapacityTrimsQueue() {
        var queue = SpeechQueue(capacity: 5, maxAge: 10)
        for index in 0..<5 { queue.enqueue("\(index)", at: 0) }
        queue.setCapacity(2)
        #expect(queue.items.map(\.text) == ["3", "4"])
        queue.setCapacity(0)
        #expect(queue.capacity == 1)
    }

    // MARK: Options

    @Test func optionsFollowSettings() {
        let options = PipelineOptions()
        var settings = AppSettings()
        settings.sourceLanguage = .german
        settings.framesPerSecond = 5
        settings.ocrAccuracy = .fast
        settings.minimumConfidence = 0.6
        options.apply(settings)

        let snapshot = options.snapshot
        #expect(snapshot.framesPerSecond == 5)
        #expect(snapshot.minimumConfidence == 0.6)
        #expect(snapshot.ocr.languages == ["de-DE"])
        #expect(snapshot.ocr.accuracy == .fast)
    }

    @Test func japaneseForcesAccurateRecognition() {
        let options = PipelineOptions()
        var settings = AppSettings()
        settings.sourceLanguage = .japanese
        settings.ocrAccuracy = .fast
        options.apply(settings)
        #expect(options.snapshot.ocr.accuracy == .accurate)
        #expect(options.snapshot.ocr.languages == ["ja-JP"])
    }

    @Test func pauseFlagIsIndependentOfSettings() {
        let options = PipelineOptions()
        options.update { $0.isPaused = true }
        options.apply(AppSettings())
        #expect(options.snapshot.isPaused)
    }

    // MARK: Settings persistence

    @Test func settingsDecodeWithMissingKeys() throws {
        let data = Data(#"{"sourceLanguage":"fr","speechRate":0.4}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.sourceLanguage == .french)
        #expect(settings.speechRate == 0.4)
        #expect(settings.framesPerSecond == AppSettings().framesPerSecond)
        #expect(settings.showOverlay)
    }

    @Test func settingsRoundTrip() throws {
        var settings = AppSettings()
        settings.voiceIdentifier = "com.apple.voice.compact.ru-RU.Milena"
        settings.maxQueuedPhrases = 5
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    // MARK: Region geometry

    @Test func regionIsConvertedToTopLeftDisplayCoordinates() {
        // A 400×100 band whose bottom edge is 50 pt above the bottom of a 1000-pt-tall screen.
        let viewRect = CGRect(x: 100, y: 50, width: 400, height: 100)
        let local = RegionSelection.displayLocalRect(fromViewRect: viewRect, screenHeight: 1000)
        #expect(local == CGRect(x: 100, y: 850, width: 400, height: 100))
    }
}
