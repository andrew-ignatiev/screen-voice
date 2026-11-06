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
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings: language, voice, names before a colon (⌘,)")
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
        GroupBox("Source") {
            HStack {
                Text(coordinator.state.source?.description ?? String(localized: "Not selected"))
                    .foregroundStyle(coordinator.state.source == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose Region or Window…") { isPickingSource = true }
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
                Label("Start", systemImage: "play.fill")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(state.runState != .idle || state.source == nil)

            if state.runState == .paused {
                Button {
                    coordinator.resume()
                } label: {
                    Label("Resume", systemImage: "playpause.fill")
                }
            } else {
                Button {
                    coordinator.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .disabled(state.runState != .running)
            }

            Button {
                Task { await coordinator.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!state.isCaptureActive)

            Toggle("Catch up", isOn: Binding(
                get: { coordinator.settings.speedUpWhenBehind },
                set: { coordinator.settingsStore.settings.speedUpWhenBehind = $0 }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.regular)
            .help("Speak faster when behind: 1.25 times as soon as the next subtitle is waiting, 1.5 times with two or more. Normal speed returns once it catches up.")

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
                    Toggle("Floating panel", isOn: Binding(
                        get: { coordinator.settings.showOverlay },
                        set: { coordinator.setOverlayVisible($0) }
                    ))
                    Spacer()
                    if coordinator.speech.catchUpFactor > 1 {
                        Text("Faster: \(coordinator.speech.catchUpFactor.formatted(.number.precision(.fractionLength(0...2))))×")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    if coordinator.speech.queuedCount > 0 {
                        Text("In queue: \(coordinator.speech.queuedCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Skip Line") { coordinator.speech.skipCurrent() }
                        .disabled(!coordinator.speech.isSpeaking)
                    Button("Clear Queue") { coordinator.speech.clearQueue() }
                        .disabled(coordinator.speech.queuedCount == 0)
                }
                .font(.callout)

                if let duration = state.lastOCRDuration, state.isCaptureActive {
                    Text("OCR: \(Int(duration * 1000)) ms · lines: \(state.recognizedLines.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text("Now")
        }
    }

    private var historySection: some View {
        GroupBox("History") {
            if coordinator.state.history.isEmpty {
                Text("Translated lines will appear here.")
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
                Label("Screen recording permission required", systemImage: "rectangle.dashed.badge.record")
                    .font(.headline)
                Text("ScreenVoice reads text only from the chosen window or region and never saves frames. Turn on ScreenVoice in System Settings → Privacy & Security → Screen & System Audio Recording. macOS may ask you to relaunch the app afterwards.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Request Permission") { coordinator.requestPermission() }
                    Button("Open System Settings") { coordinator.openScreenRecordingSettings() }
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
                Label("No Russian voice installed", systemImage: "speaker.slash")
                    .font(.headline)
                Text("Open System Settings → Accessibility → Spoken Content → System Voice → Manage Voices… and download a Russian voice, for example Milena.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Spoken Content Settings") { coordinator.openSpokenContentSettings() }
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
                Label("Qwen3-TTS model not downloaded", systemImage: "waveform.badge.exclamationmark")
                    .font(.headline)
                Text("The neural voice is selected, but its model isn’t downloaded yet. Until then, phrases are spoken with the system voice.")
                    .fixedSize(horizontal: false, vertical: true)
                NeuralModelRow(kind: .speech)
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
        let target = AppSettings.targetLanguageName
        switch coordinator.state.translationAvailability {
        case .installed, .unknown, .checking:
            EmptyView()
        case .needsDownload:
            banner(
                title: String(localized: "Language model required"),
                text: String(localized: "The “\(language) → \(target)” translation model isn’t downloaded to this Mac yet."),
                icon: "arrow.down.circle"
            ) {
                Button("Download Model") { coordinator.requestModelDownload() }
            }
        case .downloading:
            banner(title: String(localized: "Downloading language model…"), text: String(localized: "Confirm the download in the system dialog. Translation starts working once it finishes."), icon: "arrow.down.circle") {
                ProgressView().controlSize(.small)
            }
        case .unsupported:
            banner(
                title: String(localized: "Language pair not supported"),
                text: String(localized: "Apple Translation on this Mac doesn’t support “\(language) → \(target)”. Choose another source language in Settings."),
                icon: "xmark.octagon"
            ) {
                SettingsLink { Text("Open Settings") }
            }
        case .failed(let message):
            banner(title: String(localized: "Couldn’t prepare translation"), text: message, icon: "exclamationmark.triangle") {
                Button("Retry") { coordinator.requestModelDownload() }
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
                Label { Text(verbatim: title) } icon: { Image(systemName: icon) }.font(.headline)
                Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                HStack { actions() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
