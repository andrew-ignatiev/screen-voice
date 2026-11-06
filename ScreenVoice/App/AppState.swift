import Foundation
import Observation

enum RunState: Equatable, Sendable {
    case idle
    case starting
    case running
    case paused
}

/// Observable UI state. Mutated only by `AppCoordinator`.
@MainActor
@Observable
final class AppState {
    var hasScreenRecordingPermission = false
    var source: CaptureSource?
    var runState: RunState = .idle
    var isTranslating = false
    var translationAvailability: TranslationAvailability = .unknown
    var hasRussianVoice = true

    /// Diagnostics of the most recent OCR pass. They change on every frame, so only `OCRStatsLabel` reads them;
    /// views that read other state don't re-render with each frame.
    var recognizedLineCount = 0
    var lastOCRDuration: TimeInterval?
    /// Whether the last OCR pass found text. Set only when it changes (it drives the status text).
    var hasRecognizedText = false

    var currentOriginal = ""
    var currentTranslation = ""
    private(set) var history: [TranslationResult] = []

    var errorMessage: String?

    static let historyLimit = 50

    var isCaptureActive: Bool { runState == .running || runState == .paused }

    func appendToHistory(_ result: TranslationResult) {
        history.insert(result, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    func clearSession() {
        recognizedLineCount = 0
        lastOCRDuration = nil
        hasRecognizedText = false
        currentOriginal = ""
        currentTranslation = ""
        isTranslating = false
    }
}
