import Foundation

/// One pair this user actually writes: `next` following `previous`.
public struct WordPair: Codable, Hashable, Sendable {
    public var previous: String
    public var next: String
    public var uses: Int
    public var lastUsed: Date

    public init(previous: String, next: String, uses: Int = 1, lastUsed: Date) {
        self.previous = previous
        self.next = next
        self.uses = uses
        self.lastUsed = lastUsed
    }
}

/// Where word pairs are kept. A nil file (no Full Access) means the list lasts for this session.
public protocol WordContextStore: Sendable {
    func load() -> [WordPair]
    func save(_ pairs: [WordPair])
}

/// `WordPairs.json` in the App Group, same home as learned words.
public struct AppGroupWordContextStore: WordContextStore {
    private let file: CodableFileStore<[WordPair]>

    public init(fileName: String = "WordPairs.json") {
        file = CodableFileStore { SharedContainer.fileURL(named: fileName) }
    }

    public func load() -> [WordPair] {
        file.load() ?? []
    }

    public func save(_ pairs: [WordPair]) {
        file.save(pairs)
    }
}

/// A short memory of which word followed which, including the two words before it.
/// The bonus only moves a follower that was already a close call; a clearly better shape
/// stays first. Before this user has a pair, a short list of common followers breaks the
/// same kind of tie. A pair this user has written still wins over that list.
@MainActor
final class WordContext {
    static let capacity = 400

    /// Followers worth offering before this user has written the pair themselves.
    /// The first word in each list is the one to prefer when several are close.
    private static let commonFollowers: [String: [String]] = [
        "to": ["the", "be", "do", "get", "a"],
        "of": ["the", "a", "it"],
        "in": ["the", "a", "this"],
        "there": ["is", "are", "was"],
        "for": ["the", "a", "you"],
        "on": ["the", "a"],
        "it": ["is", "was"],
        "and": ["the", "then"],
        "is": ["a", "the", "not"],
        "that": ["is", "the"],
        "with": ["the", "a"],
        "from": ["the", "a"],
        "this": ["is", "was"],
        "have": ["to", "a", "been"],
        "be": ["a", "the", "able"],
        "i": ["am", "have", "think", "was"],
        "you": ["are", "can", "know"],
        "we": ["are", "can", "have"],
        "do": ["you", "not", "it"],
        "don't": ["know", "want", "have"],
        "going": ["to"],
        "want": ["to", "a"],
        "would": ["be", "like"],
        "was": ["a", "the"],
        "if": ["you", "the", "i"],
        "but": ["the", "i"],
        "my": ["own"],
        "about": ["the", "it"],
        "into": ["the"],
        "out": ["of"],
        "more": ["than"],
        "because": ["of", "the"],
    ]

    /// The two words just written, when this user has not stored that triple yet.
    private static let commonTriples: [String: [String]] = [
        "going to": ["the", "be", "get"],
        "want to": ["be", "go", "see"],
        "have to": ["be", "go", "do"],
        "used to": ["be"],
        "trying to": ["get", "be"],
        "need to": ["be", "get"],
        "i don't": ["know", "think", "want"],
        "don't know": ["what", "how", "why"],
        "a lot": ["of"],
        "out of": ["the"],
        "one of": ["the", "them"],
        "kind of": ["a", "the"],
        "because of": ["the"],
        "instead of": ["the"],
        "according to": ["the"],
    ]

    /// The last two committed words, oldest first. Not persisted; the pairs are.
    private var recent: [String] = []
    private var pairs: [WordPair]
    private let store: (any WordContextStore)?

    init(store: (any WordContextStore)? = nil) {
        self.store = store
        pairs = store?.load() ?? []
        if pairs.count > Self.capacity {
            trim()
        }
    }

    /// Records `word` as what was just committed, the pair from the word before it, and the
    /// triple from the two words before it.
    func noteCommitted(_ word: String) {
        let word = Self.normalized(word)
        guard !word.isEmpty else { return }
        if let immediate = recent.last, immediate != word {
            record(previous: immediate, next: word)
            if recent.count >= 2 {
                record(previous: recent.suffix(2).joined(separator: " "), next: word)
            }
        }
        recent.append(word)
        if recent.count > 2 {
            recent.removeFirst(recent.count - 2)
        }
    }

    /// Moves a remembered follower ahead of the top word when the two were already close.
    /// A triple this user has written wins over a pair. A personal pair wins over the static
    /// list. With no personal memory, a common triple, then a common pair, can break the tie.
    func applying(to result: DecodeResult) -> DecodeResult {
        guard let immediate = recent.last, result.readings.count > 1, let top = result.readings.first else { return result }
        let tripleKey = recent.count >= 2 ? recent.suffix(2).joined(separator: " ") : nil
        if let tripleKey {
            let personal = pairs.filter { $0.previous == tripleKey }
            if !personal.isEmpty {
                return promoting(ranked(personal), in: result, top: top)
            }
        }
        let personalPair = pairs.filter { $0.previous == immediate }
        if !personalPair.isEmpty {
            return promoting(ranked(personalPair), in: result, top: top)
        }
        if let tripleKey, let common = Self.commonTriples[tripleKey] {
            return promoting(ranked(common), in: result, top: top)
        }
        guard let common = Self.commonFollowers[immediate] else { return result }
        return promoting(ranked(common), in: result, top: top)
    }

    private func record(previous: String, next: String) {
        if let index = pairs.firstIndex(where: { $0.previous == previous && $0.next == next }) {
            pairs[index].uses += 1
            pairs[index].lastUsed = .now
        } else {
            pairs.append(WordPair(previous: previous, next: next, lastUsed: .now))
        }
        if pairs.count > Self.capacity {
            trim()
        }
        store?.save(pairs)
    }

    private func ranked(_ pairs: [WordPair]) -> [(word: String, rank: (Int, Date))] {
        pairs.map { (word: $0.next, rank: ($0.uses, $0.lastUsed)) }
    }

    private func ranked(_ words: [String]) -> [(word: String, rank: (Int, Date))] {
        words.enumerated().map { index, word in
            (word: word, rank: (words.count - index, Date.distantPast))
        }
    }

    private func promoting(
        _ followers: [(word: String, rank: (Int, Date))],
        in result: DecodeResult,
        top: DecodeResult.Reading
    ) -> DecodeResult {
        let ranked = result.readings.enumerated().dropFirst().filter { _, reading in
            top.score - reading.score <= DecodeResult.confidenceMargin
                && followers.contains { $0.word == reading.word.lowercased() }
        }
        guard let best = ranked.max(by: { lhs, rhs in
            rank(of: lhs.element.word, in: followers) < rank(of: rhs.element.word, in: followers)
        }) else { return result }
        var readings = result.readings
        let chosen = readings.remove(at: best.offset)
        readings.insert(
            DecodeResult.Reading(word: chosen.word, score: top.score + 0.01),
            at: 0
        )
        return DecodeResult(readings: readings)
    }

    private func rank(of word: String, in followers: [(word: String, rank: (Int, Date))]) -> (Int, Date) {
        followers.first { $0.word == word.lowercased() }?.rank ?? (0, .distantPast)
    }

    private func trim() {
        pairs.sort { $0.lastUsed < $1.lastUsed }
        if pairs.count > Self.capacity {
            pairs.removeFirst(pairs.count - Self.capacity)
        }
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
