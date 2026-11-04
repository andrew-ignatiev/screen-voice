import Foundation
import Testing
@testable import ScreenVoice

/// Serialized: the end-to-end tests share MLX process-wide state (GPU cache, RNG), as the app's single synthesizer does.
@Suite("Qwen3-TTS neural voice", .serialized)
struct NeuralVoiceTests {
    // MARK: Settings

    @Test func olderSettingsDefaultToSystemVoice() throws {
        let data = Data(#"{"sourceLanguage":"en","voiceIdentifier":"x"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.speechEngine == .system)
        #expect(settings.qwenVoiceSeed == AppSettings().qwenVoiceSeed)
        #expect(settings.voiceIdentifier == "x")
    }

    @Test func engineAndSeedRoundTrip() throws {
        var settings = AppSettings()
        settings.speechEngine = .qwen
        settings.qwenVoiceSeed = 42
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    // MARK: Playback speed

    @Test func defaultSpeechRateIsNormalSpeed() {
        #expect(QwenPhraseSpeaker.playbackRate(forSpeechRate: 0.5) == 1)
    }

    @Test func speechRateMapsToHalfAndDoubleSpeed() {
        #expect(QwenPhraseSpeaker.playbackRate(forSpeechRate: 0) == 0.5)
        #expect(QwenPhraseSpeaker.playbackRate(forSpeechRate: 1) == 2)
        #expect(QwenPhraseSpeaker.playbackRate(forSpeechRate: -3) == 0.5)
        #expect(QwenPhraseSpeaker.playbackRate(forSpeechRate: 7) == 2)
        #expect(QwenPhraseSpeaker.playbackRate(forSpeechRate: 0.25) < 1)
        #expect(QwenPhraseSpeaker.playbackRate(forSpeechRate: 0.75) > 1)
    }

    // MARK: Model store

    @Test func modelSpecIsPinned() {
        let spec = QwenModelSpec.base8bit
        #expect(spec.revision.count == 40)
        #expect(spec.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
        #expect(spec.url(for: spec.files[0]).absoluteString.contains("/resolve/\(spec.revision)/"))
        #expect(spec.totalBytes > 1_900_000_000)
    }

    @Test func incompleteModelDirectoryIsNotInstalled() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spec = QwenModelSpec(
            repository: "test/model",
            revision: String(repeating: "0", count: 40),
            directoryName: "model",
            files: [
                .init(path: "a.json", size: 3, sha256: ""),
                .init(path: "sub/b.bin", size: 2, sha256: ""),
            ]
        )
        try FileManager.default.createDirectory(at: directory.appending(path: "sub"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: directory.appending(path: "a.json"))
        #expect(!QwenModelStore.isComplete(spec: spec, at: directory))

        try Data("x".utf8).write(to: directory.appending(path: "sub/b.bin"))
        #expect(!QwenModelStore.isComplete(spec: spec, at: directory), "wrong size must not count as installed")

        try Data("xy".utf8).write(to: directory.appending(path: "sub/b.bin"))
        #expect(QwenModelStore.isComplete(spec: spec, at: directory))
    }

    // MARK: End to end (runs only when the model is installed in the app container)

    static var modelInstalled: Bool {
        QwenModelStore.isComplete(
            spec: .base8bit,
            at: QwenModelStore.defaultRoot.appending(path: QwenModelSpec.base8bit.directoryName)
        )
    }

    @Test(.enabled(if: modelInstalled), .timeLimit(.minutes(2)))
    func synthesizesRussianWithStableVoice() async throws {
        let voices = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: voices) }
        let synthesizer = QwenSynthesizer()
        let modelDirectory = QwenModelStore.defaultRoot.appending(path: QwenModelSpec.base8bit.directoryName)

        let sampleRate = try await synthesizer.load(modelDirectory: modelDirectory, voiceSeed: 7, voiceDirectory: voices)
        #expect(sampleRate == 24_000)
        #expect(FileManager.default.fileExists(atPath: voices.appending(path: "qwen-voice-7.wav").path))

        let start = ContinuousClock.now
        var firstChunk: Duration?
        var samples: [Float] = []
        for try await chunk in synthesizer.synthesize("Корабль отправляется через десять минут.") {
            if firstChunk == nil { firstChunk = ContinuousClock.now - start }
            samples += chunk
        }
        let seconds = Double(samples.count) / sampleRate
        let total = ContinuousClock.now - start
        print("QWEN-TIMING first chunk \(firstChunk.map(String.init(describing:)) ?? "-"), total \(total), audio \(seconds) s")
        #expect(seconds > 1 && seconds < 8, "unexpected audio length \(seconds) s")
        #expect(samples.contains { abs($0) > 0.05 }, "audio is silent")
        #expect(firstChunk.map { $0 < .seconds(2) } ?? false, "first audio took \(String(describing: firstChunk))")

        await synthesizer.unload()
        await #expect(throws: QwenSynthesizerError.self) {
            for try await _ in synthesizer.synthesize("Привет.") {}
        }
    }

    @Test(.enabled(if: modelInstalled), .timeLimit(.minutes(2)))
    func concurrentPhrasesAreSerialized() async throws {
        let voices = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: voices) }
        let synthesizer = QwenSynthesizer()
        let modelDirectory = QwenModelStore.defaultRoot.appending(path: QwenModelSpec.base8bit.directoryName)
        _ = try await synthesizer.load(modelDirectory: modelDirectory, voiceSeed: 7, voiceDirectory: voices)

        // An abandoned stream (like a skipped phrase) must not corrupt the next one.
        let abandoned = synthesizer.synthesize("Это длинная фраза, которую пользователь пропустит, не дослушав до конца.")
        for try await _ in abandoned { break }
        var samples: [Float] = []
        for try await chunk in synthesizer.synthesize("Не трогай это!") {
            samples += chunk
        }
        let seconds = Double(samples.count) / 24_000
        #expect(seconds > 0.5 && seconds < 5, "unexpected audio length \(seconds) s")
        await synthesizer.unload()
    }
}
