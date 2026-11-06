import AVFoundation
import Foundation
import Speech

/// Transcribes an imported voice sample on the device with Apple's ru-RU dictation model, so the user only
/// checks the text the clone needs instead of typing it. The model is downloaded by the system on first use.
enum VoiceTranscriber {
    enum Failure: LocalizedError {
        case notAuthorized
        case unsupported

        var errorDescription: String? {
            switch self {
            case .notAuthorized: String(localized: "Speech recognition is off for ScreenVoice. Type the text of the sample.")
            case .unsupported: String(localized: "Russian speech recognition isn’t available on this Mac. Type the text of the sample.")
            }
        }
    }

    static func transcribe(_ file: URL) async throws -> String {
        guard await authorize() else { throw Failure.notAuthorized }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ru_RU")) else {
            throw Failure.unsupported
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audio = try AVAudioFile(forReading: file)
        async let text: String = transcriber.results.reduce(into: "") { $0 += String($1.text.characters) }
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }
}
