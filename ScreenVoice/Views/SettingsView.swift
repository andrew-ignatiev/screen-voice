import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        @Bindable var store = coordinator.settingsStore
        let isActive = coordinator.state.isCaptureActive

        Form {
            Section("Языки") {
                Picker("Исходный язык", selection: $store.settings.sourceLanguage) {
                    ForEach(SourceLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(isActive)
                LabeledContent("Язык перевода", value: "Русский")
                if isActive {
                    Text("Остановите захват, чтобы сменить исходный язык.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Озвучка") {
                Picker("Движок", selection: $store.settings.speechEngine) {
                    ForEach(SpeechEngineKind.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                if store.settings.speechEngine == .qwen {
                    NeuralModelRow()
                    LabeledContent("Голос Qwen") {
                        HStack {
                            Text("Вариант \(store.settings.qwenVoiceSeed)")
                                .monospacedDigit()
                            Button("Другой голос") { coordinator.nextNeuralVoice() }
                        }
                    }
                    Text("Пока голос не загружен или при ошибке фразы озвучиваются системным голосом ниже.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker(store.settings.speechEngine == .qwen ? "Запасной голос" : "Голос", selection: $store.settings.voiceIdentifier) {
                    Text("Лучший установленный русский").tag(String?.none)
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(Self.qualityName(voice.quality))").tag(Optional(voice.identifier))
                    }
                }
                LabeledContent("Скорость") {
                    Slider(
                        value: $store.settings.speechRate,
                        in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate
                    )
                }
                LabeledContent("Громкость") {
                    Slider(value: $store.settings.speechVolume, in: 0...1)
                }
                Toggle(isOn: $store.settings.skipSpeakerLabels) {
                    Text("Не озвучивать имя перед двоеточием")
                    Text("«Датч: Что-то там» будет произнесено как «Что-то там». На экране текст остаётся полным.")
                }
                Stepper(
                    "Фраз в очереди не больше: \(store.settings.maxQueuedPhrases)",
                    value: $store.settings.maxQueuedPhrases,
                    in: AppSettings.queueRange
                )
                Button("Прослушать") { coordinator.previewVoice() }
                    .disabled(isActive)
            }

            Section("Распознавание") {
                Stepper(
                    "Частота анализа: \(Int(store.settings.framesPerSecond)) кадр/с",
                    value: $store.settings.framesPerSecond,
                    in: AppSettings.framesPerSecondRange,
                    step: 1
                )
                Picker("Режим OCR", selection: $store.settings.ocrAccuracy) {
                    ForEach(OCRAccuracy.allCases) { accuracy in
                        Text(accuracy.displayName).tag(accuracy)
                    }
                }
                .disabled(!store.settings.sourceLanguage.supportsFastRecognition)
                LabeledContent("Мин. уверенность OCR: \(Int(store.settings.minimumConfidence * 100))%") {
                    Slider(value: $store.settings.minimumConfidence, in: 0.1...0.9)
                }
            }

            Section("Отображение") {
                Toggle("Показывать плавающую панель", isOn: $store.settings.showOverlay)
            }

            Section {
                Text("Распознавание, перевод и озвучка выполняются на этом Mac. Кадры и текст не сохраняются на диск и никуда не отправляются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
        .onAppear { voices = SpeechService.russianVoices() }
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "премиум"
        case .enhanced: "улучшенный"
        default: "стандартный"
        }
    }
}

/// Download / status / delete for the Qwen3-TTS model.
struct NeuralModelRow: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let qwen = coordinator.speech.qwen
        let size = ByteCountFormatter.string(fromByteCount: qwen.modelStore.spec.totalBytes, countStyle: .file)
        LabeledContent("Модель") {
            switch qwen.modelStore.state {
            case .notInstalled:
                Button("Загрузить (\(size))") { coordinator.downloadNeuralModel() }
            case .downloading(let fraction):
                HStack {
                    ProgressView(value: fraction)
                        .frame(width: 140)
                    Text("\(Int(fraction * 100))%")
                        .monospacedDigit()
                    Button("Отмена") { qwen.modelStore.cancelDownload() }
                }
            case .verifying:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Проверка файлов…")
                }
            case .installed:
                HStack {
                    Text(Self.loadStateText(qwen.state))
                        .foregroundStyle(.secondary)
                    Button("Удалить", role: .destructive) { coordinator.deleteNeuralModel() }
                        .disabled(coordinator.state.isCaptureActive)
                }
            case .failed(let message):
                VStack(alignment: .trailing) {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.caption)
                    Button("Повторить") { coordinator.downloadNeuralModel() }
                }
            }
        }
    }

    private static func loadStateText(_ state: QwenVoiceState) -> String {
        switch state {
        case .unloaded: "Установлена"
        case .loading: "Загружается в память…"
        case .ready: "Готова"
        case .failed(let message): "Ошибка: \(message)"
        }
    }
}
