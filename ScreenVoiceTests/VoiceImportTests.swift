import AVFoundation
import Foundation
import Testing
@testable import ScreenVoice

/// Importing a WAV/MP3 voice sample: decoding, mono mix, trimming, cutting long samples at a pause.
@Suite("Voice sample import")
@MainActor
struct VoiceImportTests {
    private static let rate = 24_000.0

    /// A 220 Hz tone for `seconds`, then `gap` seconds of silence, repeated.
    private static func speechLike(_ parts: [(seconds: Double, gap: Double)]) -> [Float] {
        var out: [Float] = []
        for part in parts {
            out += (0..<Int(part.seconds * rate)).map { Float(sin(2 * .pi * 220 * Double($0) / rate)) * 0.3 }
            out += [Float](repeating: 0, count: Int(part.gap * rate))
        }
        return out
    }

    private static func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "import-test-\(UUID().uuidString).\(ext)")
    }

    @Test func longSampleIsCutAtThePauseNearFifteenSeconds() {
        // Pauses end at ~6.5 s, ~13.5 s and ~19.5 s; the one nearest 15 s is at 13.5 s.
        let samples = Self.speechLike([(6, 0.5), (6.5, 0.5), (5.5, 0.5), (10, 0)])
        let cut = VoiceRecorder.cutAtPause(samples, sampleRate: Self.rate)
        let seconds = Double(cut.count) / Self.rate
        #expect(abs(seconds - 13.25) < 0.3, "cut at \(seconds) s")
    }

    @Test func sampleWithoutPausesIsCutAtFifteenSeconds() {
        let cut = VoiceRecorder.cutAtPause(Self.speechLike([(30, 0)]), sampleRate: Self.rate)
        #expect(cut.count == Int(15 * Self.rate))
    }

    @Test func importsStereoWAVAsTrimmedMono() throws {
        let url = Self.temporaryURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = Int(rate * 10)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        // 1 s silence, 8 s tone on the left channel only, 1 s silence.
        for i in 0..<frames {
            let t = Double(i) / rate
            buffer.floatChannelData![0][i] = (1..<9).contains(t) ? Float(sin(2 * .pi * 200 * t)) * 0.2 : 0
            buffer.floatChannelData![1][i] = 0
        }
        try file.write(from: buffer)
        file.close()  // finalizes the WAV header before the importer reads it

        let recorder = VoiceRecorder()
        try recorder.importSample(from: url)
        #expect(recorder.hasRecording)
        #expect(recorder.importedFileName == url.lastPathComponent)
        #expect(!recorder.wasShortened)
        #expect(abs(recorder.seconds - 8.4) < 0.1, "8 s of tone plus 0.2 s padding each side, got \(recorder.seconds)")
    }

    @Test func longWAVIsShortenedAndFlagged() throws {
        let url = Self.temporaryURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try VoiceRecorder.writeWAV(Self.speechLike([(7, 0.6), (7, 0.6), (7, 0.6), (7, 0)]), sampleRate: Self.rate, to: url)
        let recorder = VoiceRecorder()
        try recorder.importSample(from: url)
        #expect(recorder.wasShortened)
        #expect(RecordedVoice.secondsRange.contains(recorder.seconds))
        #expect(recorder.seconds > 8 && recorder.seconds < 16, "got \(recorder.seconds) s")
    }

    @Test func silentFileIsRejected() throws {
        let url = Self.temporaryURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try VoiceRecorder.writeWAV([Float](repeating: 0, count: Int(Self.rate * 5)), sampleRate: Self.rate, to: url)
        let recorder = VoiceRecorder()
        try recorder.importSample(from: url)
        #expect(!recorder.hasRecording)
    }

    nonisolated static let systemMP3 = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/PersonalAudio.framework/Versions/A/Resources/Enrollment_1.mp3")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: systemMP3.path)))
    func decodesMP3() throws {
        let (samples, rate) = try VoiceRecorder.readMono(Self.systemMP3)
        #expect(rate > 8_000)
        #expect(samples.count > Int(rate), "expected over a second of audio")
        #expect(samples.contains { abs($0) > 0.01 })
    }
}
