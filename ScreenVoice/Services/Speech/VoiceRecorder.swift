import AVFoundation
import Foundation
import Observation

/// Records a short passage from the microphone, or imports a WAV/MP3 sample, for Base to clone. Audio stays in memory until `save(to:)`;
/// silence at both ends is trimmed and the level is normalized, because the clone copies the recording's
/// loudness and pauses too.
@MainActor
@Observable
final class VoiceRecorder {
    enum State: Equatable {
        case idle
        case recording
        case recorded
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Input level of the last ~50 ms, 0…1, for the meter.
    private(set) var level: Float = 0
    private(set) var seconds: Double = 0
    private(set) var isPlaying = false
    /// File name of the imported sample; nil for a microphone recording.
    private(set) var importedFileName: String?
    /// The imported sample was longer than `RecordedVoice.secondsRange` and was cut at a pause.
    private(set) var wasShortened = false

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let buffer = SampleBuffer()
    @ObservationIgnored private var sampleRate: Double = 48_000
    @ObservationIgnored private var samples: [Float] = []
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playbackFile: URL?
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    var hasRecording: Bool { state == .recorded }

    func start() async {
        stopPlayback()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                state = .denied
                return
            }
        default:
            state = .denied
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .failed(String(localized: "No microphone found."))
            return
        }
        sampleRate = format.sampleRate
        buffer.reset()
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(into: buffer))
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .failed(error.localizedDescription)
            return
        }
        state = .recording
        seconds = 0
        importedFileName = nil
        wasShortened = false
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.level = self.buffer.recentLevel
                self.seconds = Double(self.buffer.count) / self.sampleRate
                // Nobody needs more than a minute; stop instead of filling memory.
                if self.seconds > 60 { self.stop() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        meterTask?.cancel()
        meterTask = nil
        level = 0
        samples = Self.trimmedAndNormalized(buffer.take(), sampleRate: sampleRate)
        seconds = Double(samples.count) / sampleRate
        state = samples.isEmpty ? .failed(String(localized: "Nothing was heard. Check the microphone and try again.")) : .recorded
    }

    func play() {
        guard hasRecording else { return }
        stopPlayback()
        do {
            let url = FileManager.default.temporaryDirectory.appending(path: "voice-preview-\(UUID().uuidString).wav")
            try Self.writeWAV(samples, sampleRate: sampleRate, to: url)
            playbackFile = url
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            self.player = player
            isPlaying = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(player.duration))
                if self?.player === player { self?.stopPlayback() }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        if let playbackFile { try? FileManager.default.removeItem(at: playbackFile) }
        playbackFile = nil
    }

    /// Writes the trimmed recording. The file appears complete or not at all.
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.deletingPathExtension().appendingPathExtension("partial.wav")
        try Self.writeWAV(samples, sampleRate: sampleRate, to: partial)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
    }

    /// Stops everything and forgets the recording.
    func discard() {
        if state == .recording { stop() }
        stopPlayback()
        samples = []
        seconds = 0
        importedFileName = nil
        wasShortened = false
        state = .idle
    }

    // MARK: Importing

    /// Longest stretch of a file that is read; a voice sample needs only seconds.
    nonisolated static let maxImportSeconds: Double = 120

    /// Loads a WAV or MP3 sample (any channel count and sample rate): mixed to mono, trimmed and normalized
    /// like a recording, and cut at a pause near 15 s if it is longer than the clone accepts.
    func importSample(from url: URL) throws {
        if state == .recording { stop() }
        stopPlayback()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let (raw, rate) = try Self.readMono(url)
        var processed = Self.trimmedAndNormalized(raw, sampleRate: rate)
        guard !processed.isEmpty else {
            state = .failed(String(localized: "No speech found in the file."))
            return
        }
        var shortened = false
        if Double(processed.count) / rate > RecordedVoice.secondsRange.upperBound {
            processed = Self.trimmedAndNormalized(Self.cutAtPause(processed, sampleRate: rate), sampleRate: rate)
            shortened = true
        }
        samples = processed
        sampleRate = rate
        seconds = Double(processed.count) / rate
        importedFileName = url.lastPathComponent
        wasShortened = shortened
        state = .recorded
    }

    /// Writes the current sample to a temporary WAV (for transcription). The caller deletes it.
    func temporaryWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-sample-\(UUID().uuidString).wav")
        try Self.writeWAV(samples, sampleRate: sampleRate, to: url)
        return url
    }

    /// The file's first `maxImportSeconds`, averaged to mono.
    nonisolated static func readMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length), maxImportSeconds * format.sampleRate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer, frameCount: frames)
        guard let channels = buffer.floatChannelData else { return ([], format.sampleRate) }
        let count = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            let channel = channels[c]
            for i in 0..<count { mono[i] += channel[i] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for i in 0..<count { mono[i] *= scale }
        }
        return (mono, format.sampleRate)
    }

    /// Cuts a long sample at the pause (≥ 0.25 s of near-silence) closest to `target` seconds, between 8 s and
    /// the clone's maximum, so the transcript stays whole. Without such a pause it cuts at `target`.
    nonisolated static func cutAtPause(_ samples: [Float], sampleRate: Double, target: Double = 15) -> [Float] {
        let window = max(1, Int(sampleRate * 0.02))
        var levels: [Float] = []
        var start = 0
        while start + window <= samples.count {
            var energy: Float = 0
            for i in start..<(start + window) { energy += samples[i] * samples[i] }
            levels.append((energy / Float(window)).squareRoot())
            start += window
        }
        let threshold = max(0.003, (levels.max() ?? 0) * 0.06)
        let windowSeconds = Double(window) / sampleRate
        let minimumRun = Int((0.25 / windowSeconds).rounded(.up))
        let lowest = 8.0, highest = RecordedVoice.secondsRange.upperBound
        var best: (distance: Double, cut: Int)?
        var runStart: Int?
        for index in 0...levels.count {
            // A sentinel after the end closes a trailing silent run.
            let level = index < levels.count ? levels[index] : .infinity
            if level <= threshold {
                if runStart == nil { runStart = index }
            } else if let first = runStart {
                if index - first >= minimumRun {
                    let middle = (first + index) / 2
                    let time = Double(middle) * windowSeconds
                    if time >= lowest, time <= highest, abs(time - target) < (best?.distance ?? .infinity) {
                        best = (abs(time - target), middle * window)
                    }
                }
                runStart = nil
            }
        }
        let cut = best?.cut ?? Int(target * sampleRate)
        return Array(samples.prefix(cut))
    }

    // MARK: Processing

    /// Drops leading and trailing silence (keeping 0.2 s around the speech) and scales the peak to 0.9,
    /// with at most 8× gain so a near-silent recording isn't blown up into noise.
    nonisolated static func trimmedAndNormalized(_ samples: [Float], sampleRate: Double) -> [Float] {
        let window = max(1, Int(sampleRate * 0.02))
        guard samples.count >= window else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / window)
        var start = 0
        while start + window <= samples.count {
            var energy: Float = 0
            for i in start..<(start + window) { energy += samples[i] * samples[i] }
            levels.append((energy / Float(window)).squareRoot())
            start += window
        }
        let loudest = levels.max() ?? 0
        let threshold = max(0.003, loudest * 0.06)
        guard let first = levels.firstIndex(where: { $0 > threshold }),
              let last = levels.lastIndex(where: { $0 > threshold })
        else { return [] }
        let pad = Int(sampleRate * 0.2)
        let lower = max(0, first * window - pad)
        let upper = min(samples.count, (last + 1) * window + pad)
        let speech = samples[lower..<upper]
        let peak = speech.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return [] }
        let gain = min(0.9 / peak, 8)
        return speech.map { $0 * gain }
    }

    /// 16-bit mono WAV.
    nonisolated static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            pcm.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: pcm)
    }

    /// Built outside the main actor: the tap runs on the audio thread, and a main-actor closure would trap there.
    nonisolated private static func tap(into buffer: SampleBuffer) -> AVAudioNodeTapBlock {
        { pcm, _ in
            guard let channel = pcm.floatChannelData?[0] else { return }
            buffer.append(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
        }
    }
}

/// Samples written by the audio thread and read by the main actor.
private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastLevel: Float = 0

    var count: Int {
        lock.withLock { samples.count }
    }

    var recentLevel: Float {
        lock.withLock { lastLevel }
    }

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        var energy: Float = 0
        for value in chunk { energy += value * value }
        let rms = chunk.isEmpty ? 0 : (energy / Float(chunk.count)).squareRoot()
        lock.withLock {
            samples.append(contentsOf: chunk)
            // ~-50 dBFS…0 dBFS mapped to 0…1 reads naturally on a meter.
            lastLevel = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))
        }
    }

    func take() -> [Float] {
        lock.withLock {
            defer { samples = [] }
            return samples
        }
    }

    func reset() {
        lock.withLock {
            samples = []
            lastLevel = 0
        }
    }
}
