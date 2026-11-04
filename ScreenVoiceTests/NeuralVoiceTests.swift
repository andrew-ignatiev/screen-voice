import Foundation
import Testing
@testable import ScreenVoice

/// Serialized: the end-to-end tests share MLX process-wide state (GPU cache, RNG), as the app's single synthesizer does.
@Suite("Qwen3-TTS neural voice", .serialized)
struct NeuralVoiceTests {
    // MARK: Settings

    @Test func olderSettingsDefaultToSystemVoiceAndNarrator() throws {
        // Builds before VoiceDesign stored a numeric seed for the old placeholder voice; it is ignored.
        let data = Data(#"{"sourceLanguage":"en","voiceIdentifier":"x","qwenVoiceSeed":9}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.speechEngine == .system)
        #expect(settings.neuralVoice == .defaultMale)
        #expect(settings.voicePresets.isEmpty)
        #expect(settings.voiceIdentifier == "x")
    }

    @Test func voiceAndPresetsRoundTrip() throws {
        var settings = AppSettings()
        settings.speechEngine = .qwen
        settings.neuralVoice = NeuralVoice(gender: .female, style: "Young, bright, energetic.", seed: 42)
        settings.saveVoicePreset(named: "Energetic")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.selectedVoicePreset?.name == "Energetic")
    }

    // MARK: Voice description

    @Test func instructStartsWithGenderLine() {
        let voice = NeuralVoice(gender: .female, style: "  Calm.\n", seed: 1)
        #expect(voice.instruct == "Native Russian female speaker.\nCalm.")
        #expect(NeuralVoice(gender: .male, style: " ", seed: 1).instruct == "Native Russian male speaker.")
        #expect(NeuralVoice.defaultMale.instruct.contains("baritone"))
    }

    @Test func defaultStyleFollowsGenderButEditedStyleIsKept() {
        var voice = NeuralVoice.defaultMale
        voice.setGender(.female)
        #expect(voice.style == VoiceGender.female.defaultStyle)
        #expect(voice.seed == NeuralVoice.defaultMale.seed)

        voice.style = "Husky, slow."
        voice.setGender(.male)
        #expect(voice.gender == .male)
        #expect(voice.style == "Husky, slow.")
    }

    // MARK: Presets

    @Test func builtInPresetsAreSelectedByVoice() {
        var settings = AppSettings()
        #expect(settings.selectedVoicePreset?.id == VoicePreset.builtIn[0].id)
        settings.applyVoicePreset(id: VoicePreset.builtIn[1].id)
        #expect(settings.neuralVoice == .defaultFemale)
        settings.neuralVoice.seed += 1
        #expect(settings.selectedVoicePreset == nil, "an edited voice is custom until saved")
    }

    @Test func savingWithSameNameReplacesAndDeleteRemoves() throws {
        var settings = AppSettings()
        settings.neuralVoice.seed = 100
        let saved = settings.saveVoicePreset(named: " Mine ")
        let first = try #require(saved)
        #expect(first.name == "Mine")
        settings.neuralVoice.seed = 101
        let replaced = settings.saveVoicePreset(named: "mine")
        let second = try #require(replaced)
        #expect(second.id == first.id)
        #expect(settings.voicePresets.count == 1)
        #expect(settings.voicePresets[0].voice.seed == 101)
        let blank = settings.saveVoicePreset(named: "   ")
        #expect(blank == nil)

        settings.deleteVoicePreset(id: first.id)
        #expect(settings.voicePresets.isEmpty)
        #expect(settings.neuralVoice.seed == 101, "deleting a preset keeps the current voice")
        settings.deleteVoicePreset(id: VoicePreset.builtIn[0].id)
        #expect(settings.allVoicePresets.count == VoicePreset.builtIn.count, "built-in presets cannot be deleted")
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
        let spec = QwenModelSpec.voiceDesign8bit
        #expect(spec.revision.count == 40)
        #expect(spec.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
        #expect(spec.url(for: spec.files[0]).absoluteString.contains("/resolve/\(spec.revision)/"))
        #expect(spec.totalBytes > 3_000_000_000)
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

    @Test func obsoleteFilesAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "Models")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let old = root.appending(path: "Qwen3-TTS-12Hz-0.6B-Base-8bit")
        let voices = root.deletingLastPathComponent().appending(path: "Voices")
        let current = root.appending(path: QwenModelSpec.voiceDesign8bit.directoryName)
        for directory in [old, voices, current] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        QwenModelStore.removeObsoleteFiles(root: root)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: voices.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
    }

    // MARK: End to end (runs only when the model is installed in the app container)

    static let modelDirectory = QwenModelStore.defaultRoot.appending(path: QwenModelSpec.voiceDesign8bit.directoryName)

    static var modelInstalled: Bool {
        QwenModelStore.isComplete(spec: .voiceDesign8bit, at: modelDirectory)
    }

    private static func render(_ text: String, _ voice: NeuralVoice, with synthesizer: QwenSynthesizer) async throws -> [Float] {
        var samples: [Float] = []
        for try await chunk in synthesizer.synthesize(text, voice: voice) {
            samples += chunk
        }
        return samples
    }

    @Test(.enabled(if: modelInstalled), .timeLimit(.minutes(2)))
    func synthesizesRussianQuickly() async throws {
        let synthesizer = QwenSynthesizer()
        let sampleRate = try await synthesizer.load(modelDirectory: Self.modelDirectory)
        #expect(sampleRate == 24_000)

        let start = ContinuousClock.now
        var firstChunk: Duration?
        var samples: [Float] = []
        for try await chunk in synthesizer.synthesize("Корабль отправляется через десять минут.", voice: .defaultMale) {
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
            for try await _ in synthesizer.synthesize("Привет.", voice: .defaultMale) {}
        }
    }

    @Test(.enabled(if: modelInstalled), .timeLimit(.minutes(2)))
    func sameVoiceGivesSameAudioAndVariantsDiffer() async throws {
        let synthesizer = QwenSynthesizer()
        _ = try await synthesizer.load(modelDirectory: Self.modelDirectory)
        let text = "Привет! Так будет звучать перевод субтитров."

        let first = try await Self.render(text, .defaultFemale, with: synthesizer)
        _ = try await Self.render("Другая фраза между ними.", .defaultMale, with: synthesizer)
        let again = try await Self.render(text, .defaultFemale, with: synthesizer)
        #expect(first == again, "the Listen button must sound the same every time")

        var other = NeuralVoice.defaultFemale
        other.seed += 1
        #expect(try await Self.render(text, other, with: synthesizer) != first)
        await synthesizer.unload()
    }

    @Test(.enabled(if: modelInstalled), .timeLimit(.minutes(2)))
    func concurrentPhrasesAreSerialized() async throws {
        let synthesizer = QwenSynthesizer()
        _ = try await synthesizer.load(modelDirectory: Self.modelDirectory)

        // An abandoned stream (like a skipped phrase) must not corrupt the next one.
        let abandoned = synthesizer.synthesize("Это длинная фраза, которую пользователь пропустит, не дослушав до конца.", voice: .defaultMale)
        for try await _ in abandoned { break }
        let samples = try await Self.render("Не трогай это!", .defaultMale, with: synthesizer)
        let seconds = Double(samples.count) / 24_000
        #expect(seconds > 0.5 && seconds < 5, "unexpected audio length \(seconds) s")
        await synthesizer.unload()
    }
}
