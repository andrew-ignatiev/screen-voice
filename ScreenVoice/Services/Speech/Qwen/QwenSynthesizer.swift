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

/// Owns the Qwen3-TTS VoiceDesign model. Every MLX operation runs behind a gate, one at a time: the model and
/// its streaming decoder state are not safe for concurrent use, and the seed is process-wide MLX state.
///
/// Each phrase is generated from the voice description with the voice's seed, so a voice sounds the same on
/// every phrase and the same text always gives the same audio. Without the fixed seed the model invents a
/// new voice for every phrase.
///
/// A started generation always runs to completion, even if nobody listens any more. Generation is ~3.5× faster
/// than playback, so by the time a phrase is skipped it has usually finished anyway, and the next phrase never
/// overlaps a half-cancelled one.
actor QwenSynthesizer {
    static let language = "russian"
    /// Seconds of audio per streamed chunk. 0.5 s gives ~0.15 s to first audio on Apple silicon.
    static let streamingInterval = 0.5

    private var model: Qwen3TTSModel?
    private var modelDirectory: URL?

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Loads the model if needed. Returns the output sample rate.
    func load(modelDirectory: URL) async throws -> Double {
        await acquire()
        defer { release() }

        if model == nil || self.modelDirectory != modelDirectory {
            dropModel()
            let loaded = try await TTS.loadModel(modelRepo: modelDirectory.path, modelType: "qwen3_tts")
            guard let qwen = loaded as? Qwen3TTSModel else { throw QwenSynthesizerError.unexpectedModel }
            // The first generation compiles the GPU kernels (~2.5 s to first audio). Do it now, while the
            // app shows "Loading voice model…", so the first subtitle starts as fast as the rest.
            for try await _ in qwen.generateStream(
                text: "Проверка.",
                voice: NeuralVoice.defaultMale.instruct,
                refAudio: nil,
                refText: nil,
                language: Self.language,
                generationParameters: qwen.defaultGenerationParameters,
                streamingInterval: Self.streamingInterval
            ) {}
            model = qwen
            self.modelDirectory = modelDirectory
        }
        guard let model else { throw QwenSynthesizerError.notLoaded }
        return Double(model.sampleRate)
    }

    func unload() async {
        await acquire()
        defer { release() }
        dropModel()
    }

    /// Streams 24 kHz mono samples for `text` in `voice`. Stopping iteration does not stop generation;
    /// see the type comment.
    nonisolated func synthesize(_ text: String, voice: NeuralVoice) -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        Task { await self.generate(text, voice: voice, into: continuation) }
        return stream
    }

    private func generate(
        _ text: String,
        voice: NeuralVoice,
        into continuation: AsyncThrowingStream<[Float], Error>.Continuation
    ) async {
        await acquire()
        defer { release() }
        guard let model else {
            continuation.finish(throwing: QwenSynthesizerError.notLoaded)
            return
        }
        do {
            // Qwen3 ignores GenerateParameters.seed; seed MLX's global generator instead.
            MLXRandom.seed(voice.seed)
            let events = model.generateStream(
                text: text,
                voice: voice.instruct,
                refAudio: nil,
                refText: nil,
                language: Self.language,
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

    private func dropModel() {
        model = nil
        modelDirectory = nil
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
