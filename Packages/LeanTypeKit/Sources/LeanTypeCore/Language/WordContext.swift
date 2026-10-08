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

/// A short memory of which word followed which. The bonus only moves a follower that was
/// already a close call; a clearly better shape stays first.
@MainActor
final class WordContext {
    static let capacity = 400

    private var preceding: String?
    private var pairs: [WordPair]
    private let store: (any WordContextStore)?

    init(store: (any WordContextStore)? = nil) {
        self.store = store
        pairs = store?.load() ?? []
        if pairs.count > Self.capacity {
            trim()
        }
    }

    /// Records `word` as what was just committed, and the pair from the word before it.
    func noteCommitted(_ word: String) {
        let word = Self.normalized(word)
        guard !word.isEmpty else { return }
        if let preceding, preceding != word {
            record(previous: preceding, next: word)
        }
        preceding = word
    }

    /// Moves a remembered follower ahead of the top word when the two were already close.
    func applying(to result: DecodeResult) -> DecodeResult {
        guard let preceding, result.readings.count > 1, let top = result.readings.first else { return result }
        let followers = pairs.filter { $0.previous == preceding }
        guard !followers.isEmpty else { return result }
        let ranked = result.readings.enumerated().dropFirst().filter { _, reading in
            top.score - reading.score <= DecodeResult.confidenceMargin
                && followers.contains { $0.next == reading.word.lowercased() }
        }
        guard let best = ranked.max(by: { lhs, rhs in
            strength(of: lhs.element.word, in: followers) < strength(of: rhs.element.word, in: followers)
        }) else { return result }
        var readings = result.readings
        let chosen = readings.remove(at: best.offset)
        readings.insert(
            DecodeResult.Reading(word: chosen.word, score: top.score + 0.01),
            at: 0
        )
        return DecodeResult(readings: readings)
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

    private func strength(of word: String, in followers: [WordPair]) -> (Int, Date) {
        let match = followers.first { $0.next == word.lowercased() }
        return (match?.uses ?? 0, match?.lastUsed ?? .distantPast)
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
