import AppKit
import SwiftUI

/// Floating subtitle panel: recognized text and its Russian translation.
struct OverlayView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let state = coordinator.state
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.runState == .paused ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(coordinator.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    coordinator.setOverlayVisible(false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Скрыть панель (обработка продолжится)")
            }

            if !state.currentOriginal.isEmpty {
                Text(state.currentOriginal)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Text(state.currentTranslation.isEmpty ? "Перевод появится здесь" : state.currentTranslation)
                .font(.title3.weight(.semibold))
                .foregroundStyle(state.currentTranslation.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(4)
    }
}

/// Hosts `OverlayView` in a non-activating, always-on-top panel that also floats over full-screen video.
@MainActor
final class OverlayPanelController {
    private unowned let coordinator: AppCoordinator
    private var panel: NSPanel?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let size = CGSize(width: 560, height: 150)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 320, height: 90)

        let hosting = NSHostingView(rootView: OverlayView().environment(coordinator))
        panel.contentView = hosting

        if !panel.setFrameUsingName("ScreenVoiceOverlay"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 60))
        }
        panel.setFrameAutosaveName("ScreenVoiceOverlay")
        return panel
    }
}
