import Foundation

struct TranslationResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let original: String
    let translated: String
    let createdAt: Date

    init(original: String, translated: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.original = original
        self.translated = translated
        self.createdAt = createdAt
    }
}

/// State of the on-device translation model for the selected language pair.
enum TranslationAvailability: Equatable, Sendable {
    case unknown
    case checking
    case installed
    case needsDownload
    case downloading
    case unsupported
    case failed(String)
}
