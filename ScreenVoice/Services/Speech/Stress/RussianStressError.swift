import Foundation

enum RussianStressError: LocalizedError {
    case badFile(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .badFile(let name): String(localized: "The stress file \(name) can’t be read.")
        case .runtime(let message): String(localized: "Stress marking failed: \(message).")
        }
    }
}
