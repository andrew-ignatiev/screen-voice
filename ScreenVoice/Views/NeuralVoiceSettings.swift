import SwiftUI

/// Rows of the Speech section that describe the Qwen3-TTS voice: preset, gender, style, variant and reference
/// length. A new combination is created once (VoiceDesign records a reference), then Base clones it.
struct NeuralVoiceSettings: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var presetPendingDeletion: VoicePreset?
    @State private var isRecordingVoice = false
    @State private var isImportingVoice = false

    var body: some View {
        @Bindable var store = coordinator.settingsStore
        let settings = store.settings
        let selected = settings.selectedVoicePreset
        let qwen = coordinator.speech.qwen
        let isCreated = qwen.hasReference(for: settings.neuralVoice)
        let isCreating = qwen.state == .creatingVoice

        Picker("Voice preset", selection: presetSelection) {
            ForEach(VoicePreset.builtIn) { preset in
                Text(preset.name).tag(Optional(preset.id))
            }
            if !settings.voicePresets.isEmpty {
                Divider()
                ForEach(settings.voicePresets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            if selected == nil {
                Divider()
                Text("Custom (not saved)").tag(UUID?.none)
            }
        }

        if let recording = settings.neuralVoice.recording {
            LabeledContent("Recording") {
                Text(verbatim: String(format: "%.1f", recording.seconds) + " " + String(localized: "s", comment: "Seconds unit after the reference length field"))
                    .monospacedDigit()
            }
            Text(verbatim: "“\(recording.text)”")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Picker("Gender", selection: genderSelection) {
                ForEach(VoiceGender.allCases) { gender in
                    Text(gender.displayName).tag(gender)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Style")
                    Spacer()
                    Button("Reset Style") {
                        store.settings.neuralVoice.style = settings.neuralVoice.gender.defaultStyle
                    }
                    .disabled(settings.neuralVoice.style == settings.neuralVoice.gender.defaultStyle)
                }
                TextField("Style", text: $store.settings.neuralVoice.style, prompt: Text(verbatim: "Deep, warm baritone. Calm delivery."), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(4...10)
                    .font(.callout)
                Text("Describe the voice in English: timbre, age, accent, manner. The male or female line is added for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        LabeledContent("Voice variant") {
            HStack(spacing: 4) {
                TextField("Voice variant", value: variantSelection, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                Stepper("Voice variant", value: variantSelection, in: NeuralVoice.seedRange)
                    .labelsHidden()
            }
        }
        Text(settings.neuralVoice.recording == nil
             ? LocalizedStringKey("Each variant is a different voice that fits the description. The same variant always sounds the same.")
             : LocalizedStringKey("With a recording, the variant only changes small details of delivery. The same variant always sounds the same."))
            .font(.caption)
            .foregroundStyle(.secondary)

        if settings.neuralVoice.recording == nil {
            LabeledContent("Reference length") {
                HStack(spacing: 4) {
                    TextField("Reference length", value: referenceSecondsSelection, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 40)
                    Text("s", comment: "Seconds unit after the reference length field")
                        .foregroundStyle(.secondary)
                    Stepper("Reference length", value: referenceSecondsSelection, in: NeuralVoice.referenceSecondsRange)
                        .labelsHidden()
                }
            }
            Text("Approximate length of the recording the voice is cloned from. Each length is a slightly different recording; listen to compare.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Picker("Delivery", selection: $store.settings.neuralDelivery) {
            ForEach(NeuralDelivery.allCases) { delivery in
                Text(delivery.displayName).tag(delivery)
            }
        }
        .pickerStyle(.segmented)
        Text("Sampling temperature. Calm keeps the pitch even; Lively varies intonation more. Applies to every voice from the next phrase.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if !isCreated, settings.neuralVoice.recording != nil {
            Text("The recording of this voice is missing. Record it again.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if !isCreated {
            Text(qwen.designModelStore.isInstalled
                 ? LocalizedStringKey("New voice: Listen creates it first (10–20 seconds, once).")
                 : LocalizedStringKey("New voice: download the voice designer to create it. Until then the built-in narrator speaks."))
                .font(.caption)
                .foregroundStyle(.orange)
        }

        PreviewTextField()

        HStack {
            Button("Listen") { coordinator.previewVoice() }
                .disabled(coordinator.state.isCaptureActive || isCreating || !qwen.modelStore.isInstalled)
            if isCreating {
                ProgressView().controlSize(.small)
                Text("Creating voice…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let selected, !selected.isBuiltIn {
                Button("Delete Preset", role: .destructive) { presetPendingDeletion = selected }
            }
            Button("Record Your Voice…") { isRecordingVoice = true }
                .disabled(coordinator.state.isCaptureActive || isCreating)
            Button("Import Voice Sample…") { isImportingVoice = true }
                .disabled(coordinator.state.isCaptureActive || isCreating)
                .help("Clone a voice from a WAV or MP3 file: 8–15 seconds of one person speaking, without music.")
            Button("Save as Preset…") {
                presetName = ""
                isNamingPreset = true
            }
            // A voice that already is a preset has nothing new to save.
            .disabled(selected != nil)
        }
        .sheet(isPresented: $isRecordingVoice) {
            VoiceRecordingSheet()
        }
        .sheet(isPresented: $isImportingVoice) {
            VoiceRecordingSheet(startsWithImport: true)
        }
        .alert("Save Voice Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { store.settings.saveVoicePreset(named: presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the gender, style, variant and reference length. A preset with the same name is replaced.")
        }
        .confirmationDialog(
            "Delete the “\(presetPendingDeletion?.name ?? "")” preset?",
            isPresented: Binding(get: { presetPendingDeletion != nil }, set: { if !$0 { presetPendingDeletion = nil } })
        ) {
            Button("Delete Preset", role: .destructive) {
                if let preset = presetPendingDeletion {
                    store.settings.deleteVoicePreset(id: preset.id)
                }
                presetPendingDeletion = nil
            }
        } message: {
            Text("The current voice stays selected.")
        }
    }

    private var presetSelection: Binding<UUID?> {
        let store = coordinator.settingsStore
        return Binding(
            get: { store.settings.selectedVoicePreset?.id },
            set: { id in
                if let id { store.settings.applyVoicePreset(id: id) }
            }
        )
    }

    /// Typed values outside the range are clamped, so the variant is never 0 or absurdly large.
    private var variantSelection: Binding<UInt64> {
        let store = coordinator.settingsStore
        return Binding(
            get: { store.settings.neuralVoice.seed },
            set: { store.settings.neuralVoice.seed = min(max($0, NeuralVoice.seedRange.lowerBound), NeuralVoice.seedRange.upperBound) }
        )
    }

    private var referenceSecondsSelection: Binding<Int> {
        let store = coordinator.settingsStore
        let range = NeuralVoice.referenceSecondsRange
        return Binding(
            get: { store.settings.neuralVoice.referenceSeconds },
            set: { store.settings.neuralVoice.referenceSeconds = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    private var genderSelection: Binding<VoiceGender> {
        let store = coordinator.settingsStore
        return Binding(
            get: { store.settings.neuralVoice.gender },
            set: { store.settings.neuralVoice.setGender($0) }
        )
    }
}
