import Foundation

/// The hold-and-slide row for a letter key: built-in accents, unless the user has replaced them.
public enum KeyShortcuts {
    /// Matches the callout, which draws at most this many choices.
    public static let maxCount = 10
    /// Long enough for an email, short enough to stay one line.
    public static let maxLength = 64

    public static let letters: [String] = Array("abcdefghijklmnopqrstuvwxyz").map(String.init)

    public static func isLetter(_ key: String) -> Bool {
        letters.contains(key)
    }

    /// The row a hold should show. Overrides apply only to `a`–`z`. Anything else keeps `builtIn`.
    public static func row(for key: String, builtIn: [String], overrides: [String: [String]]) -> [String] {
        guard isLetter(key), let override = overrides[key] else { return builtIn }
        return normalized(override)
    }

    /// Trims blanks, clips length, drops duplicates, and stops at `maxCount`.
    public static func normalized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(raw.count, maxCount))
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clipped = String(trimmed.prefix(maxLength))
            guard seen.insert(clipped).inserted else { continue }
            result.append(clipped)
            if result.count == maxCount { break }
        }
        return result
    }
}
