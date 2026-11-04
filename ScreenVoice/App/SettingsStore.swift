import Foundation
import Observation

/// Persists `AppSettings` in UserDefaults. No secrets are needed for the MVP configuration,
/// so nothing is stored in the Keychain.
@MainActor
@Observable
final class SettingsStore {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            onChange?(oldValue, settings)
        }
    }

    /// Called with (old, new) after every change.
    @ObservationIgnored var onChange: ((AppSettings, AppSettings) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    private static let key = "ScreenVoice.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
