import SwiftUI

@main
struct ScreenVoiceApp: App {
    static let mainWindowID = "main"

    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        Window("ScreenVoice", id: Self.mainWindowID) {
            MainView()
                .environment(coordinator)
                .frame(minWidth: 560, minHeight: 600)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(coordinator)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(coordinator)
        } label: {
            Image(systemName: coordinator.state.isCaptureActive ? "waveform.circle.fill" : "waveform.circle")
        }
    }
}
