import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        @Bindable var store = coordinator.settingsStore
        let isActive = coordinator.state.isCaptureActive

        Form {
            Section("Languages") {
                Picker("Source language", selection: $store.settings.sourceLanguage) {
                    ForEach(SourceLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(isActive)
                LabeledContent("Target language", value: AppSettings.targetLanguageName)
                if isActive {
                    Text("Stop capture to change the source language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Speech") {
                Picker("Engine", selection: $store.settings.speechEngine) {
                    ForEach(SpeechEngineKind.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                if store.settings.speechEngine == .qwen {
                    NeuralModelRow(kind: .speech)
                    NeuralModelRow(kind: .designer)
                    NeuralModelRow(kind: .stress)
                    NeuralVoiceSettings()
                    Text("Until the voice is loaded, or if it fails, phrases are spoken with the system voice below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker(store.settings.speechEngine == .qwen ? LocalizedStringKey("Fallback voice") : LocalizedStringKey("Voice"), selection: $store.settings.voiceIdentifier) {
                    Text("Best installed Russian voice").tag(String?.none)
                    ForEach(voices, id: \.identifier) { voice in
                        Text(verbatim: "\(voice.name) · \(Self.qualityName(voice.quality))").tag(Optional(voice.identifier))
                    }
                }
                LabeledContent("Speed") {
                    Slider(
                        value: $store.settings.speechRate,
                        in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate
                    )
                }
                LabeledContent("Volume") {
                    Slider(value: $store.settings.speechVolume, in: 0...1)
                }
                Toggle(isOn: $store.settings.skipSpeakerLabels) {
                    Text("Don’t speak the name before a colon")
                    Text("“Dutch: Something” is spoken as “Something”. The full text stays on screen.")
                }
                Stepper(
                    "Max queued phrases: \(store.settings.maxQueuedPhrases)",
                    value: $store.settings.maxQueuedPhrases,
                    in: AppSettings.queueRange
                )
                if store.settings.speechEngine != .qwen {
                    PreviewTextField()
                    Button("Preview") { coordinator.previewVoice() }
                        .disabled(isActive)
                }
            }

            Section("Recognition") {
                Stepper(
                    "Analysis rate: \(Int(store.settings.framesPerSecond)) fps",
                    value: $store.settings.framesPerSecond,
                    in: AppSettings.framesPerSecondRange,
                    step: 1
                )
                Picker("OCR mode", selection: $store.settings.ocrAccuracy) {
                    ForEach(OCRAccuracy.allCases) { accuracy in
                        Text(accuracy.displayName).tag(accuracy)
                    }
                }
                .disabled(!store.settings.sourceLanguage.supportsFastRecognition)
                LabeledContent("Min. OCR confidence: \(Int(store.settings.minimumConfidence * 100))%") {
                    Slider(value: $store.settings.minimumConfidence, in: 0.1...0.9)
                }
            }

            Section("Display") {
                Toggle("Show floating panel", isOn: $store.settings.showOverlay)
            }

            Section {
                Text("Recognition, translation and speech run on this Mac. Frames and text are never saved to disk or sent anywhere.")
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
        case .premium: String(localized: "premium", comment: "Voice quality")
        case .enhanced: String(localized: "enhanced", comment: "Voice quality")
        default: String(localized: "standard", comment: "Voice quality")
        }
    }
}

/// Download / status / delete for a Qwen3-TTS model or the Russian stress pack.
struct NeuralModelRow: View {
    enum Kind {
        /// Base: speaks every phrase.
        case speech
        /// VoiceDesign: creates new voices from a description. Optional.
        case designer
        /// RUAccent + stress LoRA. Optional.
        case stress
    }

    let kind: Kind
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let qwen = coordinator.speech.qwen
        @Bindable var settings = coordinator.settingsStore
        let store = switch kind {
        case .speech: qwen.modelStore
        case .designer: qwen.designModelStore
        case .stress: qwen.stressStore
        }
        let size = ByteCountFormatter.string(fromByteCount: store.spec.totalBytes, countStyle: .file)
        let busy = coordinator.state.isCaptureActive || qwen.state == .creatingVoice
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                switch store.state {
                case .notInstalled:
                    Button("Download (\(size))") { download() }
                case .downloading(let fraction):
                    HStack {
                        ProgressView(value: fraction)
                            .frame(width: 140)
                        Text("\(Int(fraction * 100))%")
                            .monospacedDigit()
                        Button("Cancel") { store.cancelDownload() }
                    }
                case .verifying:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Verifying files…")
                    }
                case .installed:
                    HStack {
                        if kind == .stress {
                            Toggle("Mark stress", isOn: $settings.settings.russianStress)
                                .toggleStyle(.checkbox)
                                .disabled(qwen.state == .loading || qwen.state == .creatingVoice)
                        } else {
                            Text(kind == .speech ? Self.loadStateText(qwen.state) : String(localized: "Installed", comment: "Qwen model state"))
                                .foregroundStyle(.secondary)
                        }
                        Button("Delete", role: .destructive) { delete() }
                            .disabled(busy || (kind == .stress && qwen.state == .loading))
                    }
                case .failed(let message):
                    VStack(alignment: .trailing) {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.caption)
                        Button("Retry") { download() }
                    }
                }
            }
            if kind == .designer {
                Text("Optional. Needed only to create a new voice from its description; it is loaded for a few seconds and then unloaded. The built-in narrators and voices already created work without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if kind == .stress {
                Text("Optional. RUAccent marks the stressed vowel of each word and a stress LoRA makes the voice follow the marks, so words like замок or мука are stressed by their meaning. RUAccent still guesses wrong now and then. Speech gets about 10 percent slower.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = qwen.stressError, store.state == .installed {
                    Text("Russian stress unavailable: \(error) Speaking without stress marks.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onChange(of: store.state) { _, state in
            if kind == .stress, state == .installed { coordinator.stressPackDidInstall() }
        }
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .speech: "Model"
        case .designer: "Voice designer"
        case .stress: "Russian stress"
        }
    }

    private func download() {
        switch kind {
        case .speech: coordinator.downloadNeuralModel()
        case .designer: coordinator.downloadVoiceDesigner()
        case .stress: coordinator.downloadStressPack()
        }
    }

    private func delete() {
        switch kind {
        case .speech: coordinator.deleteNeuralModel()
        case .designer: coordinator.deleteVoiceDesigner()
        case .stress: coordinator.deleteStressPack()
        }
    }

    private static func loadStateText(_ state: QwenVoiceState) -> String {
        switch state {
        case .unloaded: String(localized: "Installed", comment: "Qwen model state")
        case .loading: String(localized: "Loading into memory…")
        case .creatingVoice: String(localized: "Creating voice…")
        case .ready: String(localized: "Ready", comment: "Qwen model state")
        case .failed(let message): String(localized: "Error: \(message)")
        }
    }
}

/// Multi-line field for the phrase Listen/Preview speaks. Left empty, the built-in phrase is used.
struct PreviewTextField: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var store = coordinator.settingsStore
        VStack(alignment: .leading, spacing: 4) {
            Text("Text to listen")
            TextEditor(text: $store.settings.previewText)
                .font(.body)
                .frame(minHeight: 54, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if store.settings.previewText.isEmpty {
                        Text(verbatim: SpeechService.previewText)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack(alignment: .firstTextBaseline) {
                Text("Type any phrase to hear the voice say it. Leave empty for the default phrase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.settings.previewText.isEmpty {
                    Button("Reset") { store.settings.previewText = "" }
                        .controlSize(.small)
                }
            }
        }
    }
}
