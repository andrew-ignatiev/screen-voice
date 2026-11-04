import AVFoundation
import Foundation

/// Speaks one phrase at a time with an installed ru-RU system voice.
/// AVSpeechSynthesizer plays through the default output device and mixes with other apps' audio.
@MainActor
final class SystemPhraseSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    typealias Completion = @MainActor () -> Void

    var voiceIdentifier: String?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var volume: Float = 1

    private let synthesizer = AVSpeechSynthesizer()
    private var current: ObjectIdentifier?
    private var completion: Completion?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Installed Russian voices, best quality first.
    static func russianVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("ru") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    func speak(_ text: String, completion: @escaping Completion) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolveVoice()
        utterance.rate = rate
        utterance.volume = volume
        current = ObjectIdentifier(utterance)
        self.completion = completion
        synthesizer.speak(utterance)
    }

    func pause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
        }
    }

    /// Returns false when there was nothing paused to continue.
    func resume() -> Bool {
        guard synthesizer.isPaused else { return false }
        synthesizer.continueSpeaking()
        return true
    }

    /// Stops immediately; the completion runs from the delegate's didCancel.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return voice
        }
        return Self.russianVoices().first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard id == current, let completion else { return }
        current = nil
        self.completion = nil
        completion()
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
}
