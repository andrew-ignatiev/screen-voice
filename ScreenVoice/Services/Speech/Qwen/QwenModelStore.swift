import CryptoKit
import Foundation
import Observation

/// A pinned Hugging Face snapshot: exact revision, file sizes and SHA-256 digests.
struct QwenModelSpec: Sendable {
    struct File: Sendable {
        let path: String
        let size: Int64
        let sha256: String
        /// Where the file comes from when it isn't the spec's own repository; `path` is the same there.
        var source: Source?
    }

    struct Source: Sendable {
        let repository: String
        let revision: String
    }

    let repository: String
    let revision: String
    let directoryName: String
    let files: [File]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    func url(for file: File) -> URL {
        let repository = file.source?.repository ?? repository
        let revision = file.source?.revision ?? revision
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
    }

    /// Qwen3-TTS 1.7B Base, 8-bit: speaks every phrase by cloning a voice's reference recording. With top_k 50
    /// it read all test numbers right and kept the reference pitch (~0.19 s to first audio, ~4.4 GB peak).
    static let base8bit = QwenModelSpec(
        repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
        revision: "e7dd0585652209fa0d7783659aad4e8a324de11c",
        directoryName: "Qwen3-TTS-12Hz-1.7B-Base-8bit",
        files: [
            File(path: "config.json", size: 5_522, sha256: "b14fba6bfd391968876248b843b095696b0188187a3d774a3bddc32544d15627"),
            File(path: "generation_config.json", size: 245, sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
            File(path: "merges.txt", size: 1_671_839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
            File(path: "model.safetensors", size: 2_417_320_525, sha256: "b965c581ccf6aa852a4124feeb7a8a111542ee7b213139368b4cc7ba7fd4728b"),
            File(path: "model.safetensors.index.json", size: 78_070, sha256: "9592a7c0ac3261a6211978416ef1796d3841225ac0ff0f9d6bfb5d1a6b49e5e9"),
            File(path: "preprocessor_config.json", size: 127, sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
            File(path: "tokenizer_config.json", size: 7_344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
            File(path: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            File(path: "speech_tokenizer/config.json", size: 2_336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
            File(path: "speech_tokenizer/configuration.json", size: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
            File(path: "speech_tokenizer/model.safetensors", size: 682_293_092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
            File(path: "speech_tokenizer/preprocessor_config.json", size: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        ]
    )

    /// Qwen3-TTS 1.7B VoiceDesign, 8-bit: turns a text description into a reference recording. Optional: loaded
    /// only while a new voice is created, then unloaded.
    static let voiceDesign8bit = QwenModelSpec(
        repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
        revision: "f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee",
        directoryName: "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
        files: [
            File(path: "config.json", size: 5_437, sha256: "b91c47798e77e259e6b86987e48d7a5eca8e703205e00afb63fe08ec5251f983"),
            File(path: "generation_config.json", size: 245, sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
            File(path: "merges.txt", size: 1_671_839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
            File(path: "model.safetensors", size: 2_393_308_931, sha256: "1a84179d87c972353ccdd9b48f3c4422509b3d1b11030d32358312fb0f3800d7"),
            File(path: "model.safetensors.index.json", size: 71_786, sha256: "2551ed02dc288b90cd6b7ec98652433f08ef2ae98fb3eda5248a4b9e5b47d08b"),
            File(path: "preprocessor_config.json", size: 127, sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
            File(path: "tokenizer_config.json", size: 7_344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
            File(path: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            File(path: "speech_tokenizer/config.json", size: 2_336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
            File(path: "speech_tokenizer/configuration.json", size: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
            File(path: "speech_tokenizer/model.safetensors", size: 682_293_092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
            File(path: "speech_tokenizer/preprocessor_config.json", size: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        ]
    )
}

extension QwenModelSpec {
    private static let lora = Source(
        repository: "siriusfreak/qwen3-tts-12hz-1.7b-ru-stress-cf",
        revision: "c16b3af3db3095120efc1ebb73f6522442bcb3b1"
    )

    /// Optional Russian stress pack (~550 MB): RUAccent's models and dictionaries, which mark the stressed
    /// vowel of each word (`RussianStressMarker`), and siriusfreak's LoRA, which makes Base follow the marks
    /// (`StressLoRA`). Without the LoRA the marks garble words; without marks the LoRA changes nothing.
    static let russianStress = QwenModelSpec(
        repository: "ruaccent/accentuator",
        revision: "b78ae5ea1e62beaf138bed1865cd8c3b0b5ca855",
        directoryName: "RussianStress-ruaccent-b78ae5e-lora-c16b3af",
        files: [
            File(path: "nn/nn_accent/config.json", size: 841, sha256: "e377f159a8fc8673e211f100d4a237d5fe3dceb3b6789a5a738bf50bda23be49"),
            File(path: "nn/nn_accent/model.onnx", size: 803_402, sha256: "4e393144e45626f6f1062a0784ef06f921b97321a8e7b87ac2a09a892286500a"),
            File(path: "nn/nn_accent/vocab.txt", size: 140, sha256: "242882b2f27800e49a6babf46867dabf6dc9b6535b600776a68815fe4d4f4382"),
            File(path: "nn/nn_stress_usage_predictor/config.json", size: 822, sha256: "aa0638edf56254f123e593e96f034c2b5e68303ac207b29f64f0878dc4c22631"),
            File(path: "nn/nn_stress_usage_predictor/model.onnx", size: 116_473_561, sha256: "3d547500637b4ddfec8880ed6d1405fd50ee9d3f0131ef8a2a69dcf961dbefeb"),
            File(path: "nn/nn_stress_usage_predictor/vocab.txt", size: 1_080_667, sha256: "f056a69b097422652053bf87565c35543e5d81540ca4b7dddd28de4157a969e0"),
            File(path: "nn/nn_yo_homograph_resolver/config.json", size: 625, sha256: "adf7fd2c67be1498071f447ec4a23dbe84904c49f95d1d3e6c7d9df269b9a2e9"),
            File(path: "nn/nn_yo_homograph_resolver/model.onnx", size: 14_332_169, sha256: "42cc85bf0c4b319dfe3d89fa17b162a92fd5e1c651a657cb3d5f44978d4e70ac"),
            File(path: "nn/nn_yo_homograph_resolver/vocab.txt", size: 48_576, sha256: "9276b81ff34cd9560563a476de6735abf5ed9a3871131644992230dc4e630056"),
            File(path: "nn/nn_omograph/turbo3.1/added_tokens.json", size: 279_418, sha256: "071c01df9ba59b64b9d0d9af0eaac5412a5fc558d540a214ada4ee7531d38096"),
            File(path: "nn/nn_omograph/turbo3.1/merges.txt", size: 1_213_606, sha256: "120c75258d87ba748b2025f517819fd0e0386e8d31cc6b29a21f900d395dd825"),
            File(path: "nn/nn_omograph/turbo3.1/model.onnx", size: 359_306_923, sha256: "2cb6a174c4cdb45bd3132b4f7c8a3779fc4b6869863180ed7d0e421bcd453dbd"),
            File(path: "nn/nn_omograph/turbo3.1/vocab.json", size: 1_555_282, sha256: "ba028ba89c029a473ac369716b4d52bb252a38004fc5dd085d18f4ada4a760b3"),
            File(path: "dictionary/accents.json.gz", size: 20_954_156, sha256: "aa460ebba90de00fbbf3d41d121961f605b98667e45efb7920f127473b15515e"),
            File(path: "dictionary/omographs.json.gz", size: 219_047, sha256: "04a9e81c68d65f65ba493fe0110f99e79087548c2beeec3032e2b66e28706f36"),
            File(path: "dictionary/yo_homographs.json.gz", size: 5_747, sha256: "c4ee777bbbab87f9eac838f370ad92974e079d02b21903e480c54b5f0c8c60d1"),
            File(path: "dictionary/yo_words.json.gz", size: 548_914, sha256: "a19fa89a964a0691d9fe4ee384783e3934904891843d8f59a1c480d67947a82a"),
            File(path: "lora/adapter.json", size: 1_869, sha256: "d39870f47f9d3c683ad7588c808f73f991310f8a28020bdf6d9b71c64825f2bb", source: lora),
            File(path: "lora/adapter.safetensors", size: 34_908_456, sha256: "88a94c0fbe85800d309f94bb9c28d698bf9c86d9494617b6cf4dd996cc13648b", source: lora),
        ]
    )

    /// The LoRA adapter's folder inside an installed stress pack.
    static func stressLoRADirectory(in pack: URL) -> URL {
        pack.appending(path: "lora", directoryHint: .isDirectory)
    }
}

enum QwenModelInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(fraction: Double)
    case verifying
    case installed
    case failed(String)
}

enum QwenModelStoreError: LocalizedError {
    case badResponse(String, Int)
    case sizeMismatch(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let file, let code): String(localized: "The server returned error \(code) for \(file).")
        case .sizeMismatch(let file): String(localized: "\(file) was only partly downloaded.")
        case .checksumMismatch(let file): String(localized: "The checksum of \(file) doesn’t match.")
        }
    }
}

/// Downloads, verifies and locates one Qwen3-TTS model in Application Support.
/// Files go to a `.partial` directory first and are moved into place only after every checksum matches.
@MainActor
@Observable
final class QwenModelStore {
    let spec: QwenModelSpec
    private(set) var state: QwenModelInstallState = .notInstalled

    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private let root: URL

    init(spec: QwenModelSpec = .base8bit, root: URL = QwenModelStore.defaultRoot) {
        self.spec = spec
        self.root = root
        if root == Self.defaultRoot {
            Self.removeObsoleteFiles(root: root)
        }
        state = Self.isComplete(spec: spec, at: modelDirectory) ? .installed : .notInstalled
    }

    nonisolated static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "ScreenVoice/Models", directoryHint: .isDirectory)
    }

    /// Earlier builds used Qwen3-TTS 0.6B Base plus cached reference voices (~2 GB). Nothing reads them any more.
    nonisolated static let obsoleteModelDirectories = ["Qwen3-TTS-12Hz-0.6B-Base-8bit", "Qwen3-TTS-12Hz-0.6B-Base-8bit.partial"]

    nonisolated static func removeObsoleteFiles(root: URL) {
        let fm = FileManager.default
        for name in obsoleteModelDirectories {
            try? fm.removeItem(at: root.appending(path: name, directoryHint: .isDirectory))
        }
        try? fm.removeItem(at: root.deletingLastPathComponent().appending(path: "Voices", directoryHint: .isDirectory))
    }

    var modelDirectory: URL { root.appending(path: spec.directoryName, directoryHint: .isDirectory) }
    var isInstalled: Bool { state == .installed }

    func download() {
        guard downloadTask == nil, state != .installed else { return }
        state = .downloading(fraction: 0)
        let spec = spec, root = root, final = modelDirectory
        downloadTask = Task { [weak self] in
            do {
                try await Self.install(spec: spec, root: root, final: final) { fraction in
                    Task { @MainActor in
                        if case .downloading = self?.state { self?.state = .downloading(fraction: fraction) }
                    }
                } verifying: {
                    Task { @MainActor in self?.state = .verifying }
                }
                self?.finishDownload(.installed)
            } catch is CancellationError {
                self?.finishDownload(.notInstalled)
            } catch {
                self?.finishDownload(.failed(error.localizedDescription))
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func delete() {
        cancelDownload()
        try? FileManager.default.removeItem(at: modelDirectory)
        state = .notInstalled
    }

    private func finishDownload(_ newState: QwenModelInstallState) {
        downloadTask = nil
        state = newState
    }

    // MARK: Installation (off the main actor)

    /// Cheap check used at launch: every file exists with the expected size.
    nonisolated static func isComplete(spec: QwenModelSpec, at directory: URL) -> Bool {
        spec.files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appending(path: file.path).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    nonisolated private static func install(
        spec: QwenModelSpec,
        root: URL,
        final: URL,
        progress: @escaping @Sendable (Double) -> Void,
        verifying: @escaping @Sendable () -> Void
    ) async throws {
        let fm = FileManager.default
        let partial = root.appending(path: spec.directoryName + ".partial", directoryHint: .isDirectory)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)

        let total = Double(spec.totalBytes)
        var completed: Int64 = 0
        for file in spec.files {
            try Task.checkCancellation()
            let destination = partial.appending(path: file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Resume across launches at file granularity: keep files that already have the right size.
            let existingSize = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            if existingSize != file.size {
                let base = completed
                try await downloadFile(spec.url(for: file), name: file.path, to: destination) { written in
                    progress(Double(base + written) / total)
                }
            }
            completed += file.size
            progress(Double(completed) / total)
        }

        verifying()
        for file in spec.files {
            try Task.checkCancellation()
            let url = partial.appending(path: file.path)
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            guard size == file.size else {
                try? fm.removeItem(at: url)
                throw QwenModelStoreError.sizeMismatch(file.path)
            }
            guard try sha256(of: url) == file.sha256 else {
                try? fm.removeItem(at: url)
                throw QwenModelStoreError.checksumMismatch(file.path)
            }
        }

        if fm.fileExists(atPath: final.path) {
            try fm.removeItem(at: final)
        }
        try fm.moveItem(at: partial, to: final)
    }

    nonisolated private static func downloadFile(
        _ url: URL,
        name: String,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let box = DownloadTaskBox()
        defer { box.invalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                    // The temporary file is deleted when this handler returns, so move it here.
                    do {
                        if let error { throw error }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard let temporary, (200..<300).contains(status) else {
                            throw QwenModelStoreError.badResponse(name, status)
                        }
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        continuation.resume()
                    } catch let error as URLError where error.code == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.set(task, observation: task.progress.observe(\.completedUnitCount) { taskProgress, _ in
                    progress(taskProgress.completedUnitCount)
                })
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Holds the in-flight download task so the cancellation handler can reach it.
private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func set(_ task: URLSessionDownloadTask, observation: NSKeyValueObservation) {
        lock.lock()
        self.task = task
        self.observation = observation
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func invalidate() {
        lock.lock()
        observation?.invalidate()
        observation = nil
        task = nil
        lock.unlock()
    }
}
