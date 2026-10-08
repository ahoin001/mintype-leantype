import Foundation

/// The hold-and-slide row for a letter key: built-in accents, unless the user has replaced them.
public enum KeyShortcuts {
    /// Matches the callout, which draws at most this many choices.
    public static let maxCount = 10
    /// Long enough for an email, short enough to stay one line.
    public static let maxLength = 64

    public static let letters: [String] = Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
    /// The period key's hold row always starts with this, nearest the finger.
    public static let period = "."
    /// Marks beside the period until the user replaces them.
    public static let defaultPeriodShortcuts = ["?", "!", "$"]

    public static func isLetter(_ key: String) -> Bool {
        letters.contains(key)
    }

    /// Letters, and the period key. Other symbols keep their built-in row.
    public static func isEditable(_ key: String) -> Bool {
        isLetter(key) || key == period
    }

    /// The row a hold should show. Letter overrides replace the accents. A period override
    /// replaces the marks beside it, and the period itself stays first.
    public static func row(for key: String, builtIn: [String], overrides: [String: [String]]) -> [String] {
        if key == period {
            let shortcuts = overrides[key].map(normalized) ?? builtIn
            return pinnedPeriod(shortcuts)
        }
        guard isLetter(key), let override = overrides[key] else { return builtIn }
        return normalized(override)
    }

    /// `shortcuts` sit beside the period. The period is always index 0, nearest the key.
    public static func pinnedPeriod(_ shortcuts: [String]) -> [String] {
        var row = [period]
        for item in normalized(shortcuts) where item != period {
            row.append(item)
            if row.count == maxCount { break }
        }
        return row
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
