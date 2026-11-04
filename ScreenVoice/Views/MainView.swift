import AppKit
import SwiftUI
import Translation

struct MainView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isPickingSource = false

    var body: some View {
        @Bindable var coordinator = coordinator
        let state = coordinator.state

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !state.hasScreenRecordingPermission {
                    PermissionBanner()
                }
                if !state.hasRussianVoice {
                    VoiceBanner()
                }
                if coordinator.settings.speechEngine == .qwen, !coordinator.speech.qwen.modelStore.isInstalled {
                    NeuralModelBanner()
                }
                TranslationBanner()

                sourceSection
                controls

                if let error = state.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                currentSection
                historySection
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Настройки", systemImage: "gearshape")
                }
                .help("Настройки: язык, голос, имена перед двоеточием (⌘,)")
            }
        }
        .sheet(isPresented: $isPickingSource) {
            SourcePickerView()
        }
        .translationTask(coordinator.modelDownloadConfiguration) { session in
            // Shows the system prompt to download the language model, if it is missing.
            let handle = TranslationSessionHandle(session: session)
            do {
                try await handle.prepareTranslation()
                await coordinator.modelDownloadFinished(errorMessage: nil)
            } catch {
                await coordinator.modelDownloadFinished(errorMessage: error.localizedDescription)
            }
        }
        .task {
            await coordinator.onAppear()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshPermission()
            coordinator.refreshVoiceAvailability()
        }
    }

    private var sourceSection: some View {
        GroupBox("Источник") {
            HStack {
                Text(coordinator.state.source?.description ?? "Не выбран")
                    .foregroundStyle(coordinator.state.source == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Выбрать область/окно…") { isPickingSource = true }
                    .disabled(coordinator.state.runState != .idle)
            }
            .padding(6)
        }
    }

    private var controls: some View {
        let state = coordinator.state
        return HStack(spacing: 10) {
            Button {
                Task { await coordinator.start() }
            } label: {
                Label("Старт", systemImage: "play.fill")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(state.runState != .idle || state.source == nil)

            if state.runState == .paused {
                Button {
                    coordinator.resume()
                } label: {
                    Label("Продолжить", systemImage: "playpause.fill")
                }
            } else {
                Button {
                    coordinator.pause()
                } label: {
                    Label("Пауза", systemImage: "pause.fill")
                }
                .disabled(state.runState != .running)
            }

            Button {
                Task { await coordinator.stop() }
            } label: {
                Label("Стоп", systemImage: "stop.fill")
            }
            .disabled(!state.isCaptureActive)

            Spacer()

            StatusPill(text: coordinator.statusText, active: state.isCaptureActive, paused: state.runState == .paused)
        }
        .controlSize(.large)
    }

    private var currentSection: some View {
        let state = coordinator.state
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.currentOriginal.isEmpty ? "—" : state.currentOriginal)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(state.currentTranslation.isEmpty ? "—" : state.currentTranslation)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)

                Divider()

                HStack(spacing: 12) {
                    Toggle("Плавающая панель", isOn: Binding(
                        get: { coordinator.settings.showOverlay },
                        set: { coordinator.setOverlayVisible($0) }
                    ))
                    Spacer()
                    if coordinator.speech.queuedCount > 0 {
                        Text("В очереди: \(coordinator.speech.queuedCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Пропустить реплику") { coordinator.speech.skipCurrent() }
                        .disabled(!coordinator.speech.isSpeaking)
                    Button("Очистить очередь") { coordinator.speech.clearQueue() }
                        .disabled(coordinator.speech.queuedCount == 0)
                }
                .font(.callout)

                if let duration = state.lastOCRDuration, state.isCaptureActive {
                    Text("OCR: \(Int(duration * 1000)) мс · строк: \(state.recognizedLines.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("Сейчас")
        }
    }

    private var historySection: some View {
        GroupBox("История") {
            if coordinator.state.history.isEmpty {
                Text("Переведённые реплики появятся здесь.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(coordinator.state.history) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.original)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(item.translated)
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct StatusPill: View {
    let text: String
    let active: Bool
    let paused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(paused ? Color.orange : active ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }
}

private struct PermissionBanner: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Нужно разрешение на запись экрана", systemImage: "rectangle.dashed.badge.record")
                    .font(.headline)
                Text("ScreenVoice читает текст только из выбранного окна или области и не сохраняет кадры. Включите ScreenVoice в «Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука». После включения macOS может попросить перезапустить приложение.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Запросить разрешение") { coordinator.requestPermission() }
                    Button("Открыть Системные настройки") { coordinator.openScreenRecordingSettings() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

private struct VoiceBanner: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Русский голос не установлен", systemImage: "speaker.slash")
                    .font(.headline)
                Text("Откройте «Системные настройки → Универсальный доступ → Устный контент → Системный голос → Управление голосами…» и загрузите русский голос, например Milena.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Открыть настройки устного контента") { coordinator.openSpokenContentSettings() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

private struct NeuralModelBanner: View {
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Модель Qwen3-TTS не загружена", systemImage: "waveform.badge.exclamationmark")
                    .font(.headline)
                Text("Выбран нейросетевой голос, но модель ещё не загружена. Пока фразы озвучиваются системным голосом.")
                    .fixedSize(horizontal: false, vertical: true)
                NeuralModelRow()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

private struct TranslationBanner: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let language = coordinator.settings.sourceLanguage.displayName
        switch coordinator.state.translationAvailability {
        case .installed, .unknown, .checking:
            EmptyView()
        case .needsDownload:
            banner(
                title: "Нужна языковая модель",
                text: "Модель перевода «\(language) → Русский» ещё не загружена на этот Mac.",
                icon: "arrow.down.circle"
            ) {
                Button("Загрузить модель") { coordinator.requestModelDownload() }
            }
        case .downloading:
            banner(title: "Загрузка языковой модели…", text: "Подтвердите загрузку в системном окне. Перевод начнёт работать после её завершения.", icon: "arrow.down.circle") {
                ProgressView().controlSize(.small)
            }
        case .unsupported:
            banner(
                title: "Языковая пара не поддерживается",
                text: "Apple Translation на этом Mac не поддерживает перевод «\(language) → Русский». Выберите другой исходный язык в настройках.",
                icon: "xmark.octagon"
            ) {
                SettingsLink { Text("Открыть настройки") }
            }
        case .failed(let message):
            banner(title: "Не удалось подготовить перевод", text: message, icon: "exclamationmark.triangle") {
                Button("Повторить") { coordinator.requestModelDownload() }
            }
        }
    }

    private func banner(
        title: String,
        text: String,
        icon: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(.headline)
                Text(text).fixedSize(horizontal: false, vertical: true)
                HStack { actions() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
