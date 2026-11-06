import AVFoundation
import Foundation

/// Plays one Qwen phrase at a time: schedules streamed chunks on an AVAudioPlayerNode as they arrive and
/// reports when the last one has been heard. Speed is changed with a time-stretch unit (pitch is preserved),
/// because Qwen3 has no speaking-rate control.
@MainActor
final class QwenPhraseSpeaker {
    typealias Completion = @MainActor (Result<Void, Error>) -> Void

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?

    private var phraseID = 0
    private var pendingBuffers = 0
    private var generationFinished = false
    private var completion: Completion?
    private var feedTask: Task<Void, Never>?
    private var configurationObserver: (any NSObjectProtocol)?

    var rate: Float = 1 {
        didSet {
            timePitch.rate = rate
            timePitch.bypass = rate == 1
        }
    }

    var volume: Float = 1 {
        didSet { player.volume = volume }
    }

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.bypass = true
        // The engine stops itself when the output device changes; end the phrase instead of hanging on it.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Maps the AVSpeechUtterance rate slider (0…1, normal 0.5) to a playback multiplier (0.5×…2×).
    nonisolated static func playbackRate(forSpeechRate speechRate: Float) -> Float {
        let r = min(max(speechRate, 0), 1)
        return r <= 0.5 ? 0.5 + r : 1 + (r - 0.5) * 2
    }

    /// The inverse of `playbackRate(forSpeechRate:)`, used to speed the system voice up by the same factor.
    /// Multipliers above 2× map past the slider's end (> 1); callers clamp.
    nonisolated static func speechRate(forPlaybackRate playbackRate: Float) -> Float {
        playbackRate <= 1 ? max(playbackRate - 0.5, 0) : 0.5 + (playbackRate - 1) / 2
    }

    func speak(_ text: String, voice: NeuralVoice, delivery: NeuralDelivery, synthesizer: QwenSynthesizer, sampleRate: Double, completion: @escaping Completion) {
        stop()
        phraseID += 1
        let id = phraseID
        self.completion = completion
        pendingBuffers = 0
        generationFinished = false

        do {
            try startEngine(sampleRate: sampleRate)
        } catch {
            finish(id, .failure(error))
            return
        }

        feedTask = Task { [weak self] in
            do {
                for try await samples in synthesizer.synthesize(text, voice: voice, delivery: delivery) {
                    guard let self, id == self.phraseID else { return }
                    self.schedule(samples, id: id)
                }
                self?.generationDidFinish(id)
            } catch {
                self?.finish(id, .failure(error))
            }
        }
    }

    func pause() {
        player.pause()
    }

    func resume() {
        if completion != nil {
            player.play()
        }
    }

    /// Silences the current phrase immediately and reports it as finished.
    func stop() {
        // Invalidate the phrase first so late buffer callbacks and chunks are ignored.
        phraseID += 1
        feedTask?.cancel()
        feedTask = nil
        player.stop()
        pendingBuffers = 0
        if let completion {
            self.completion = nil
            completion(.success(()))
        }
    }

    // MARK: Private

    private func startEngine(sampleRate: Double) throws {
        if format?.sampleRate != sampleRate {
            guard let newFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw QwenSynthesizerError.notLoaded
            }
            engine.stop()
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(player, to: timePitch, format: newFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: newFormat)
            format = newFormat
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.volume = volume
        player.play()
    }

    private func schedule(_ samples: [Float], id: Int) {
        guard !samples.isEmpty, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferDidPlay(id) }
        }
    }

    private func bufferDidPlay(_ id: Int) {
        guard id == phraseID else { return }
        pendingBuffers -= 1
        finishIfDone(id)
    }

    private func generationDidFinish(_ id: Int) {
        guard id == phraseID else { return }
        generationFinished = true
        finishIfDone(id)
    }

    private func finishIfDone(_ id: Int) {
        if generationFinished, pendingBuffers <= 0 {
            finish(id, .success(()))
        }
    }

    private func finish(_ id: Int, _ result: Result<Void, Error>) {
        guard id == phraseID, let completion else { return }
        self.completion = nil
        feedTask = nil
        completion(result)
    }
}
