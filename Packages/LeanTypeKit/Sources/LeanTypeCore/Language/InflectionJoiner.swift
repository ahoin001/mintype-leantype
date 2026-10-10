import Foundation

/// Joins a short suffix onto the word just swiped, and only when that spelling is already known.
///
/// `happy` plus `er` stays two words. The joiner never rewrites a stem, and it never looks at the clock.
enum InflectionJoiner {
    /// Longest useful forms first, so a single free chip prefers `ing` over `s`.
    static let suffixes = ["ing", "ed", "es", "ly", "er", "est", "s"]

    /// `previous + draft` when `draft` is exactly one suffix and the concatenation is known.
    static func joined(previous: String, draft: String, isKnown: (String) -> Bool) -> String? {
        let suffix = draft.lowercased()
        guard !previous.isEmpty, suffixes.contains(suffix) else { return nil }
        let combined = previous.lowercased() + suffix
        guard isKnown(combined) else { return nil }
        return combined
    }

    /// Keeps the first letter's case from the word already on the page.
    static func matchingCase(_ word: String, like source: String) -> String {
        guard let first = source.first, first.isUppercase, let head = word.first else { return word }
        return String(head).uppercased() + word.dropFirst()
    }
}
