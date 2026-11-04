import AppKit
import SwiftUI

/// Menu bar item: always shows whether capture is active and lets the user stop it immediately.
struct MenuBarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = coordinator.state

        Text(coordinator.statusText)

        Divider()

        switch state.runState {
        case .idle, .starting:
            Button("Старт") { Task { await coordinator.start() } }
                .disabled(state.source == nil || state.runState == .starting)
        case .running:
            Button("Пауза") { coordinator.pause() }
            Button("Стоп") { Task { await coordinator.stop() } }
        case .paused:
            Button("Продолжить") { coordinator.resume() }
            Button("Стоп") { Task { await coordinator.stop() } }
        }

        Toggle("Плавающая панель", isOn: Binding(
            get: { coordinator.settings.showOverlay },
            set: { coordinator.setOverlayVisible($0) }
        ))

        Divider()

        Button("Открыть ScreenVoice") {
            openWindow(id: ScreenVoiceApp.mainWindowID)
            NSApp.activate()
        }
        SettingsLink { Text("Настройки…") }
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
