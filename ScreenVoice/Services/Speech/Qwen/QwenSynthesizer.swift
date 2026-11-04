import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS

enum QwenSynthesizerError: LocalizedError {
    case notLoaded
    case unexpectedModel

    var errorDescription: String? {
        switch self {
        case .notLoaded: String(localized: "The Qwen3-TTS model isn’t loaded.")
        case .unexpectedModel: String(localized: "The model folder doesn’t contain Qwen3-TTS.")
        }
    }
}

/// Owns the Qwen3-TTS model and the voice conditioning. Every MLX operation runs behind a gate, one at a time:
/// the model and its streaming decoder state are not safe for concurrent use.
///
/// A started generation always runs to completion, even if nobody listens any more. Generation is ~4× faster
/// than playback, so by the time a phrase is skipped it has usually finished anyway, and the next phrase never
/// overlaps a half-cancelled one.
actor QwenSynthesizer {
    /// What the generated placeholder voice says. Also the reference transcript for voice conditioning.
    /// Spoken content, not UI: always Russian, never localized.
    static let referenceText = "Добрый вечер. Сегодня я расскажу вам короткую историю о старом маяке на берегу холодного моря."
    static let language = "russian"
    /// Seconds of audio per streamed chunk. 0.5 s gives ~0.1 s to first audio on Apple silicon.
    static let streamingInterval = 0.5

    private var model: Qwen3TTSModel?
    private var modelDirectory: URL?
    private var conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning?
    private var voiceSeed: UInt64?

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Loads the model (if needed) and prepares the voice for `voiceSeed`. Returns the output sample rate.
    func load(modelDirectory: URL, voiceSeed: UInt64, voiceDirectory: URL) async throws -> Double {
        await acquire()
        defer { release() }

        if model == nil || self.modelDirectory != modelDirectory {
            dropModel()
            let loaded = try await TTS.loadModel(modelRepo: modelDirectory.path, modelType: "qwen3_tts")
            guard let qwen = loaded as? Qwen3TTSModel else { throw QwenSynthesizerError.unexpectedModel }
            model = qwen
            self.modelDirectory = modelDirectory
        }
        guard let model else { throw QwenSynthesizerError.notLoaded }

        if conditioning == nil || self.voiceSeed != voiceSeed {
            conditioning = nil
            let reference = try await referenceAudio(model: model, seed: voiceSeed, directory: voiceDirectory)
            conditioning = try model.prepareReferenceConditioning(
                refAudio: reference,
                refText: Self.referenceText,
                language: Self.language
            )
            self.voiceSeed = voiceSeed
        }
        return Double(model.sampleRate)
    }

    func unload() async {
        await acquire()
        defer { release() }
        dropModel()
    }

    /// Streams 24 kHz mono samples for `text`. Stopping iteration does not stop generation; see the type comment.
    nonisolated func synthesize(_ text: String) -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        Task { await self.generate(text, into: continuation) }
        return stream
    }

    private func generate(_ text: String, into continuation: AsyncThrowingStream<[Float], Error>.Continuation) async {
        await acquire()
        defer { release() }
        guard let model, let conditioning else {
            continuation.finish(throwing: QwenSynthesizerError.notLoaded)
            return
        }
        do {
            let events = model.generateStream(
                text: text,
                conditioning: conditioning,
                generationParameters: model.defaultGenerationParameters,
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

    /// The placeholder voice: Qwen3 Base speaking `referenceText` with a seeded random voice, cached on disk
    /// so the same seed always gives the same voice.
    private func referenceAudio(model: Qwen3TTSModel, seed: UInt64, directory: URL) async throws -> MLXArray {
        let url = directory.appending(path: "qwen-voice-\(seed).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Qwen3 ignores GenerateParameters.seed; seed MLX's global generator instead.
            MLXRandom.seed(seed)
            let audio = try await model.generate(
                text: Self.referenceText,
                voice: nil,
                refAudio: nil,
                refText: nil,
                language: Self.language,
                generationParameters: model.defaultGenerationParameters
            )
            let samples = audio.asType(.float32).asArray(Float.self)
            try AudioUtils.writeWavFile(samples: samples, sampleRate: model.sampleRate, fileURL: url)
        }
        let (_, reference) = try loadAudioArray(from: url, sampleRate: model.sampleRate)
        return reference
    }

    private func dropModel() {
        model = nil
        modelDirectory = nil
        conditioning = nil
        voiceSeed = nil
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
