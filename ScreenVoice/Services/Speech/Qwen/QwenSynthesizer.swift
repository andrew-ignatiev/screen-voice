import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import os

enum QwenSynthesizerError: LocalizedError {
    case notLoaded
    case unexpectedModel
    case missingReference
    case emptyReference

    var errorDescription: String? {
        switch self {
        case .notLoaded: String(localized: "The Qwen3-TTS model isn’t loaded.")
        case .unexpectedModel: String(localized: "The model folder doesn’t contain Qwen3-TTS.")
        case .missingReference: String(localized: "The voice’s reference recording is missing.")
        case .emptyReference: String(localized: "The voice designer produced no audio. Try another variant.")
        }
    }
}

/// Owns the Qwen3-TTS models. Every MLX operation runs behind a gate, one at a time: the models and their
/// streaming decoder state are not safe for concurrent use, and the seed is process-wide MLX state.
///
/// Only one model is in memory at a time. The Base model speaks every phrase by cloning the voice's reference
/// recording. VoiceDesign is loaded only to create a missing reference from the voice's description, and is
/// unloaded right after; the caller then loads Base again.
///
/// With the Russian stress pack, Base is loaded with the stress LoRA and every phrase gets RUAccent's stress
/// marks first. If the pack fails to load, the model speaks without it.
///
/// A started generation always runs to completion, even if nobody listens any more. Generation is ~3× faster
/// than playback, so by the time a phrase is skipped it has usually finished anyway, and the next phrase never
/// overlaps a half-cancelled one.
actor QwenSynthesizer {
    static let language = "russian"
    /// Seconds of audio per streamed chunk. 0.5 s gives ~0.2 s to first audio on Apple silicon.
    static let streamingInterval = 0.5
    /// Both models ship `top_k 50` in generation_config.json, but mlx-audio-swift's defaults leave it at 0
    /// (no limit). Without it speech gets harsher, words are misread and the voice drifts.
    static let topK = 50

    private var model: Qwen3TTSModel?
    private var modelDirectory: URL?
    private var stressDirectory: URL?
    private var stressMarker: RussianStressMarker?
    private static let log = Logger(subsystem: "app.screenvoice.ScreenVoice", category: "Qwen")
    private let referenceDirectory: URL
    private let bundle: Bundle
    /// Prepared reference conditioning per recording file. Preparing one takes a fraction of a second.
    private var conditionings: [Reference: Qwen3TTSModel.Qwen3TTSReferenceConditioning] = [:]
    /// Reference of the last phrase, used when the requested voice has none yet.
    private var lastReference: Reference?

    /// A reference recording and its exact transcript.
    private struct Reference: Hashable {
        let url: URL
        let text: String
    }

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(referenceDirectory: URL = VoiceReference.defaultDirectory, bundle: Bundle = .main) {
        self.referenceDirectory = referenceDirectory
        self.bundle = bundle
    }

    struct LoadResult: Sendable {
        let sampleRate: Double
        /// The stress pack was requested but couldn't be used; phrases are spoken without stress marks.
        let stressError: String?
    }

    /// Loads the Base model if needed, with the stress pack in `stressDirectory` (nil: without). A model loaded
    /// with another pack setting is reloaded, because the LoRA changes its layers.
    @discardableResult
    func load(modelDirectory: URL, stressDirectory: URL? = nil) async throws -> LoadResult {
        await acquire()
        defer { release() }

        var stressError: String?
        if model == nil || self.modelDirectory != modelDirectory || self.stressDirectory != stressDirectory {
            dropModel()
            let qwen = try await Self.loadModel(at: modelDirectory)
            if let stressDirectory {
                do {
                    let marker = try RussianStressMarker(directory: stressDirectory)
                    try StressLoRA.apply(to: qwen, adapterDirectory: QwenModelSpec.stressLoRADirectory(in: stressDirectory))
                    stressMarker = marker
                } catch {
                    // A LoRA half applied is unknown territory: start over without the pack.
                    Self.log.error("Stress pack unavailable: \(error.localizedDescription, privacy: .public)")
                    stressError = error.localizedDescription
                    dropModel()
                    model = try await Self.loadModel(at: modelDirectory)
                }
            }
            if model == nil { model = qwen }
            self.modelDirectory = modelDirectory
            self.stressDirectory = stressDirectory
            guard let model else { throw QwenSynthesizerError.notLoaded }
            // The first generation compiles the GPU kernels (~2.5 s to first audio). Do it now, while the
            // app shows "Loading voice model…", so the first subtitle starts as fast as the rest.
            let conditioning = try conditioning(for: NeuralVoice.defaultMale, model: model)
            for try await _ in model.generateStream(
                text: spokenText("Проверка."),
                conditioning: conditioning,
                generationParameters: Self.parameters(for: model),
                streamingInterval: Self.streamingInterval
            ) {}
        }
        guard let model else { throw QwenSynthesizerError.notLoaded }
        return LoadResult(sampleRate: Double(model.sampleRate), stressError: stressError)
    }

    /// Whether phrases currently get stress marks.
    var marksStress: Bool { stressMarker != nil }

    /// The text the model reads: with RUAccent's stress marks when the pack is loaded. Marking takes a few
    /// milliseconds per phrase; if it fails, the phrase is read as written.
    private func spokenText(_ text: String) -> String {
        guard let stressMarker else { return text }
        do {
            return try stressMarker.mark(text)
        } catch {
            Self.log.error("Stress marking failed: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    func unload() async {
        await acquire()
        defer { release() }
        dropModel()
    }

    /// Creates the reference recording of `voice` with VoiceDesign and saves it where `VoiceReference` finds it.
    /// Unloads Base first so only one model is in memory; Base stays unloaded afterwards.
    func createReference(for voice: NeuralVoice, designModelDirectory: URL) async throws -> URL {
        await acquire()
        defer { release() }
        dropModel()
        defer { Memory.clearCache() }

        let design = try await Self.loadModel(at: designModelDirectory)
        MLXRandom.seed(voice.seed)
        let audio = try await design.generate(
            text: voice.referenceText,
            voice: voice.instruct,
            refAudio: nil,
            refText: nil,
            language: Self.language,
            generationParameters: Self.parameters(for: design)
        )
        let samples = audio.asType(.float32).asArray(Float.self)
        guard samples.count > design.sampleRate else { throw QwenSynthesizerError.emptyReference }

        let destination = VoiceReference.createdURL(for: voice, directory: referenceDirectory)
        try FileManager.default.createDirectory(at: referenceDirectory, withIntermediateDirectories: true)
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.wav")
        try AudioUtils.writeWavFile(samples: samples, sampleRate: design.sampleRate, fileURL: partial)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        return destination
    }

    /// Streams 24 kHz mono samples for `text` in `voice`. A voice without a reference recording yet speaks with
    /// the previous voice (or the built-in narrator of its gender). Stopping iteration does not stop
    /// generation; see the type comment.
    nonisolated func synthesize(
        _ text: String,
        voice: NeuralVoice,
        delivery: NeuralDelivery = .calm
    ) -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        Task { await self.generate(text, voice: voice, delivery: delivery, into: continuation) }
        return stream
    }

    private func generate(
        _ text: String,
        voice: NeuralVoice,
        delivery: NeuralDelivery,
        into continuation: AsyncThrowingStream<[Float], Error>.Continuation
    ) async {
        await acquire()
        defer { release() }
        guard let model else {
            continuation.finish(throwing: QwenSynthesizerError.notLoaded)
            return
        }
        do {
            let conditioning = try conditioning(for: voice, model: model)
            // Qwen3 ignores GenerateParameters.seed; seed MLX's global generator so the same text always
            // gives the same audio.
            MLXRandom.seed(voice.seed)
            let events = model.generateStream(
                text: spokenText(text),
                conditioning: conditioning,
                generationParameters: Self.parameters(for: model, temperature: delivery.temperature),
                streamingInterval: Self.streamingInterval
            )
            for try await event in events {
                if case .audio(let chunk) = event {
                    continuation.yield(chunk.asType(.float32).asArray(Float.self))
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func conditioning(for voice: NeuralVoice, model: Qwen3TTSModel) throws -> Qwen3TTSModel.Qwen3TTSReferenceConditioning {
        let reference: Reference
        if let url = VoiceReference.existingURL(for: voice, directory: referenceDirectory, bundle: bundle) {
            reference = Reference(url: url, text: voice.referenceText)
        } else if let lastReference {
            reference = lastReference
        } else {
            var builtIn = voice.gender == .male ? NeuralVoice.defaultMale : NeuralVoice.defaultFemale
            builtIn.referenceSeconds = voice.referenceSeconds
            guard let url = VoiceReference.bundledURL(for: builtIn, bundle: bundle) else {
                throw QwenSynthesizerError.missingReference
            }
            reference = Reference(url: url, text: builtIn.referenceText)
        }
        lastReference = reference
        if let cached = conditionings[reference] { return cached }

        let audio = try loadAudioArray(from: reference.url, sampleRate: model.sampleRate).1
        let conditioning = try model.prepareReferenceConditioning(refAudio: audio, refText: reference.text, language: Self.language)
        conditionings[reference] = conditioning
        return conditioning
    }

    private static func loadModel(at directory: URL) async throws -> Qwen3TTSModel {
        let loaded = try await TTS.loadModel(modelRepo: directory.path, modelType: "qwen3_tts")
        guard let qwen = loaded as? Qwen3TTSModel else { throw QwenSynthesizerError.unexpectedModel }
        return qwen
    }

    /// The model's defaults with `top_k` fixed; `temperature` nil keeps the default 0.9. One temperature drives
    /// both the talker and its code predictor.
    static func parameters(for model: Qwen3TTSModel, temperature: Float? = nil) -> GenerateParameters {
        var parameters = model.defaultGenerationParameters
        parameters.topK = topK
        if let temperature { parameters.temperature = temperature }
        return parameters
    }

    private func dropModel() {
        model = nil
        modelDirectory = nil
        stressDirectory = nil
        stressMarker = nil
        conditionings.removeAll()
        Memory.clearCache()
    }

    // MARK: Gate

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate straight to the next waiter, so `isBusy` stays true between them.
    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
