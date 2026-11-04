import CryptoKit
import Foundation
import Observation

/// A pinned Hugging Face snapshot: exact revision, file sizes and SHA-256 digests.
struct QwenModelSpec: Sendable {
    struct File: Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    let repository: String
    let revision: String
    let directoryName: String
    let files: [File]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
    }

    /// Qwen3-TTS 1.7B VoiceDesign, 8-bit: builds a voice from a text description. Checked for Russian
    /// (correct transcripts with Apple's recognizer, ~0.15 s to first audio, ~3.9 GB peak while speaking).
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

/// Downloads, verifies and locates the Qwen3-TTS model in Application Support.
/// Files go to a `.partial` directory first and are moved into place only after every checksum matches.
@MainActor
@Observable
final class QwenModelStore {
    let spec: QwenModelSpec
    private(set) var state: QwenModelInstallState = .notInstalled

    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private let root: URL

    init(spec: QwenModelSpec = .voiceDesign8bit, root: URL = QwenModelStore.defaultRoot) {
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
