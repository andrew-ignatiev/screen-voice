import SwiftUI

/// Rows of the Speech section that describe the Qwen3-TTS voice: preset, gender, style and variant.
/// Changes apply from the next phrase; nothing has to be reloaded.
struct NeuralVoiceSettings: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var presetPendingDeletion: VoicePreset?

    var body: some View {
        @Bindable var store = coordinator.settingsStore
        let settings = store.settings
        let selected = settings.selectedVoicePreset

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
        Text("Each variant is a different voice that fits the description. The same variant always sounds the same.")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            Button("Listen") { coordinator.previewVoice() }
                .disabled(coordinator.state.isCaptureActive)
            Spacer()
            if let selected, !selected.isBuiltIn {
                Button("Delete Preset", role: .destructive) { presetPendingDeletion = selected }
            }
            Button("Save as Preset…") {
                presetName = ""
                isNamingPreset = true
            }
            // A voice that already is a preset has nothing new to save.
            .disabled(selected != nil)
        }
        .alert("Save Voice Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { store.settings.saveVoicePreset(named: presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the gender, style and variant. A preset with the same name is replaced.")
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

    private var genderSelection: Binding<VoiceGender> {
        let store = coordinator.settingsStore
        return Binding(
            get: { store.settings.neuralVoice.gender },
            set: { store.settings.neuralVoice.setGender($0) }
        )
    }
}
