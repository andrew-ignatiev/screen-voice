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

    /// Raw lines from the most recent OCR pass (shown for diagnostics).
    var recognizedLines: [String] = []
    var lastOCRDuration: TimeInterval?

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
        recognizedLines = []
        lastOCRDuration = nil
        currentOriginal = ""
        currentTranslation = ""
        isTranslating = false
    }
}
