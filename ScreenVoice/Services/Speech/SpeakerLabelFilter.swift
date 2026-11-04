import Foundation

/// Removes speaker labels such as "Датч:" or "- Mr. Smith:" from text before it is spoken.
///
/// A label is one to four words followed by a colon and a space (or the end of the text). It must sit
/// at the start of the text, after a dialogue dash, or right after the end of a sentence. Every word must
/// start with a capital letter or be a number. That keeps ordinary sentences such as "Я скажу: да"
/// intact, and times such as "10:30" have no space after the colon, so they are never matched.
enum SpeakerLabelFilter {
    private static let word = #"(?:\p{Lu}[\p{L}\p{M}'’.\-]*|\p{N}+)"#

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.!?…]\s))(\s*(?:[-–—]\s*)?)"# + word + #"(?:\s+"# + word + #"){0,3}\s*[:：](?:\s+|$)"#
    )

    static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        return TextChangeDetector.normalizeDisplayText(stripped)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–— "))
    }
}
