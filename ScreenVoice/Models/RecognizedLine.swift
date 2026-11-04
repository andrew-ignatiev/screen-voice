import CoreGraphics
import Foundation

/// One line of text returned by Vision OCR.
struct RecognizedLine: Equatable, Sendable {
    var text: String
    var confidence: Float
    /// Normalized bounding box in Vision coordinates (0...1, origin at the bottom-left).
    var boundingBox: CGRect
}
