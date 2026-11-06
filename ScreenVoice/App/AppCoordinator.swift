import AppKit
import Foundation
import Observation
import Translation

/// Owns the services and translates user actions into pipeline commands.
@MainActor
@Observable
final class AppCoordinator {
    let state = AppState()
    let settingsStore = SettingsStore()
    let speech = SpeechService()

    /// Non-nil while a model download is requested. Bound to `.translationTask` in `MainView`.
    var modelDownloadConfiguration: TranslationSession.Configuration?

    @ObservationIgnored private let pipeline = PipelineCoordinator()
    @ObservationIgnored private let regionSelector = RegionSelector()
    @ObservationIgnored private lazy var overlay = OverlayPanelController(coordinator: self)
    @ObservationIgnored private var idleUnloadTask: Task<Void, Never>?

    /// How long the Qwen model stays in memory after a preview when capture is not running.
    static let neuralIdleUnloadDelay: Duration = .seconds(120)

    var settings: AppSettings { settingsStore.settings }

    init() {
        pipeline.delegate = self
        speech.apply(settingsStore.settings)
        settingsStore.onChange = { [weak self] old, new in
            self?.settingsDidChange(from: old, to: new)
        }
        refreshPermission()
        refreshVoiceAvailability()
    }

    // MARK: Status

    var statusText: String {
        if !state.hasScreenRecordingPermission { return String(localized: "Waiting for screen recording permission") }
        if state.translationAvailability == .downloading { return String(localized: "Downloading language model…") }
        if speech.qwen.state == .loading { return String(localized: "Loading voice model…") }
        if speech.qwen.state == .creatingVoice { return String(localized: "Creating voice…") }
        switch state.runState {
        case .idle: return state.errorMessage == nil ? String(localized: "Idle") : String(localized: "Error")
        case .starting: return String(localized: "Starting capture…")
        case .paused: return String(localized: "Paused", comment: "Status: capture is paused")
        case .running:
            if speech.isSpeaking { return String(localized: "Speaking") }
            if state.isTranslating { return String(localized: "Translating") }
            if !state.recognizedLines.isEmpty { return String(localized: "Recognizing") }
            return String(localized: "Capture active")
        }
    }

    // MARK: Lifecycle

    func onAppear() async {
        refreshPermission()
        refreshVoiceAvailability()
        await checkTranslationAvailability()
    }

    func refreshPermission() {
        state.hasScreenRecordingPermission = CaptureService.hasPermission()
    }

    func requestPermission() {
        CaptureService.requestPermission()
        refreshPermission()
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openSpokenContentSettings() {
        open("x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")
    }

    func refreshVoiceAvailability() {
        state.hasRussianVoice = !SpeechService.russianVoices().isEmpty
    }

    // MARK: Source selection

    func availableWindows() async throws -> [WindowInfo] {
        try await pipeline.availableWindows()
    }

    func select(_ source: CaptureSource) {
        state.source = source
        state.errorMessage = nil
    }

    func selectRegion() async {
        if let region = await regionSelector.selectRegion() {
            select(.region(region))
        }
    }

    func selectEntireMainDisplay() {
        guard let screen = NSScreen.main, let displayID = screen.displayID else { return }
        let rect = CGRect(origin: .zero, size: screen.frame.size)
        select(.region(RegionSelection(displayID: displayID, rect: rect, scale: screen.backingScaleFactor)))
    }

    // MARK: Translation model

    func checkTranslationAvailability() async {
        let language = settings.sourceLanguage
        if state.translationAvailability != .downloading {
            state.translationAvailability = .checking
        }
        let availability = await TranslationService.availability(from: language.localeLanguage, to: AppSettings.targetLanguage)
        // Ignore stale answers if the language changed while we were waiting.
        guard language == settings.sourceLanguage, state.translationAvailability != .downloading else { return }
        state.translationAvailability = availability
    }

    func requestModelDownload() {
        state.translationAvailability = .downloading
        let configuration = TranslationSession.Configuration(
            source: settings.sourceLanguage.localeLanguage,
            target: AppSettings.targetLanguage
        )
        if modelDownloadConfiguration == configuration {
            modelDownloadConfiguration?.invalidate()
        } else {
            modelDownloadConfiguration = configuration
        }
    }

    /// Called from SwiftUI's `.translationTask` after `prepareTranslation()` (the system download prompt)
    /// finishes. The session itself stays in the view's task because `TranslationSession` is not Sendable.
    func modelDownloadFinished(errorMessage: String?) async {
        if let errorMessage {
            state.translationAvailability = .failed(errorMessage)
        } else {
            state.translationAvailability = .checking
            await checkTranslationAvailability()
        }
        modelDownloadConfiguration = nil
    }

    // MARK: Run control

    func start() async {
        guard state.runState == .idle else { return }
        state.errorMessage = nil

        refreshPermission()
        guard state.hasScreenRecordingPermission else {
            requestPermission()
            state.errorMessage = CaptureError.permissionDenied.errorDescription
            return
        }
        guard let source = state.source else {
            state.errorMessage = String(localized: "Choose a window or screen region first.")
            return
        }

        await checkTranslationAvailability()
        switch state.translationAvailability {
        case .installed:
            break
        case .needsDownload:
            state.errorMessage = TranslationServiceError.modelNotInstalled.errorDescription
            return
        case .unsupported:
            state.errorMessage = TranslationServiceError.unsupportedPair.errorDescription
            return
        default:
            state.errorMessage = String(localized: "Couldn’t check translation availability.")
            return
        }

        refreshVoiceAvailability()
        state.clearSession()
        state.runState = .starting
        idleUnloadTask?.cancel()
        await prepareNeuralVoice()
        do {
            try await pipeline.start(source: source, settings: settings)
            state.runState = .running
            updateOverlayVisibility()
        } catch {
            state.runState = .idle
            state.errorMessage = error.localizedDescription
            refreshPermission()
        }
    }

    func pause() {
        guard state.runState == .running else { return }
        pipeline.setPaused(true)
        speech.pause()
        state.runState = .paused
    }

    func resume() {
        guard state.runState == .paused else { return }
        pipeline.setPaused(false)
        speech.resume()
        state.runState = .running
    }

    func stop() async {
        await pipeline.stop()
        speech.stopAll()
        state.runState = .idle
        state.isTranslating = false
        updateOverlayVisibility()
        await speech.qwen.unload()
    }

    // MARK: Neural voice

    /// Plays the preview phrase with the selected engine. For Qwen, creates the voice first if it is new,
    /// then loads Base if needed, so Listen plays exactly what subtitles will sound like.
    func previewVoice() {
        Task {
            if settings.speechEngine == .qwen, speech.qwen.modelStore.isInstalled {
                state.errorMessage = nil
                await prepareNeuralVoice()
                if !state.isCaptureActive { scheduleIdleUnload() }
            }
            speech.preview(settings.previewText)
        }
    }

    func downloadNeuralModel() {
        speech.qwen.modelStore.download()
    }

    func deleteNeuralModel() {
        Task {
            speech.stopAll()
            await speech.qwen.unload()
            speech.qwen.modelStore.delete()
        }
    }

    func downloadVoiceDesigner() {
        speech.qwen.designModelStore.download()
    }

    /// Downloads the Russian stress pack. A loaded model picks it up after the download (see `stressPackDidInstall`).
    func downloadStressPack() {
        speech.qwen.stressStore.download()
    }

    /// Called when the stress pack's download finishes: a loaded model is reloaded with it.
    func stressPackDidInstall() {
        Task { await speech.qwen.applyStressSetting() }
    }

    func deleteStressPack() {
        Task { await speech.qwen.deleteStressPack() }
    }

    /// Voices already created keep working; only new ones can't be created any more.
    func deleteVoiceDesigner() {
        speech.qwen.designModelStore.delete()
    }

    /// Creates the selected voice if it is new (when the designer is installed), then loads Base.
    private func prepareNeuralVoice() async {
        guard settings.speechEngine == .qwen, speech.qwen.modelStore.isInstalled else { return }
        let voice = settings.neuralVoice
        if !speech.qwen.hasReference(for: voice) {
            if voice.recording != nil {
                state.errorMessage = QwenVoiceControllerError.recordingMissing.errorDescription
            } else if speech.qwen.designModelStore.isInstalled {
                do {
                    try await speech.qwen.createVoice(voice)
                } catch {
                    state.errorMessage = String(localized: "Couldn’t create the voice: \(error.localizedDescription)")
                }
            } else {
                state.errorMessage = String(localized: "This voice hasn’t been created yet, so the built-in narrator speaks instead. Download the voice designer to create it.")
            }
        }
        await speech.qwen.prepare()
        if case .failed(let message) = speech.qwen.state {
            state.errorMessage = String(localized: "Qwen3-TTS voice unavailable: \(message) Using the system voice.")
        } else if let message = speech.qwen.stressError {
            state.errorMessage = String(localized: "Russian stress unavailable: \(message) Speaking without stress marks.")
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.neuralIdleUnloadDelay)
                guard let self, !Task.isCancelled, !self.state.isCaptureActive else { return }
                if !self.speech.isSpeaking { break }
            }
            await self?.speech.qwen.unload()
        }
    }

    // MARK: Overlay

    func setOverlayVisible(_ visible: Bool) {
        settingsStore.settings.showOverlay = visible
    }

    private func updateOverlayVisibility() {
        if settings.showOverlay && state.isCaptureActive {
            overlay.show()
        } else {
            overlay.hide()
        }
    }

    // MARK: Settings

    private func settingsDidChange(from old: AppSettings, to new: AppSettings) {
        speech.apply(new)
        pipeline.apply(new, previous: old)
        // Voice changes need no reload: each phrase carries its voice.
        if old.usedRecordings != new.usedRecordings {
            VoiceReference.removeUnusedRecordings(keeping: new.usedRecordings, directory: speech.qwen.referenceDirectory)
        }
        if old.speechEngine != new.speechEngine {
            if new.speechEngine == .system {
                idleUnloadTask?.cancel()
                Task { await speech.qwen.unload() }
            } else if state.isCaptureActive || speech.qwen.state != .unloaded {
                // Phrases keep using the system voice until the model is loaded.
                Task { await prepareNeuralVoice() }
            }
        }
        if old.russianStress != new.russianStress {
            Task { await speech.qwen.applyStressSetting() }
        }
        if old.sourceLanguage != new.sourceLanguage {
            Task { await checkTranslationAvailability() }
        }
        if old.showOverlay != new.showOverlay {
            updateOverlayVisibility()
        }
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppCoordinator: PipelineDelegate {
    func pipeline(_ pipeline: PipelineCoordinator, didEmit event: PipelineEvent) {
        switch event {
        case .recognized(let lines, let duration):
            state.recognizedLines = lines.map(\.text)
            state.lastOCRDuration = duration
        case .confirmed(let phrase):
            state.currentOriginal = phrase
        case .translating(let active):
            state.isTranslating = active
        case .translated(let result):
            state.currentOriginal = result.original
            state.currentTranslation = result.translated
            state.appendToHistory(result)
            // The panel and history keep the full line; only the spoken text drops speaker labels.
            let spoken = settings.skipSpeakerLabels ? SpeakerLabelFilter.strip(result.translated) : result.translated
            if state.runState == .running, !spoken.isEmpty {
                speech.enqueue(spoken)
            }
        case .failure(let message):
            state.errorMessage = message
        case .captureStopped(let message):
            Task {
                await stop()
                state.errorMessage = message.map { String(localized: "Capture stopped by the system: \($0)") }
                    ?? String(localized: "Capture stopped by the system.")
            }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
