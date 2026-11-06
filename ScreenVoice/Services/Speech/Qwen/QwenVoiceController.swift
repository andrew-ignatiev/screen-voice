import Foundation
import Observation

enum QwenVoiceControllerError: LocalizedError {
    case designerNotInstalled
    case recordingMissing

    var errorDescription: String? {
        switch self {
        case .designerNotInstalled: String(localized: "Download the voice designer to create new voices.")
        case .recordingMissing: String(localized: "The recording of this voice is missing. Record it again.")
        }
    }
}

enum QwenVoiceState: Equatable, Sendable {
    case unloaded
    case loading
    case creatingVoice
    case ready
    case failed(String)
}

/// Main-actor face of the Qwen engine: installation of the models and the stress pack, load/unload of the synthesizer and
/// creation of voices. Operations run strictly in call order, so a quick Stop → Start cannot interleave them.
@MainActor
@Observable
final class QwenVoiceController {
    /// Base: speaks every phrase. Required.
    let modelStore: QwenModelStore
    /// VoiceDesign: creates reference recordings for new voices. Optional; built-in narrators don't need it.
    let designModelStore: QwenModelStore
    /// Russian stress pack: RUAccent + the stress LoRA. Optional.
    let stressStore: QwenModelStore
    /// Whether the stress pack should be used when installed (the "Mark stress" setting).
    var marksStressWhenInstalled = true
    /// Why the installed stress pack isn't in use, if it failed to load.
    private(set) var stressError: String?
    /// The stress pack the loaded model was asked to use (nil: none), even if it failed to load.
    @ObservationIgnored private var loadedStressDirectory: URL?
    private(set) var state: QwenVoiceState = .unloaded
    private(set) var sampleRate: Double = 24_000
    /// Bumped whenever a reference recording is created, so views re-check `hasReference(for:)`.
    private(set) var referencesRevision = 0

    @ObservationIgnored let synthesizer: QwenSynthesizer
    @ObservationIgnored private var lastOperation: Task<Void, Never>?

    @ObservationIgnored let referenceDirectory: URL

    init(
        modelStore: QwenModelStore = QwenModelStore(spec: .base8bit),
        designModelStore: QwenModelStore = QwenModelStore(spec: .voiceDesign8bit),
        stressStore: QwenModelStore = QwenModelStore(spec: .russianStress),
        referenceDirectory: URL = VoiceReference.defaultDirectory
    ) {
        self.modelStore = modelStore
        self.designModelStore = designModelStore
        self.stressStore = stressStore
        self.referenceDirectory = referenceDirectory
        synthesizer = QwenSynthesizer(referenceDirectory: referenceDirectory)
    }

    /// Whether `voice` can be spoken as itself. Without a reference it speaks with the previous voice.
    func hasReference(for voice: NeuralVoice) -> Bool {
        _ = referencesRevision
        return VoiceReference.existingURL(for: voice, directory: referenceDirectory) != nil
    }

    /// Call after a reference file was added outside `createVoice`, e.g. a microphone recording.
    func referencesDidChange() {
        referencesRevision += 1
    }

    /// Creates the voice's reference with VoiceDesign (~10–20 s: VoiceDesign is loaded, used and unloaded),
    /// then loads Base again. Does nothing if the voice already has one.
    func createVoice(_ voice: NeuralVoice) async throws {
        var failure: (any Error)?
        await serialized { controller in
            guard !controller.hasReference(for: voice) else { return }
            guard voice.recording == nil else {
                failure = QwenVoiceControllerError.recordingMissing
                return
            }
            guard controller.designModelStore.isInstalled else {
                failure = QwenVoiceControllerError.designerNotInstalled
                return
            }
            controller.state = .creatingVoice
            do {
                _ = try await controller.synthesizer.createReference(
                    for: voice,
                    designModelDirectory: controller.designModelStore.modelDirectory
                )
                controller.referencesRevision += 1
            } catch {
                failure = error
            }
            controller.state = .unloaded
            await controller.performPrepare()
        }
        if let failure { throw failure }
    }

    /// The synthesizer, only when the model is loaded.
    var readySynthesizer: QwenSynthesizer? { state == .ready ? synthesizer : nil }

    /// Whether the loaded model speaks with stress marks.
    var isMarkingStress: Bool { state == .ready && loadedStressDirectory != nil && stressError == nil }

    /// The stress pack the model should be loaded with now.
    private var wantedStressDirectory: URL? {
        marksStressWhenInstalled && stressStore.isInstalled ? stressStore.modelDirectory : nil
    }

    /// Reloads the model if it is loaded with another stress setting than wanted (pack installed, deleted or
    /// the setting changed). Does nothing when the model isn't loaded.
    func applyStressSetting() async {
        await serialized { controller in
            guard controller.state == .ready, controller.loadedStressDirectory != controller.wantedStressDirectory else { return }
            controller.state = .unloaded
            await controller.performPrepare()
        }
    }

    /// Unloads the model if it uses the stress pack, deletes the pack and loads the model again without it.
    func deleteStressPack() async {
        await serialized { controller in
            let wasReady = controller.state == .ready
            if controller.loadedStressDirectory != nil {
                controller.state = .unloaded
                await controller.synthesizer.unload()
                controller.loadedStressDirectory = nil
            }
            controller.stressStore.delete()
            controller.stressError = nil
            if wasReady { await controller.performPrepare() }
        }
    }

    /// Loads Base if needed. Returns when ready or failed. Voices need no loading: each phrase carries its
    /// voice, and the reference is prepared on first use.
    func prepare() async {
        await serialized { controller in
            await controller.performPrepare()
        }
    }

    func unload() async {
        await serialized { controller in
            controller.state = .unloaded
            controller.loadedStressDirectory = nil
            await controller.synthesizer.unload()
        }
    }

    private func performPrepare() async {
        guard modelStore.isInstalled else {
            state = .unloaded
            return
        }
        let stress = wantedStressDirectory
        if state == .ready, loadedStressDirectory == stress { return }
        state = .loading
        do {
            let result = try await synthesizer.load(modelDirectory: modelStore.modelDirectory, stressDirectory: stress)
            sampleRate = result.sampleRate
            stressError = result.stressError
            loadedStressDirectory = stress
            state = .ready
        } catch {
            loadedStressDirectory = nil
            state = .failed(error.localizedDescription)
        }
    }

    private func serialized(_ body: @escaping @MainActor (QwenVoiceController) async -> Void) async {
        let previous = lastOperation
        let task = Task { @MainActor [self] in
            await previous?.value
            await body(self)
        }
        lastOperation = task
        await task.value
    }
}
