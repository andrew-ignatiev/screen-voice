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
    @ObservationIgnored private var lastOperation: Task<Void, Never>?

    init(modelStore: QwenModelStore = QwenModelStore()) {
        self.modelStore = modelStore
    }

    /// The synthesizer, only when the model is loaded.
    var readySynthesizer: QwenSynthesizer? { state == .ready ? synthesizer : nil }

    /// Loads the model if needed. Returns when ready or failed. Voices need no loading: each phrase
    /// carries its own voice description and seed.
    func prepare() async {
        await serialized { controller in
            await controller.performPrepare()
        }
    }

    func unload() async {
        await serialized { controller in
            controller.state = .unloaded
            await controller.synthesizer.unload()
        }
    }

    private func performPrepare() async {
        guard modelStore.isInstalled else {
            state = .unloaded
            return
        }
        if state == .ready { return }
        state = .loading
        do {
            sampleRate = try await synthesizer.load(modelDirectory: modelStore.modelDirectory)
            state = .ready
        } catch {
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
