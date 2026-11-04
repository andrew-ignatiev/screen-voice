import Foundation
import Observation

enum QwenVoiceState: Equatable, Sendable {
    case unloaded
    case loading
    case ready
    case failed(String)
}

/// Main-actor face of the Qwen engine: model installation plus load/unload of the synthesizer.
/// Loads and unloads run strictly in call order, so a quick Stop → Start cannot interleave them.
@MainActor
@Observable
final class QwenVoiceController {
    let modelStore: QwenModelStore
    private(set) var state: QwenVoiceState = .unloaded
    private(set) var sampleRate: Double = 24_000

    @ObservationIgnored let synthesizer = QwenSynthesizer()
    @ObservationIgnored private var loadedSeed: UInt64?
    @ObservationIgnored private var lastOperation: Task<Void, Never>?
    @ObservationIgnored private let voiceDirectory: URL

    init(
        modelStore: QwenModelStore = QwenModelStore(),
        voiceDirectory: URL = URL.applicationSupportDirectory.appending(path: "ScreenVoice/Voices", directoryHint: .isDirectory)
    ) {
        self.modelStore = modelStore
        self.voiceDirectory = voiceDirectory
    }

    /// The synthesizer, only when the model and voice are loaded.
    var readySynthesizer: QwenSynthesizer? { state == .ready ? synthesizer : nil }

    /// Loads the model and the voice for `voiceSeed` if needed. Returns when ready or failed.
    func prepare(voiceSeed: UInt64) async {
        await serialized { controller in
            await controller.performPrepare(voiceSeed: voiceSeed)
        }
    }

    func unload() async {
        await serialized { controller in
            controller.loadedSeed = nil
            controller.state = .unloaded
            await controller.synthesizer.unload()
        }
    }

    private func performPrepare(voiceSeed: UInt64) async {
        guard modelStore.isInstalled else {
            state = .unloaded
            return
        }
        if state == .ready, loadedSeed == voiceSeed { return }
        state = .loading
        do {
            sampleRate = try await synthesizer.load(
                modelDirectory: modelStore.modelDirectory,
                voiceSeed: voiceSeed,
                voiceDirectory: voiceDirectory
            )
            loadedSeed = voiceSeed
            state = .ready
        } catch {
            loadedSeed = nil
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
