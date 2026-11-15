import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import os
import Synchronization

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
/// overlaps a half-cancelled one. A generation cancelled while it still waits for its turn is skipped.
actor QwenSynthesizer {
    static let language = "russian"
    /// Seconds of audio per streamed chunk. 0.5 s gives ~0.2 s to first audio on Apple silicon.
    static let streamingInterval = 0.5
    /// Both models ship `top_k 50` in generation_config.json, but mlx-audio-swift's defaults leave it at 0
    /// (no limit). Without it speech gets harsher, words are misread and the voice drifts.
    static let topK = 50
    /// MLX keeps freed GPU buffers for reuse, by default up to the memory limit: ~2–3 GB on top of the 3.1 GB
    /// of weights while speaking, and ~1.9 GB still held after unloading. Generation allocates buffers of the
    /// same sizes again and again, so a small cache serves it as well: with 128 MB the audio is bit-identical and
    /// first audio and generation speed are unchanged (measured over 25 phrases with the stress LoRA).
    static let gpuCacheLimit = 128 << 20
    private static let memoryConfigured: Void = { Memory.cacheLimit = gpuCacheLimit }()

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

    /// Phrases to generate, in the order `start` was called.
    private nonisolated let requests: AsyncStream<Request>.Continuation

    private struct Request: Sendable {
        let text: String
        let voice: NeuralVoice
        let delivery: NeuralDelivery
        let dropped: Flag
        let started: Flag
        let audio: AsyncThrowingStream<[Float], Error>.Continuation
    }

    init(referenceDirectory: URL = VoiceReference.defaultDirectory, bundle: Bundle = .main) {
        _ = Self.memoryConfigured
        self.referenceDirectory = referenceDirectory
        self.bundle = bundle
        let (stream, requests) = AsyncStream<Request>.makeStream()
        self.requests = requests
        // One task generates the phrases one by one, so they come out in the order they were asked for.
        // The priority is fixed: speech must not depend on where the synthesizer happened to be created.
        Task(priority: .userInitiated) { [weak self] in
            for await request in stream {
                guard let self else {
                    request.audio.finish(throwing: QwenSynthesizerError.notLoaded)
                    continue
                }
                await self.generate(request)
            }
        }
    }

    deinit {
        requests.finish()
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
        start(text, voice: voice, delivery: delivery).audio
    }

    /// A phrase being generated. The stream buffers every chunk, so generation can run ahead of playback.
    struct Synthesis: Sendable {
        let audio: AsyncThrowingStream<[Float], Error>
        /// Drops the phrase. A generation still waiting for its turn never starts; a started one finishes
        /// unheard (see the type comment).
        let cancel: @Sendable () -> Void
        /// Whether generation has begun. From then on dropping the phrase saves nothing, and whatever is
        /// generated next waits until this one is done.
        let hasStarted: @Sendable () -> Bool
    }

    /// Starts generating `text` now, e.g. the next phrase while the current one plays. Generations take turns
    /// in the order of the calls, so it begins as soon as the one before it is done. Ending iteration early
    /// cancels it the same way.
    nonisolated func start(_ text: String, voice: NeuralVoice, delivery: NeuralDelivery = .calm) -> Synthesis {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        // A flag, not Task cancellation: cancelling the task would also stop a started generation midway.
        let dropped = Flag()
        let started = Flag()
        continuation.onTermination = { _ in dropped.set() }
        requests.yield(Request(text: text, voice: voice, delivery: delivery, dropped: dropped, started: started, audio: continuation))
        return Synthesis(
            audio: stream,
            cancel: {
                dropped.set()
                continuation.finish()
            },
            hasStarted: { started.isSet }
        )
    }

    final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }

    private func generate(_ request: Request) async {
        let continuation = request.audio
        await acquire()
        defer { release() }
        // Dropped while waiting for its turn (a skipped or cleared phrase): don't generate it at all.
        if request.dropped.isSet {
            continuation.finish()
            return
        }
        let (text, voice, delivery) = (request.text, request.voice, request.delivery)
        guard let model else {
            continuation.finish(throwing: QwenSynthesizerError.notLoaded)
            return
        }
        do {
            let conditioning = try conditioning(for: voice, model: model)
            // Qwen3 ignores GenerateParameters.seed; seed MLX's global generator so the same text always
            // gives the same audio.
            MLXRandom.seed(voice.seed)
            request.started.set()
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
