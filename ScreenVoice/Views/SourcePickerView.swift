import SwiftUI

struct SourcePickerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var windows: [WindowInfo] = []
    @State private var selection: WindowInfo.ID?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Источник текста")
                .font(.title2.weight(.semibold))

            Text("Лучше всего выделить только полосу с субтитрами: так распознавание быстрее и точнее.")
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    dismiss()
                    Task { await coordinator.selectRegion() }
                } label: {
                    Label("Выделить область экрана…", systemImage: "rectangle.dashed")
                }
                Button {
                    coordinator.selectEntireMainDisplay()
                    dismiss()
                } label: {
                    Label("Весь главный экран", systemImage: "display")
                }
            }

            Divider()

            HStack {
                Text("Или окно приложения").font(.headline)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить список окон")
            }

            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(windows, selection: $selection) { window in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.appName).fontWeight(.medium)
                            Text(window.title.isEmpty ? "Без названия" : window.title)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(minHeight: 240)

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Выбрать окно") {
                    if let window = windows.first(where: { $0.id == selection }) {
                        coordinator.select(.window(window))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            windows = try await coordinator.availableWindows()
        } catch {
            coordinator.refreshPermission()
            loadError = coordinator.state.hasScreenRecordingPermission
                ? error.localizedDescription
                : (CaptureError.permissionDenied.errorDescription ?? error.localizedDescription)
        }
        isLoading = false
    }
}
