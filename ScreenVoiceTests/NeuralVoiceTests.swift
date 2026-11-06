import Foundation
import MLX
import MLXAudioCore
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
        #expect(settings.neuralDelivery == .calm)
        #expect(settings.previewText.isEmpty)
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

    @Test func presetsSavedBeforeReferenceLengthGetTheDefault() throws {
        let data = Data(#"{"gender":"female","style":"Calm.","seed":4}"#.utf8)
        let voice = try JSONDecoder().decode(NeuralVoice.self, from: data)
        #expect(voice == NeuralVoice(gender: .female, style: "Calm.", seed: 4, referenceSeconds: 11))
        let tooLong = try JSONDecoder().decode(NeuralVoice.self, from: Data(#"{"gender":"male","style":"","seed":1,"referenceSeconds":40}"#.utf8))
        #expect(tooLong.referenceSeconds == 12)
    }

    @Test func deliveryMapsToTemperature() throws {
        #expect(AppSettings().neuralDelivery == .calm)
        #expect(NeuralDelivery.calm.temperature == 0.7)
        #expect(NeuralDelivery.lively.temperature == 0.9)
        var settings = AppSettings()
        settings.neuralDelivery = .lively
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.neuralDelivery == .lively)
    }

    @Test func previewTextRoundTrips() throws {
        var settings = AppSettings()
        settings.previewText = "Двадцать четвёртого мая в 1984 году."
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.previewText == settings.previewText)
    }

    // MARK: Reference recordings

    @Test func everyReferenceLengthHasATextAndBundledNarrators() {
        var previous = 0
        for seconds in NeuralVoice.referenceSecondsRange {
            let text = VoiceReference.text(seconds: seconds)
            #expect(text.count > previous, "longer references must have longer texts")
            previous = text.count
            for builtIn in [NeuralVoice.defaultMale, .defaultFemale] {
                var voice = builtIn
                voice.referenceSeconds = seconds
                #expect(VoiceReference.bundledURL(for: voice) != nil, "missing narrator-\(voice.gender)-\(seconds).wav")
            }
        }
    }

    @Test func createdReferenceNameFollowsEverythingThatShapesIt() {
        let directory = URL(filePath: "/tmp/refs")
        let voice = NeuralVoice(gender: .male, style: "Husky.", seed: 9)
        #expect(VoiceReference.bundledURL(for: voice) == nil, "a custom voice has no bundled recording")
        let url = VoiceReference.createdURL(for: voice, directory: directory)
        #expect(url == VoiceReference.createdURL(for: voice, directory: directory))
        for changed in [
            NeuralVoice(gender: .male, style: "Husky.", seed: 10),
            NeuralVoice(gender: .female, style: "Husky.", seed: 9),
            NeuralVoice(gender: .male, style: "Husky, slow.", seed: 9),
            NeuralVoice(gender: .male, style: "Husky.", seed: 9, referenceSeconds: 6),
        ] {
            #expect(VoiceReference.createdURL(for: changed, directory: directory) != url)
        }
        #expect(VoiceReference.existingURL(for: voice, directory: directory) == nil)
    }

    // MARK: Recorded voices

    @Test func recordedVoiceUsesItsOwnFileAndTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var voice = NeuralVoice.defaultMale
        voice.recording = RecordedVoice(id: UUID(), text: "Привет, это я.", seconds: 9)
        #expect(voice.referenceText == "Привет, это я.")
        #expect(VoiceReference.bundledURL(for: voice) == nil, "a recording replaces the built-in narrator")
        #expect(VoiceReference.existingURL(for: voice, directory: directory) == nil)

        let url = VoiceReference.recordedURL(for: voice.recording!, directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: url)
        #expect(VoiceReference.existingURL(for: voice, directory: directory) == url)

        var settings = AppSettings()
        settings.neuralVoice = voice
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.neuralVoice.recording == voice.recording)
        #expect(decoded.usedRecordings == [voice.recording!.id])
    }

    @Test func unusedRecordingsAreDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kept = RecordedVoice(id: UUID(), text: "a", seconds: 9)
        let dropped = RecordedVoice(id: UUID(), text: "b", seconds: 9)
        let created = directory.appending(path: "0123abcd.wav")
        for url in [VoiceReference.recordedURL(for: kept, directory: directory), VoiceReference.recordedURL(for: dropped, directory: directory), created] {
            try Data([0]).write(to: url)
        }
        VoiceReference.removeUnusedRecordings(keeping: [kept.id], directory: directory)
        #expect(FileManager.default.fileExists(atPath: VoiceReference.recordedURL(for: kept, directory: directory).path))
        #expect(!FileManager.default.fileExists(atPath: VoiceReference.recordedURL(for: dropped, directory: directory).path))
        #expect(FileManager.default.fileExists(atPath: created.path), "designed voices are not recordings")
    }

    @Test func recordingIsTrimmedAndNormalized() {
        let rate = 48_000.0
        let silence = [Float](repeating: 0.0005, count: 48_000)
        let tone = (0..<96_000).map { Float(sin(Double($0) * 0.06)) * 0.2 }
        let result = VoiceRecorder.trimmedAndNormalized(silence + tone + silence, sampleRate: rate)
        let seconds = Double(result.count) / rate
        #expect(seconds > 2.3 && seconds < 2.5, "speech plus 0.2 s on each side, got \(seconds) s")
        #expect(abs((result.map(abs).max() ?? 0) - 0.9) < 0.01)
        #expect(VoiceRecorder.trimmedAndNormalized([], sampleRate: rate).isEmpty)
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

    @Test func catchUpSpeedsUpFromTheSecondSubtitle() throws {
        #expect(SpeechService.catchUpFactor(waiting: 0) == 1)
        #expect(SpeechService.catchUpFactor(waiting: 1) == 1.25)
        #expect(SpeechService.catchUpFactor(waiting: 2) == 1.5)
        #expect(SpeechService.catchUpFactor(waiting: 3) == 1.5)
        #expect(SpeechService.catchUpFactor(waiting: 10) == 1.5)
        // The system voice is sped up by the same factor through the inverse mapping.
        for rate: Float in [0, 0.25, 0.5, 0.75, 1] {
            let playback = QwenPhraseSpeaker.playbackRate(forSpeechRate: rate)
            #expect(abs(QwenPhraseSpeaker.speechRate(forPlaybackRate: playback) - rate) < 0.0001)
        }
        #expect(QwenPhraseSpeaker.speechRate(forPlaybackRate: 1.25) == 0.625)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.speedUpWhenBehind, "on by default, also for settings saved before it existed")
    }

    // MARK: Model store

    @Test(arguments: [QwenModelSpec.base8bit, .voiceDesign8bit])
    func modelSpecIsPinned(spec: QwenModelSpec) {
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
        let current = root.appending(path: QwenModelSpec.base8bit.directoryName)
        let designer = root.appending(path: QwenModelSpec.voiceDesign8bit.directoryName)
        for directory in [old, voices, current, designer] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        QwenModelStore.removeObsoleteFiles(root: root)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: voices.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: designer.path), "the voice designer is optional, not obsolete")
    }

    // MARK: End to end (runs only when the models are installed in the app container)

    static let modelDirectory = QwenModelStore.defaultRoot.appending(path: QwenModelSpec.base8bit.directoryName)
    static let designModelDirectory = QwenModelStore.defaultRoot.appending(path: QwenModelSpec.voiceDesign8bit.directoryName)

    static var modelInstalled: Bool {
        QwenModelStore.isComplete(spec: .base8bit, at: modelDirectory)
    }

    static var bothModelsInstalled: Bool {
        modelInstalled && QwenModelStore.isComplete(spec: .voiceDesign8bit, at: designModelDirectory)
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
        let sampleRate = try await synthesizer.load(modelDirectory: Self.modelDirectory).sampleRate
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

        var lively: [Float] = []
        for try await chunk in synthesizer.synthesize(text, voice: .defaultFemale, delivery: .lively) { lively += chunk }
        #expect(lively != first, "the delivery setting must reach the model")

        var shorter = NeuralVoice.defaultFemale
        shorter.referenceSeconds = 6
        #expect(try await Self.render(text, shorter, with: synthesizer) != first, "another reference must sound different")
        await synthesizer.unload()
    }

    @Test(.enabled(if: bothModelsInstalled), .timeLimit(.minutes(3)))
    func createdVoiceIsSavedAndSpoken() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let synthesizer = QwenSynthesizer(referenceDirectory: directory)
        let voice = NeuralVoice(gender: .male, style: "Calm, low voice. Slow delivery.", seed: 11, referenceSeconds: 6)

        let start = ContinuousClock.now
        let url = try await synthesizer.createReference(for: voice, designModelDirectory: Self.designModelDirectory)
        print("QWEN-CREATE \(ContinuousClock.now - start)")
        #expect(url == VoiceReference.existingURL(for: voice, directory: directory))
        let (_, audio) = try loadAudioArray(from: url)
        #expect(audio.size > 24_000 * 3, "reference shorter than 3 s")

        _ = try await synthesizer.load(modelDirectory: Self.modelDirectory)
        let text = "Корабль отправляется через десять минут."
        let created = try await Self.render(text, voice, with: synthesizer)
        #expect(created.contains { abs($0) > 0.05 }, "audio is silent")
        #expect(try await Self.render(text, .defaultMale, with: synthesizer) != created)
        await synthesizer.unload()
    }

    @Test(.enabled(if: modelInstalled), .timeLimit(.minutes(2)))
    func recordedVoiceIsSpoken() async throws {
        // Stands in for a microphone recording: a bundled narrator written at 48 kHz, like a Mac microphone.
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var narrator = NeuralVoice.defaultMale
        narrator.referenceSeconds = 6
        let (_, audio) = try loadAudioArray(from: try #require(VoiceReference.bundledURL(for: narrator)))
        let samples = audio.asArray(Float.self).flatMap { [$0, $0] }
        var voice = NeuralVoice.defaultFemale
        voice.recording = RecordedVoice(id: UUID(), text: narrator.referenceText, seconds: Double(samples.count) / 48_000)
        try VoiceRecorder.writeWAV(samples, sampleRate: 48_000, to: VoiceReference.recordedURL(for: voice.recording!, directory: directory))

        let synthesizer = QwenSynthesizer(referenceDirectory: directory)
        _ = try await synthesizer.load(modelDirectory: Self.modelDirectory)
        let text = "Корабль отправляется через десять минут."
        let recorded = try await Self.render(text, voice, with: synthesizer)
        #expect(recorded.contains { abs($0) > 0.05 }, "audio is silent")
        #expect(try await Self.render(text, .defaultFemale, with: synthesizer) != recorded, "the recording must replace the narrator")
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
