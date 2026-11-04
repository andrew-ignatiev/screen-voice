import Foundation
import Translation

enum TranslationServiceError: LocalizedError {
    case notPrepared
    case modelNotInstalled
    case unsupportedPair

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            "Перевод не подготовлен."
        case .modelNotInstalled:
            "Языковая модель для выбранной пары не загружена. Нажмите «Загрузить модель»."
        case .unsupportedPair:
            "Выбранная языковая пара не поддерживается Apple Translation на этом Mac."
        }
    }
}

/// Local translation through Apple's Translation framework.
///
/// On macOS 26 a `TranslationSession` can be created directly for an already-installed language pair,
/// which lets translation run outside SwiftUI. Downloading a missing model still needs the SwiftUI
/// `.translationTask` modifier; see `MainView` and `AppCoordinator.modelDownloadFinished(errorMessage:)`.
actor TranslationService {
    private var session: TranslationSessionHandle?

    static func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    func prepare(source: Locale.Language, target: Locale.Language) async throws {
        switch await Self.availability(from: source, to: target) {
        case .installed:
            session = TranslationSessionHandle(session: TranslationSession(installedSource: source, target: target))
        case .needsDownload:
            throw TranslationServiceError.modelNotInstalled
        default:
            throw TranslationServiceError.unsupportedPair
        }
    }

    func translate(_ text: String) async throws -> String {
        guard let session else { throw TranslationServiceError.notPrepared }
        return try await session.translate(text)
    }

    func reset() {
        session = nil
    }
}

/// `TranslationSession` is not `Sendable`, so isolated code (an actor, or SwiftUI's main-actor
/// `.translationTask` closure) cannot pass it to the framework's nonisolated async methods.
/// Each handle has exactly one sequential user — the pipeline's translation loop, or one model-download
/// task — that awaits every call before making the next, so the session is never used concurrently.
final class TranslationSessionHandle: @unchecked Sendable {
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    /// Asks the user to download the language model if it is missing.
    func prepareTranslation() async throws {
        try await session.prepareTranslation()
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }
}
