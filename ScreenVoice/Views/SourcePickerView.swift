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
            Text("Text Source")
                .font(.title2.weight(.semibold))

            Text("For best results, select just the subtitle strip: recognition is faster and more accurate.")
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    dismiss()
                    Task { await coordinator.selectRegion() }
                } label: {
                    Label("Select Screen Region…", systemImage: "rectangle.dashed")
                }
                Button {
                    coordinator.selectEntireMainDisplay()
                    dismiss()
                } label: {
                    Label("Entire Main Display", systemImage: "display")
                }
            }

            Divider()

            HStack {
                Text("Or an App Window").font(.headline)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh window list")
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
                            Text(window.title.isEmpty ? String(localized: "Untitled") : window.title)
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
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Window") {
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
