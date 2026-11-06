import SwiftUI
import UniformTypeIdentifiers

/// Records the user reading a passage, or imports a WAV/MP3 sample, and saves it as a voice preset that Base
/// clones. An imported sample is transcribed on the device; the user checks the text.
struct VoiceRecordingSheet: View {
    /// Opens the file picker right away (the "Import Voice Sample…" button).
    var startsWithImport = false

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceRecorder()
    @State private var passageIndex = 0
    @State private var text = RecordedVoice.passages[0]
    @State private var name = ""
    @State private var gender: VoiceGender = .male
    @State private var saveError: String?
    @State private var isChoosingFile = false
    @State private var isTranscribing = false
    @State private var transcriptionNote: String?

    var body: some View {
        let isRecording = recorder.state == .recording
        let imported = recorder.importedFileName != nil
        VStack(alignment: .leading, spacing: 14) {
            Text(imported ? LocalizedStringKey("Import Voice Sample") : LocalizedStringKey("Record Your Voice"))
                .font(.title2.bold())
            if let file = recorder.importedFileName {
                Text("“\(file)”: one speaker, no music, 8–15 seconds of calm, clear speech clones best. Check that the text below is exactly what is said.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Read the text aloud the way the translation should sound: calm and clear, at your usual pace. Use a quiet room and keep the microphone 20–30 cm away. 8–15 seconds is ideal.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(imported ? LocalizedStringKey("Text of the sample") : LocalizedStringKey("Text to read"), text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .lineLimit(3...8)
                        .disabled(isRecording || isTranscribing)
                    HStack(alignment: .firstTextBaseline) {
                        if isTranscribing {
                            ProgressView().controlSize(.small)
                            Text("Recognizing the text…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if imported {
                            Text(transcriptionNote ?? String(localized: "Recognized automatically. Fix any word that differs from the sample."))
                                .font(.caption)
                                .foregroundStyle(transcriptionNote == nil ? .secondary : Color.orange)
                        } else {
                            Text("If you say something different, edit the text to match exactly.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !imported {
                            Button("Another Text") {
                                passageIndex = (passageIndex + 1) % RecordedVoice.passages.count
                                text = RecordedVoice.passages[passageIndex]
                                recorder.discard()
                            }
                            .disabled(isRecording)
                        }
                    }
                }
                .padding(4)
            }

            HStack(spacing: 12) {
                Button {
                    if isRecording {
                        recorder.stop()
                    } else {
                        if imported {
                            text = RecordedVoice.passages[passageIndex]
                            transcriptionNote = nil
                        }
                        Task { await recorder.start() }
                    }
                } label: {
                    Label(
                        isRecording ? LocalizedStringKey("Stop") : (recorder.hasRecording && !imported ? LocalizedStringKey("Record Again") : LocalizedStringKey("Record")),
                        systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .tint(isRecording ? .red : nil)
                .disabled(isTranscribing)
                Button("Choose File…") { isChoosingFile = true }
                    .disabled(isRecording || isTranscribing)
                ProgressView(value: Double(recorder.level))
                    .frame(width: 120)
                Text(verbatim: String(format: "%.1f", recorder.seconds) + " " + String(localized: "s", comment: "Seconds unit after the reference length field"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button(recorder.isPlaying ? "Stop Playback" : "Play") {
                    recorder.isPlaying ? recorder.stopPlayback() : recorder.play()
                }
                .disabled(!recorder.hasRecording)
            }

            if let message = statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if recorder.state == .denied {
                Button("Open Microphone Settings") { coordinator.openMicrophoneSettings() }
            }

            Form {
                Picker("Gender", selection: $gender) {
                    ForEach(VoiceGender.allCases) { gender in
                        Text(gender.displayName).tag(gender)
                    }
                }
                .pickerStyle(.segmented)
                TextField("Preset name", text: $name)
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    recorder.discard()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save Voice") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isTranscribing)
            }
        }
        .padding(20)
        .frame(width: 540)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.wav, .mp3]) { result in
            switch result {
            case .success(let url): importSample(url)
            case .failure(let error): saveError = error.localizedDescription
            }
        }
        .onAppear {
            gender = coordinator.settings.neuralVoice.gender
            if startsWithImport { isChoosingFile = true }
        }
        .onDisappear { recorder.discard() }
    }

    private func importSample(_ url: URL) {
        saveError = nil
        transcriptionNote = nil
        do {
            try recorder.importSample(from: url)
        } catch {
            saveError = String(localized: "Couldn’t read the file: \(error.localizedDescription)")
            return
        }
        guard recorder.hasRecording else { return }
        if trimmedName.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        text = ""
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            do {
                let file = try recorder.temporaryWAV()
                defer { try? FileManager.default.removeItem(at: file) }
                text = try await VoiceTranscriber.transcribe(file)
                if text.isEmpty { transcriptionNote = String(localized: "No words were recognized. Type the text of the sample.") }
            } catch {
                transcriptionNote = error.localizedDescription
            }
        }
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        recorder.hasRecording
            && RecordedVoice.secondsRange.contains(recorder.seconds)
            && !trimmedText.isEmpty
            && !trimmedName.isEmpty
    }

    private var statusMessage: String? {
        if let saveError { return saveError }
        switch recorder.state {
        case .denied:
            return String(localized: "Microphone access is off for ScreenVoice.")
        case .failed(let message):
            return message
        case .recorded:
            let range = RecordedVoice.secondsRange
            if recorder.wasShortened {
                return String(localized: "The sample was longer than 20 seconds, so it was cut at a pause to \(Int(recorder.seconds.rounded())) s.")
            }
            if recorder.seconds < range.lowerBound {
                return recorder.importedFileName == nil
                    ? String(localized: "Too short to clone. Read the whole text.")
                    : String(localized: "Too short to clone: choose a sample with at least 3 seconds of speech.")
            }
            if recorder.seconds > range.upperBound {
                return String(localized: "Too long: keep it under 20 seconds, or pick a shorter text.")
            }
            if !RecordedVoice.recommendedSeconds.contains(recorder.seconds) {
                return String(localized: "Usable, but 8–15 seconds clones best.")
            }
            return nil
        default:
            return nil
        }
    }

    private func save() {
        let recording = RecordedVoice(id: UUID(), text: trimmedText, seconds: recorder.seconds)
        let qwen = coordinator.speech.qwen
        do {
            try recorder.save(to: VoiceReference.recordedURL(for: recording, directory: qwen.referenceDirectory))
        } catch {
            saveError = String(localized: "Couldn’t save the recording: \(error.localizedDescription)")
            return
        }
        qwen.referencesDidChange()
        var voice = coordinator.settings.neuralVoice
        voice.gender = gender
        voice.recording = recording
        let store = coordinator.settingsStore
        store.settings.neuralVoice = voice
        store.settings.saveVoicePreset(named: trimmedName)
        recorder.discard()
        dismiss()
    }
}
