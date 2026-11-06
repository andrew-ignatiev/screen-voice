import Foundation
import MLX
import MLXAudioTTS
import MLXNN
import Testing
@testable import ScreenVoice

/// The Swift port of RUAccent must mark text exactly like the Python reference
/// (`screenvoice-research/tools/ruaccent_fixed.py`, RUAccent 1.5.8.3 with the port's fixes). The expected
/// outputs are in `RussianStressGolden.json`: 85 hand-written subtitle lines and 400 random ones.
@Suite("Russian stress")
struct RussianStressTests {
    // MARK: Text rules (no files needed)

    private static func s(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    @Test func splitsWordsLikeRUAccent() {
        var (words, gaps) = StressText.splitByWords(Self.s("Ну - и что?"))
        #expect(words.map(\.string) == ["Ну", "~", "и", "что", "?"])
        #expect(gaps.map(\.string) == ["", " ", " ", " ", "", ""])

        (words, gaps) = StressText.splitByWords(Self.s("  Привет,мир!.. Да"))
        #expect(words.map(\.string) == ["Привет", ",", "мир", "!..", "Да"])
        #expect(gaps.map(\.string) == ["  ", "", "", "", " ", ""])

        (words, _) = StressText.splitByWords(Self.s("кто-то (тут)"))
        #expect(words.map(\.string) == ["кто", "-", "то", "(", "тут", ")"])
    }

    @Test func punctuationSpacingAndSentencesMatchPython() {
        #expect(StressText.deleteSpacesBeforePunctuation(Self.s("Ну ~ и что ?")).string == "Ну - и что?")
        #expect(StressText.deleteSpacesBeforePunctuation(Self.s("слово ( скобка ) - тире")).string == "слово( скобка)-тире")
        #expect(StressText.splitSentences(Self.s("Привет! Как дела?» Хорошо... ну")).map(\.string)
            == ["Привет!", " Как дела?»", " Хорошо...", " ну"])
        #expect(StressText.normalize(Self.s("Ёж… «тест» \"кавычки\" – 1+1 №5 ok")).string == "Ёж «тест» кавычки  11 5 ok")
    }

    @Test func caseAndMarksMatchPython() {
        #expect(StressText.fixCapital(source: Self.s("Вошел"), target: Self.s("вошёл")).string == "Вошёл")
        #expect(StressText.fixCapital(source: Self.s("ВСЕ"), target: Self.s("всё")).string == "ВСЁ")
        #expect(StressText.fixCapital(source: Self.s("Дом"), target: Self.s("дома")).string == "дома")
        #expect(StressText.plusToAcute(Self.s("з+амок +он")).string == "за\u{301}мок о\u{301}н")
        #expect(StressText.transferPlus(from: Self.s("з+амок"), to: Self.s("Замок")).string == "З+амок")
    }

    // MARK: Spec

    @Test func stressPackIsPinned() {
        let spec = QwenModelSpec.russianStress
        #expect(Set(spec.files.map(\.path)).count == spec.files.count)
        #expect(spec.files.allSatisfy { $0.sha256.count == 64 })
        #expect((500_000_000 ... 600_000_000).contains(spec.totalBytes))
        let lora = spec.files.first { $0.path == "lora/adapter.safetensors" }!
        #expect(spec.url(for: lora).absoluteString
            == "https://huggingface.co/siriusfreak/qwen3-tts-12hz-1.7b-ru-stress-cf/resolve/c16b3af3db3095120efc1ebb73f6522442bcb3b1/lora/adapter.safetensors")
        let model = spec.files.first { $0.path == "nn/nn_omograph/turbo3.1/model.onnx" }!
        #expect(spec.url(for: model).absoluteString.hasPrefix("https://huggingface.co/ruaccent/accentuator/resolve/b78ae5e"))
    }

    @Test func stressSettingDefaultsToOnForOldSettings() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"speechEngine":"qwen"}"#.utf8))
        #expect(old.russianStress)
    }

    // MARK: Against the Python reference (runs when the pack is installed in the app container)

    static let packDirectory = QwenModelStore.defaultRoot.appending(path: QwenModelSpec.russianStress.directoryName)
    static var packInstalled: Bool { QwenModelStore.isComplete(spec: .russianStress, at: packDirectory) }

    private struct Golden: Decodable {
        struct Line: Decodable { let text: String; let marked: String }
        struct WordPiece: Decodable { let text: String; let stressUsageIDs: [Int]; let yoIDs: [Int] }
        struct Pair: Decodable { let text: String; let hypothesis: String; let ids: [Int] }
        let lines: [Line]
        let wordpiece: [WordPiece]
        let bpe: [Pair]
    }

    private final class Marker {}

    private static func golden() throws -> Golden {
        let url = try #require(Bundle(for: Marker.self).url(forResource: "RussianStressGolden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    @Test(.enabled(if: packInstalled))
    func tokenizersGiveTheSameIDsAsHuggingFace() throws {
        let golden = try Self.golden()
        let nn = Self.packDirectory.appending(path: "nn")
        let stressUsage = try WordPieceTokenizer(vocabularyFile: nn.appending(path: "nn_stress_usage_predictor/vocab.txt"))
        let yo = try WordPieceTokenizer(vocabularyFile: nn.appending(path: "nn_yo_homograph_resolver/vocab.txt"))
        for line in golden.wordpiece {
            #expect(stressUsage.inputIDs(stressUsage.tokenize(Self.s(line.text))) == line.stressUsageIDs, "\(line.text)")
            #expect(yo.inputIDs(yo.tokenize(Self.s(line.text.lowercased()))) == line.yoIDs, "\(line.text)")
        }
        let homograph = nn.appending(path: "nn_omograph/turbo3.1")
        let bpe = try ByteLevelBPETokenizer(
            vocabularyFile: homograph.appending(path: "vocab.json"),
            mergesFile: homograph.appending(path: "merges.txt"),
            addedTokensFile: homograph.appending(path: "added_tokens.json")
        )
        for pair in golden.bpe {
            #expect(bpe.pairIDs(pair.text, pair.hypothesis) == pair.ids, "\(pair.text) | \(pair.hypothesis)")
        }
    }

    @Test(.enabled(if: packInstalled), .timeLimit(.minutes(3)))
    func marksLikeThePythonReference() throws {
        let golden = try Self.golden()
        let marker = try RussianStressMarker(directory: Self.packDirectory)
        var differences = 0
        let start = ContinuousClock.now
        for line in golden.lines {
            let marked = try marker.mark(line.text)
            if marked != line.marked {
                differences += 1
                Issue.record("\(line.text)\n  want \(line.marked)\n  got  \(marked)")
            }
        }
        print("STRESS-TIMING \(golden.lines.count) lines in \(ContinuousClock.now - start)")
        #expect(differences == 0)
        // The meaning-dependent cases from the listening test.
        #expect(try marker.mark("Он открыл замок ключом и вошел в старый замок.")
            == "Он откры\u{301}л замо\u{301}к ключо\u{301}м и вошё\u{301}л в старый за\u{301}мок.")
    }
}

/// Model tests join the serialized Qwen suite: MLX's seed and GPU cache are process-wide.
extension NeuralVoiceTests {
    // MARK: LoRA (runs when Base and the pack are installed)

    static var modelAndPackInstalled: Bool { modelInstalled && RussianStressTests.packInstalled }

    @Test(.enabled(if: modelAndPackInstalled), .timeLimit(.minutes(2)))
    func loraWrapsTheTalkerAndAddsTheLowRankUpdate() async throws {
        let model = try await TTS.loadQwen(at: Self.modelDirectory)
        let before = Dictionary(model.namedModules(), uniquingKeysWith: { a, _ in a })
        let base = try #require(before["talker.model.layers.3.mlp.down_proj"] as? QuantizedLinear)
        let x = MLXRandom.normal([1, 2, base.shape.1]).asType(base.scales.dtype)
        let plain = base(x)

        let count = try StressLoRA.apply(to: model, adapterDirectory: QwenModelSpec.stressLoRADirectory(in: RussianStressTests.packDirectory))
        #expect(count == 196)
        let after = Dictionary(model.namedModules(), uniquingKeysWith: { a, _ in a })
        let wrapped = try #require(after["talker.model.layers.3.mlp.down_proj"] as? LoRAQuantizedLinear)

        let adapter = try loadArrays(url: QwenModelSpec.stressLoRADirectory(in: RussianStressTests.packDirectory).appending(path: "adapter.safetensors"))
        let a = adapter["layers.3.mlp.down_proj.lora_A.weight"]!.asType(.float32)
        let b = adapter["layers.3.mlp.down_proj.lora_B.weight"]!.asType(.float32)
        let expected = plain.asType(.float32) + matmul(matmul(x.asType(.float32), a.transposed()), b.transposed()) * 2
        let error = abs(wrapped(x).asType(.float32) - expected).max().item(Float.self)
        let scale = abs(expected).max().item(Float.self)
        #expect(error < scale * 0.02, "LoRA output off by \(error) (scale \(scale))")
        // The code predictor is not adapted.
        #expect(!(after["talker.code_predictor.model.layers.0.self_attn.q_proj"] is LoRAQuantizedLinear))
    }

    @Test(.enabled(if: modelAndPackInstalled), .timeLimit(.minutes(3)))
    func speaksWithStressMarks() async throws {
        let synthesizer = QwenSynthesizer()
        let result = try await synthesizer.load(modelDirectory: Self.modelDirectory, stressDirectory: RussianStressTests.packDirectory)
        #expect(result.stressError == nil)
        #expect(await synthesizer.marksStress)

        let start = ContinuousClock.now
        var firstChunk: Duration?
        var samples: [Float] = []
        for try await chunk in synthesizer.synthesize("Он открыл замок ключом и вошел в старый замок.", voice: .defaultMale) {
            if firstChunk == nil { firstChunk = ContinuousClock.now - start }
            samples += chunk
        }
        let seconds = Double(samples.count) / result.sampleRate
        print("STRESS-QWEN-TIMING first chunk \(firstChunk.map(String.init(describing:)) ?? "-"), total \(ContinuousClock.now - start), audio \(seconds) s")
        // Unfollowed marks make the model drag words out (2× longer); a normal reading is ~3–5 s.
        #expect(seconds > 2 && seconds < 7, "unexpected audio length \(seconds) s")
        #expect(firstChunk.map { $0 < .seconds(2) } ?? false)

        // Turning the pack off reloads the plain model.
        _ = try await synthesizer.load(modelDirectory: Self.modelDirectory)
        #expect(await !synthesizer.marksStress)
        await synthesizer.unload()
    }

    @Test(.enabled(if: Self.modelInstalled), .timeLimit(.minutes(2)))
    func brokenPackFallsBackToPlainSpeech() async throws {
        let broken = FileManager.default.temporaryDirectory.appending(path: "broken-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: broken) }

        let synthesizer = QwenSynthesizer()
        let result = try await synthesizer.load(modelDirectory: Self.modelDirectory, stressDirectory: broken)
        #expect(result.stressError != nil)
        #expect(await !synthesizer.marksStress)
        var samples: [Float] = []
        for try await chunk in synthesizer.synthesize("Привет.", voice: .defaultMale) { samples += chunk }
        #expect(!samples.isEmpty)
        await synthesizer.unload()
    }
}

private extension TTS {
    static func loadQwen(at directory: URL) async throws -> Qwen3TTSModel {
        try #require(try await loadModel(modelRepo: directory.path, modelType: "qwen3_tts") as? Qwen3TTSModel)
    }
}
