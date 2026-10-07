import Foundation
import LeanTypeCore

/// Compiles a `word count` frequency list into LeanType's memory-mappable `lexicon.bin`.
///
///     LexiconBuilder <frequency-list> <output.bin> [--case-reference <words>] [--blocklist <words>] [--limit <n>]
///
/// - The frequency list is one `word count` pair per line, lowercase (e.g. FrequencyWords).
/// - `--case-reference` is a plain word list with natural capitalization (such as
///   /usr/share/dict/words); words that only ever appear capitalized there ("London",
///   "Monday") get that capitalization.
/// - `--blocklist` lists words that must never be suggested; they're left out entirely.
struct Builder {
    static let minimumLength = 2
    static let maximumLength = 24
    static let singleLetterWords: Set<String> = ["a", "i"]

    var counts: [String: UInt64] = [:]

    mutating func run(arguments: [String]) throws {
        let positional = arguments.filter { !$0.hasPrefix("--") && !isOptionValue($0, in: arguments) }
        guard positional.count == 2 else {
            throw BuildError.usage
        }
        let input = URL(fileURLWithPath: positional[0])
        let output = URL(fileURLWithPath: positional[1])

        try load(input)
        rebuildContractions()
        removeFragments()
        try removeBlocked(option("--blocklist", in: arguments))

        let capitalized = try capitalizationMap(option("--case-reference", in: arguments))
        var entries = counts.compactMap { word, count -> LexiconFormat.Entry? in
            guard isAcceptable(word) else { return nil }
            return LexiconFormat.Entry(display: display(for: word, capitalized: capitalized), count: count)
        }
        if let limit = option("--limit", in: arguments).flatMap(Int.init), limit > 0, entries.count > limit {
            entries.sort { $0.count > $1.count }
            entries.removeLast(entries.count - limit)
        }

        let data = LexiconFormat.write(entries)
        try data.write(to: output)
        print("Wrote \(entries.count) words (\(data.count / 1024) KB) to \(output.path)")
    }

    // MARK: - Steps

    private mutating func load(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let count = UInt64(parts[1]) else { continue }
            counts[String(parts[0]), default: 0] += count
        }
    }

    /// Subtitle tokenizers split "don't" into "don" + "'t". Rebuild the contractions with
    /// counts estimated from the fragments, then shrink the bases they inflated.
    private mutating func rebuildContractions() {
        var notTotal: UInt64 = 0
        for (fragment, contraction) in Contractions.negatives {
            let count = counts[fragment] ?? 0
            counts[contraction, default: 0] += count
            notTotal += count
        }

        let remainder = (counts["'t"] ?? 0) > notTotal ? (counts["'t"] ?? 0) - notTotal : 0
        for (base, contraction, share) in Contractions.ambiguousNegatives {
            let estimate = UInt64(Double(remainder) * share)
            counts[contraction, default: 0] += estimate
            if let baseCount = counts[base] {
                counts[base] = max(baseCount > estimate ? baseCount - estimate : 0, baseCount / 10)
            }
        }

        for (suffix, shares) in Contractions.suffixShares {
            let total = Double(counts[suffix] ?? 0)
            for (contraction, share) in shares {
                counts[contraction, default: 0] += UInt64(total * share)
            }
        }
        for (fragment, word) in Contractions.wholeWords {
            counts[word, default: 0] += counts[fragment] ?? 0
        }
    }

    private mutating func removeFragments() {
        for fragment in Contractions.fragments {
            counts[fragment] = nil
        }
        counts = counts.filter { !$0.key.hasPrefix("'") }
    }

    private mutating func removeBlocked(_ path: String?) throws {
        guard let path else { return }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let word = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard !word.isEmpty else { continue }
            for form in [word, word + "s", word + "es", word + "ed", word + "ing"] {
                counts[form] = nil
            }
        }
    }

    /// Lowercase word to its capitalized form, for words never written lowercase.
    private func capitalizationMap(_ path: String?) throws -> [String: String] {
        guard let path else { return [:] }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var lowercase: Set<String> = []
        var capitalized: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let word = String(line)
            let lower = word.lowercased()
            if word == lower {
                lowercase.insert(lower)
            } else if word.first?.isUppercase == true, word.dropFirst() == lower.dropFirst() {
                capitalized[lower] = word
            }
        }
        return capitalized.filter { !lowercase.contains($0.key) }
    }

    // MARK: - Rules

    private func isAcceptable(_ word: String) -> Bool {
        guard word.count <= Self.maximumLength else { return false }
        if word.count < Self.minimumLength, !Self.singleLetterWords.contains(word) { return false }
        let allowed = word.allSatisfy { ("a"..."z").contains($0) || $0 == "'" }
        guard allowed, word.contains(where: \.isLetter) else { return false }
        // Apostrophes only inside known contractions.
        return !word.contains("'") || Contractions.all.contains(word)
    }

    private func display(for word: String, capitalized: [String: String]) -> String {
        if word == "i" { return "I" }
        if let contraction = Contractions.displayForms[word] { return contraction }
        if word.count >= 3, let form = capitalized[word] { return form }
        return word
    }

    // MARK: - Arguments

    private func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func isOptionValue(_ argument: String, in arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: argument), index > 0 else { return false }
        return arguments[index - 1].hasPrefix("--")
    }
}

enum BuildError: Error, CustomStringConvertible {
    case usage

    var description: String {
        "usage: LexiconBuilder <frequency-list> <output.bin> [--case-reference <words>] [--blocklist <words>] [--limit <n>]"
    }
}

do {
    var builder = Builder()
    try builder.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
