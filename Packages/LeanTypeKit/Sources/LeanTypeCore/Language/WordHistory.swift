import Foundation

/// One reading kept with a committed word. The path that produced it is not stored.
struct HistoryReading: Hashable, Sendable {
    var word: String
    var score: Double
}

/// A word the keyboard just committed, and enough to offer its other readings later.
struct HistoryEntry: Hashable, Sendable {
    var text: String
    var readings: [HistoryReading]
    var aimed: String
    var unsure: Bool
    var trailing: String
    var startsSentence: Bool

    var suffix: String { text + trailing }
}

/// The last few committed words. Editing is allowed only while the field still ends with them.
struct WordHistory: Equatable, Sendable {
    static let capacity = 12

    private(set) var entries: [HistoryEntry] = []

    var suffix: String { entries.map(\.suffix).joined() }

    var isEmpty: Bool { entries.isEmpty }

    mutating func clear() {
        entries.removeAll()
    }

    /// Drops the ring when the field no longer ends with what was stored, or when there is no context.
    mutating func dropIfStale(contextBefore: String?) {
        guard matches(contextBefore) else {
            entries.removeAll()
            return
        }
    }

    func matches(_ contextBefore: String?) -> Bool {
        guard let contextBefore, !entries.isEmpty else { return false }
        return contextBefore.hasSuffix(suffix)
    }

    /// Appends `entry`, or replaces the last one when this commit rewrote it.
    /// A context that no longer continues the ring starts a new ring of one word, or drops it.
    mutating func record(_ entry: HistoryEntry, contextBefore: String?) {
        var entry = entry
        entry.readings = Array(entry.readings.prefix(4))
        guard let contextBefore else {
            entries.removeAll()
            return
        }
        let addition = entry.suffix
        let existing = suffix
        if contextBefore.hasSuffix(existing + addition) || (existing.isEmpty && contextBefore.hasSuffix(addition)) {
            entry.startsSentence = Self.startsSentence(entry, in: contextBefore, precededBy: existing)
            entries.append(entry)
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
            }
            return
        }
        if !entries.isEmpty {
            let withoutLast = entries.dropLast().map(\.suffix).joined()
            if contextBefore.hasSuffix(withoutLast + addition) {
                entry.startsSentence = Self.startsSentence(entry, in: contextBefore, precededBy: withoutLast)
                entries[entries.count - 1] = entry
                return
            }
        }
        if contextBefore.hasSuffix(addition) {
            entry.startsSentence = Self.startsSentence(entry, in: contextBefore, precededBy: "")
            entries = [entry]
            return
        }
        entries.removeAll()
    }

    func entry(_ index: Int) -> HistoryEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    /// Rewrites one stored word. The caller has already made the field match.
    mutating func rewrite(at index: Int, text: String) {
        guard entries.indices.contains(index) else { return }
        entries[index].text = text
        entries[index].unsure = false
    }

    /// Joins `index` with the next word and drops the next entry.
    mutating func merge(at index: Int, text: String) {
        guard entries.indices.contains(index + 1) else { return }
        entries[index].text = text
        entries[index].trailing = entries[index + 1].trailing
        entries[index].unsure = false
        entries.remove(at: index + 1)
    }

    /// The text from `index` through the caret, used to prove the field has not moved.
    func suffix(from index: Int) -> String? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index...].map(\.suffix).joined()
    }

    private static func startsSentence(_ entry: HistoryEntry, in context: String, precededBy: String) -> Bool {
        let ending = precededBy + entry.suffix
        guard context.hasSuffix(ending) else { return false }
        let head = context.dropLast(ending.count)
        guard let last = head.last else { return true }
        if last.isNewline { return true }
        return TextBoundary.endsSentence(last)
    }
}

/// Alternatives frozen when a chip opens. They do not reshuffle until the drill closes.
struct HistoryDrill: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case entry(Int)
        case document(Int)
    }

    var source: Source
    var choices: [String]
    var context: String?
}

public struct HistoryMenuRow: Hashable, Sendable {
    public var title: String
    public var action: Candidate.StripAction

    public init(title: String, action: Candidate.StripAction) {
        self.title = title
        self.action = action
    }
}

/// One in-place edit that the undo chip can put back, while the field still ends with it.
struct HistoryUndo: Equatable, Sendable {
    var match: String
    var previous: String
}

/// How the suggestion row moves. Travel becomes a fade when Reduce Motion is on.
public enum StripMotion {
    public static func ignoresHistoryTap(isTentative: Bool) -> Bool { isTentative }

    public static func fadesInsteadOfTraveling(reduceMotion: Bool) -> Bool { reduceMotion }
}

/// Alternatives for one stored word. Order is computed once, when a drill opens.
enum HistoryRanking {
    static func alternatives(
        for entry: HistoryEntry,
        previous: String?,
        next: String?,
        known: (String) -> Bool,
        pair: (String, String) -> Double
    ) -> [String] {
        var scored: [(word: String, score: Double)] = entry.readings.map { ($0.word, $0.score) }
        if !scored.contains(where: { $0.word.compare(entry.text, options: .caseInsensitive) == .orderedSame }) {
            scored.append((entry.text, scored.first?.score ?? 0))
        }
        let base = scored.map(\.score).max() ?? 0
        for extra in extras(for: entry.text, known: known) where !scored.contains(where: {
            $0.word.compare(extra, options: .caseInsensitive) == .orderedSame
        }) {
            scored.append((extra, base - 0.25))
        }
        for index in scored.indices {
            var bonus = 0.0
            if let previous { bonus += pair(previous, scored[index].word) }
            if let next { bonus += pair(scored[index].word, next) }
            scored[index].score += bonus
        }
        scored.sort { $0.score > $1.score }
        var seen = Set<String>()
        var words: [String] = []
        for item in scored where seen.insert(item.word.lowercased()).inserted {
            words.append(item.word)
        }
        let aimed = entry.aimed
        if !aimed.isEmpty, seen.insert(aimed.lowercased()).inserted {
            words.append(aimed)
        }
        return words
    }

    /// Real cut points, including a one-letter tail such as "the" / "n".
    static func segmentations(of word: String, known: (String) -> Bool) -> [String] {
        let letters = Array(word)
        guard letters.count >= 2 else { return [] }
        var cuts: [String] = []
        for index in 1..<letters.count {
            let left = String(letters[..<index])
            let right = String(letters[index...])
            guard known(left) else { continue }
            guard known(right) || right.count == 1 else { continue }
            let shown = left + " " + right
            if !cuts.contains(shown) { cuts.append(shown) }
            if cuts.count == 3 { break }
        }
        return cuts
    }

    static func extras(for word: String, known: (String) -> Bool) -> [String] {
        var extras: [String] = []
        if let other = contraction(of: word) { extras.append(other) }
        extras.append(contentsOf: segmentations(of: word, known: known))
        if word.contains(" "), let joined = joined(word), known(joined) || contraction(of: joined) != nil {
            extras.append(joined)
        }
        return extras
    }

    /// The other real form, when both exist. "its" stays; "it's" is offered beside it.
    static func contraction(of word: String) -> String? {
        let key = word.lowercased()
        let pairs = [
            ("its", "it's"), ("it's", "its"),
            ("were", "we're"), ("we're", "were"),
            ("cant", "can't"), ("can't", "cant"),
            ("wont", "won't"), ("won't", "wont"),
            ("dont", "don't"), ("don't", "dont"),
            ("im", "i'm"), ("i'm", "im"),
            ("lets", "let's"), ("let's", "lets"),
        ]
        return pairs.first { $0.0 == key }?.1
    }

    private static func joined(_ words: String) -> String? {
        let parts = words.split(separator: " ")
        guard parts.count == 2 else { return nil }
        return parts.joined()
    }
}

/// A tiny arithmetic parser for a token such as `12*7` or `(2+3)*4`. Not an evaluator of Swift.
enum ExpressionValue {
    static func token(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let scalars = Array(text)
        var start = scalars.count
        while start > 0 {
            let character = scalars[start - 1]
            if character.isNumber || "+-*/().".contains(character) {
                start -= 1
            } else {
                break
            }
        }
        let token = String(scalars[start...])
        guard token.contains(where: { "+-*/".contains($0) }), token.contains(where: \.isNumber) else { return nil }
        return token
    }

    static func result(of token: String) -> String? {
        var parser = Parser(Array(token))
        guard let value = parser.parse(), parser.isAtEnd, value.isFinite else { return nil }
        if value.rounded() == value, abs(value) < 1_000_000_000 {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }

    private struct Parser {
        var characters: [Character]
        var index = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        var isAtEnd: Bool { index == characters.count }

        mutating func parse() -> Double? { parseSum() }

        mutating func parseSum() -> Double? {
            guard var value = parseProduct() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                guard let next = parseProduct() else { return nil }
                value = op == "+" ? value + next : value - next
            }
            return value
        }

        mutating func parseProduct() -> Double? {
            guard var value = parseUnary() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                index += 1
                guard let next = parseUnary() else { return nil }
                if op == "/" {
                    guard next != 0 else { return nil }
                    value /= next
                } else {
                    value *= next
                }
            }
            return value
        }

        mutating func parseUnary() -> Double? {
            if peek() == "-" {
                index += 1
                guard let value = parseUnary() else { return nil }
                return -value
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Double? {
            if peek() == "(" {
                index += 1
                guard let value = parseSum(), peek() == ")" else { return nil }
                index += 1
                return value
            }
            let start = index
            if peek() == "." { return nil }
            while let character = peek(), character.isNumber || character == "." {
                index += 1
            }
            guard index > start else { return nil }
            return Double(String(characters[start..<index]))
        }

        func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }
    }
}

/// A short expansion, such as `omw` → "on my way". Stored beside the other learning files.
struct Snippet: Codable, Hashable, Sendable {
    var trigger: String
    var expansion: String
}

struct SnippetBook: Equatable, Sendable {
    var items: [Snippet]

    static let bundled = [Snippet(trigger: "omw", expansion: "on my way")]

    func expansion(for word: String) -> String? {
        items.first { $0.trigger.compare(word, options: .caseInsensitive) == .orderedSame }?.expansion
    }

    static func load() -> SnippetBook {
        guard let url = LearningDirectory.fileURL(named: "Snippets.json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Snippet].self, from: data),
              !items.isEmpty
        else { return SnippetBook(items: bundled) }
        return SnippetBook(items: items)
    }
}

/// A small bundled table. Recents live in the learning directory; this is not a second lexicon.
enum EmojiWords {
    static let bundled: [String: String] = [
        "love": "❤️", "heart": "❤️", "happy": "😊", "smile": "😊", "sad": "😢",
        "yes": "👍", "ok": "👍", "no": "👎", "thanks": "🙏", "thank": "🙏",
        "please": "🙏", "sorry": "😔", "wow": "😮", "lol": "😂", "haha": "😂",
        "cool": "😎", "fire": "🔥", "star": "⭐️", "sun": "☀️", "rain": "🌧",
        "coffee": "☕️", "tea": "🍵", "pizza": "🍕", "cake": "🎂", "party": "🎉",
        "idea": "💡", "time": "⏰", "home": "🏠", "car": "🚗", "phone": "📱",
        "music": "🎵", "book": "📚", "check": "✅", "warning": "⚠️", "hello": "👋",
        "bye": "👋", "wave": "👋", "kiss": "😘", "cat": "🐱", "dog": "🐶",
    ]

    static func symbol(for word: String, recents: [String: String] = [:]) -> String? {
        let key = word.lowercased()
        return recents[key] ?? bundled[key]
    }

    static func loadRecents() -> [String: String] {
        guard let url = LearningDirectory.fileURL(named: "emoji-recents.json"),
              let data = try? Data(contentsOf: url),
              let recents = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return recents
    }

    static func remember(_ word: String, symbol: String) {
        guard let url = LearningDirectory.fileURL(named: "emoji-recents.json") else { return }
        var recents = loadRecents()
        recents[word.lowercased()] = symbol
        guard let data = try? JSONEncoder().encode(recents) else { return }
        try? data.write(to: url)
    }
}

/// How long one history replacement took. Tests pass the elapsed time; the log does not read a device clock.
extension String {
    func suffix(utf16Count count: Int) -> String? {
        guard count > 0 else { return nil }
        var remaining = count
        var index = endIndex
        while remaining > 0, index > startIndex {
            index = self.index(before: index)
            remaining -= self[index].utf16.count
        }
        guard remaining == 0 else { return nil }
        return String(self[index...])
    }
}

enum HistoryEditLog {
    struct Record: Equatable {
        var milliseconds: Double
    }

    static func record(elapsed seconds: Double) -> Record {
        Record(milliseconds: seconds * 1000)
    }
}
