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
                    NeuralModelRow()
                    LabeledContent("Qwen voice") {
                        HStack {
                            Text("Variant \(store.settings.qwenVoiceSeed)")
                                .monospacedDigit()
                            Button("Another voice") { coordinator.nextNeuralVoice() }
                        }
                    }
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
                Button("Preview") { coordinator.previewVoice() }
                    .disabled(isActive)
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

/// Download / status / delete for the Qwen3-TTS model.
struct NeuralModelRow: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let qwen = coordinator.speech.qwen
        let size = ByteCountFormatter.string(fromByteCount: qwen.modelStore.spec.totalBytes, countStyle: .file)
        LabeledContent("Model") {
            switch qwen.modelStore.state {
            case .notInstalled:
                Button("Download (\(size))") { coordinator.downloadNeuralModel() }
            case .downloading(let fraction):
                HStack {
                    ProgressView(value: fraction)
                        .frame(width: 140)
                    Text("\(Int(fraction * 100))%")
                        .monospacedDigit()
                    Button("Cancel") { qwen.modelStore.cancelDownload() }
                }
            case .verifying:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifying files…")
                }
            case .installed:
                HStack {
                    Text(Self.loadStateText(qwen.state))
                        .foregroundStyle(.secondary)
                    Button("Delete", role: .destructive) { coordinator.deleteNeuralModel() }
                        .disabled(coordinator.state.isCaptureActive)
                }
            case .failed(let message):
                VStack(alignment: .trailing) {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.caption)
                    Button("Retry") { coordinator.downloadNeuralModel() }
                }
            }
        }
    }

    private static func loadStateText(_ state: QwenVoiceState) -> String {
        switch state {
        case .unloaded: String(localized: "Installed", comment: "Qwen model state")
        case .loading: String(localized: "Loading into memory…")
        case .ready: String(localized: "Ready", comment: "Qwen model state")
        case .failed(let message): String(localized: "Error: \(message)")
        }
    }
}
