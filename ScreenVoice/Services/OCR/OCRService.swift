import CoreVideo
import Foundation
import Vision

/// Runs Vision text recognition on a dedicated serial queue, off the main actor and off the
/// cooperative thread pool (recognition is synchronous and can take ~100 ms per frame).
final class OCRService: Sendable {
    struct Options: Equatable, Sendable {
        var languages: [String]
        var accuracy: OCRAccuracy
        var usesLanguageCorrection = true
    }

    private let queue = DispatchQueue(label: "ScreenVoice.OCR", qos: .userInitiated)

    func recognize(_ frame: CapturedFrame, options: Options) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let lines = try Self.performRecognition(on: frame.pixelBuffer, options: options)
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func performRecognition(on pixelBuffer: CVPixelBuffer, options: Options) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.accuracy == .accurate ? .accurate : .fast
        request.recognitionLanguages = options.languages
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.automaticallyDetectsLanguage = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }
    }
}
