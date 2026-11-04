import AVFoundation
import Foundation
import Observation

/// Bounded FIFO of phrases waiting to be spoken. When full, the oldest phrase is dropped, and phrases
/// that waited too long are skipped: by then a newer subtitle is already on screen.
struct SpeechQueue: Sendable {
    struct Item: Equatable, Sendable {
        let text: String
        let enqueuedAt: TimeInterval
    }

    private(set) var capacity: Int
    var maxAge: TimeInterval
    private(set) var items: [Item] = []

    init(capacity: Int, maxAge: TimeInterval) {
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
    }

    mutating func enqueue(_ text: String, at now: TimeInterval) {
        items.append(Item(text: text, enqueuedAt: now))
        trim()
    }

    mutating func next(at now: TimeInterval) -> Item? {
        items.removeAll { now - $0.enqueuedAt > maxAge }
        return items.isEmpty ? nil : items.removeFirst()
    }

    mutating func setCapacity(_ newCapacity: Int) {
        capacity = max(1, newCapacity)
        trim()
    }

    mutating func removeAll() {
        items.removeAll()
    }

    private mutating func trim() {
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }
}

/// Speaks translations one at a time through the selected engine: the Qwen3-TTS neural voice when it is
/// loaded, otherwise the installed ru-RU system voice. Both mix with other apps' audio; the original
/// video's sound is left untouched.
@MainActor
@Observable
final class SpeechService {
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private(set) var queuedCount = 0
    /// Last Qwen failure while speaking; the phrase was spoken with the system voice instead.
    private(set) var lastNeuralError: String?

    let qwen: QwenVoiceController

    @ObservationIgnored private let system = SystemPhraseSpeaker()
    @ObservationIgnored private let neural = QwenPhraseSpeaker()
    @ObservationIgnored private var queue = SpeechQueue(capacity: 3, maxAge: 10)
    @ObservationIgnored private var preferredEngine: SpeechEngineKind = .system
    /// Phrase being spoken and the engine speaking it. Completions for any other phrase are ignored.
    @ObservationIgnored private var current: (id: Int, engine: SpeechEngineKind)?
    @ObservationIgnored private var lastPhraseID = 0

    /// Spoken content, not UI: always Russian (the target language), never localized.
    static let previewText = "Привет! Так будет звучать перевод субтитров."

    init(qwen: QwenVoiceController = QwenVoiceController()) {
        self.qwen = qwen
    }

    /// Installed Russian voices, best quality first.
    static func russianVoices() -> [AVSpeechSynthesisVoice] {
        SystemPhraseSpeaker.russianVoices()
    }

    func apply(_ settings: AppSettings) {
        preferredEngine = settings.speechEngine
        let rate = min(max(settings.speechRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        let volume = min(max(settings.speechVolume, 0), 1)
        system.voiceIdentifier = settings.voiceIdentifier
        system.rate = rate
        system.volume = volume
        neural.rate = QwenPhraseSpeaker.playbackRate(forSpeechRate: rate)
        neural.volume = volume
        queue.setCapacity(settings.maxQueuedPhrases)
        queuedCount = queue.items.count
    }

    func enqueue(_ text: String) {
        queue.enqueue(text, at: Self.now)
        queuedCount = queue.items.count
        speakNextIfPossible()
    }

    func preview() {
        stopAll()
        enqueue(Self.previewText)
    }

    func pause() {
        isPaused = true
        switch current?.engine {
        case .system: system.pause()
        case .qwen: neural.pause()
        case nil: break
        }
    }

    func resume() {
        isPaused = false
        switch current?.engine {
        case .system:
            if !system.resume() { speakNextIfPossible() }
        case .qwen:
            neural.resume()
        case nil:
            speakNextIfPossible()
        }
    }

    /// Stops the current phrase and moves on to the next queued one.
    func skipCurrent() {
        switch current?.engine {
        case .system: system.stop()
        case .qwen: neural.stop()
        case nil: break
        }
    }

    func clearQueue() {
        queue.removeAll()
        queuedCount = 0
    }

    func stopAll() {
        clearQueue()
        isPaused = false
        current = nil
        isSpeaking = false
        system.stop()
        neural.stop()
    }

    private func speakNextIfPossible() {
        guard !isPaused, current == nil, let item = queue.next(at: Self.now) else {
            queuedCount = queue.items.count
            return
        }
        lastPhraseID += 1
        let id = lastPhraseID
        isSpeaking = true
        queuedCount = queue.items.count

        if preferredEngine == .qwen, let synthesizer = qwen.readySynthesizer {
            current = (id, .qwen)
            neural.speak(item.text, synthesizer: synthesizer, sampleRate: qwen.sampleRate) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.neuralPhraseFailed(id, text: item.text, error: error)
                } else {
                    self.phraseEnded(id)
                }
            }
        } else {
            speakWithSystemVoice(item.text, id: id)
        }
    }

    private func speakWithSystemVoice(_ text: String, id: Int) {
        current = (id, .system)
        system.speak(text) { [weak self] in self?.phraseEnded(id) }
    }

    /// Keeps the subtitle audible: the same phrase is spoken with the system voice.
    private func neuralPhraseFailed(_ id: Int, text: String, error: any Error) {
        guard current?.id == id else { return }
        lastNeuralError = error.localizedDescription
        speakWithSystemVoice(text, id: id)
    }

    private func phraseEnded(_ id: Int) {
        guard current?.id == id else { return }
        current = nil
        isSpeaking = false
        speakNextIfPossible()
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
