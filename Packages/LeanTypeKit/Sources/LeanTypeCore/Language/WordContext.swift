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
    /// Uses before a personal pair may beat a shape that is a little further ahead.
    static let familiarUses = 4
    /// Still a tie, just wider than `DecodeResult.confidenceMargin`. A clear shape stays first.
    static let familiarMargin = 0.7

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
        "a": ["lot", "good", "little"],
        "an": ["old", "hour", "important"],
        "as": ["a", "well", "the"],
        "at": ["the", "least", "all"],
        "by": ["the", "a"],
        "can": ["be", "you", "i"],
        "could": ["be", "have", "you"],
        "did": ["you", "not", "the"],
        "get": ["a", "the", "it"],
        "go": ["to", "back", "home"],
        "good": ["morning", "luck", "idea"],
        "had": ["a", "to", "the"],
        "has": ["a", "been", "to"],
        "he": ["is", "was", "said"],
        "her": ["to", "and", "a"],
        "here": ["is", "are", "we"],
        "him": ["to", "a", "and"],
        "his": ["own", "a"],
        "how": ["to", "are", "much"],
        "just": ["a", "the", "want"],
        "know": ["what", "that", "how"],
        "let": ["me", "us", "you"],
        "like": ["a", "to", "the"],
        "make": ["a", "it", "sure"],
        "me": ["a", "to", "the"],
        "not": ["a", "the", "to"],
        "now": ["i", "the", "that"],
        "or": ["the", "a", "not"],
        "our": ["own", "a"],
        "she": ["is", "was", "said"],
        "should": ["be", "have", "i"],
        "so": ["i", "much", "that"],
        "some": ["of", "people", "time"],
        "take": ["a", "the", "it"],
        "than": ["the", "a", "i"],
        "them": ["to", "a", "and"],
        "then": ["i", "the", "he"],
        "they": ["are", "were", "have"],
        "time": ["to", "i", "for"],
        "up": ["to", "the", "with"],
        "what": ["i", "is", "do"],
        "when": ["i", "the", "you"],
        "where": ["the", "i", "is"],
        "which": ["is", "the"],
        "who": ["is", "are", "was"],
        "will": ["be", "have", "you"],
        "your": ["own", "a"],
        "been": ["a", "the", "to"],
        "back": ["to", "in", "and"],
        "over": ["the", "to"],
        "after": ["the", "a"],
        "before": ["the", "i"],
        "very": ["much", "good"],
        "really": ["good", "want"],
        "think": ["that", "it", "i"],
        "see": ["you", "the", "if"],
        "need": ["to", "a"],
        "thank": ["you"],
        "thanks": ["for"],
        "its": ["a", "the"],
        "it's": ["a", "the", "not"],
        "i'm": ["not", "going", "a"],
        "can't": ["be", "wait"],
        "didn't": ["know", "want"],
        "that's": ["a", "the", "what"],
        "there's": ["a", "no"],
        "we're": ["going", "not"],
        "you're": ["not", "going", "a"],
        "gonna": ["be", "go"],
        "wanna": ["go", "be", "see"],
        "right": ["now", "there"],
        "all": ["the", "of", "right"],
        "one": ["of", "day"],
        "also": ["a", "the"],
        "even": ["if", "the"],
        "still": ["have", "the"],
        "only": ["a", "the"],
        "other": ["than", "people"],
        "same": ["as", "time"],
        "much": ["as", "more"],
        "many": ["people", "of"],
        "most": ["of", "people"],
        "such": ["a", "as"],
        "too": ["much", "many"],
        "well": ["as", "i"],
        "way": ["to", "of"],
        "look": ["at", "like"],
        "come": ["on", "to"],
        "went": ["to", "back"],
        "said": ["that", "i", "the"],
        "say": ["that", "i"],
        "tell": ["me", "you"],
        "give": ["me", "it", "you"],
        "work": ["on", "for"],
        "love": ["you", "it"],
        "feel": ["like"],
        "something": ["to", "like"],
        "anything": ["else", "to"],
        "nothing": ["to", "but"],
        "lot": ["of"],
        "bit": ["of"],
        "sort": ["of"],
        "able": ["to"],
        "sure": ["that", "you"],
        "sorry": ["for", "i"],
        "maybe": ["i", "we"],
        "around": ["the", "here"],
        "through": ["the"],
        "without": ["a", "the"],
        "during": ["the"],
        "between": ["the"],
        "off": ["the", "of"],
        "down": ["the", "to"],
        "again": ["and"],
        "always": ["be", "the"],
        "never": ["been", "the"],
        "today": ["i"],
        "people": ["who", "are"],
        "got": ["a", "to", "the"],
        "let's": ["go", "see"],
        "please": ["let", "help"],
        "yes": ["i", "please"],
        "no": ["i", "one"],
        "hi": ["i"],
        "hey": ["i"],
        "hello": ["i"],
    ]

    /// Words that often open a sentence. Used only after a sentence ends, or at the start.
    private static let sentenceStarters = [
        "i", "the", "it", "this", "we", "you", "a", "if", "but", "so",
        "there", "what", "how", "when", "he", "she", "they", "please", "yes", "no",
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

    /// Drops the words just written. Learned pairs stay, so the next sentence can start fresh.
    func noteSentenceEnded() {
        recent.removeAll()
    }

    /// Up to three words the next stroke is likely to be. Personal memory wins over the
    /// static lists, and a sentence start only offers sentence openers. The decoder scores
    /// these; it does not promote them on its own.
    func expectedWords() -> [String] {
        guard let immediate = recent.last else {
            return Array(Self.sentenceStarters.prefix(3))
        }
        let tripleKey = recent.count >= 2 ? recent.suffix(2).joined(separator: " ") : nil
        if let tripleKey {
            let personal = pairs.filter { $0.previous == tripleKey }
            if !personal.isEmpty {
                return Self.leading(personal, limit: 3)
            }
        }
        let personalPair = pairs.filter { $0.previous == immediate }
        if !personalPair.isEmpty {
            return Self.leading(personalPair, limit: 3)
        }
        if let tripleKey, let common = Self.commonTriples[tripleKey] {
            return Array(common.prefix(3))
        }
        guard let common = Self.commonFollowers[immediate] else { return [] }
        return Array(common.prefix(3))
    }

    private static func leading(_ pairs: [WordPair], limit: Int) -> [String] {
        pairs.sorted { lhs, rhs in
            if lhs.uses != rhs.uses { return lhs.uses > rhs.uses }
            return lhs.lastUsed > rhs.lastUsed
        }
        .prefix(limit)
        .map(\.next)
    }

    /// Moves a remembered follower ahead of the top word when the two were already close.
    /// A triple this user has written wins over a pair. A personal pair wins over the static
    /// list. With no personal memory, a common triple, then a common pair, can break the tie.
    /// After a sentence ends, only sentence-opening words can break that tie.
    func applying(to result: DecodeResult) -> DecodeResult {
        guard result.readings.count > 1, let top = result.readings.first else { return result }
        guard let immediate = recent.last else {
            return promoting(ranked(Self.sentenceStarters), in: result, top: top) ?? result
        }
        let tripleKey = recent.count >= 2 ? recent.suffix(2).joined(separator: " ") : nil
        if let tripleKey {
            let personal = pairs.filter { $0.previous == tripleKey }
            if !personal.isEmpty, let promoted = promoting(ranked(personal), in: result, top: top) {
                return promoted
            }
        }
        let personalPair = pairs.filter { $0.previous == immediate }
        if !personalPair.isEmpty {
            return promoting(ranked(personalPair), in: result, top: top) ?? result
        }
        if let tripleKey, let common = Self.commonTriples[tripleKey] {
            return promoting(ranked(common), in: result, top: top) ?? result
        }
        guard let common = Self.commonFollowers[immediate] else { return result }
        return promoting(ranked(common), in: result, top: top) ?? result
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

    private func ranked(_ pairs: [WordPair]) -> [(word: String, rank: (Int, Date), margin: Double)] {
        pairs.map { pair in
            let margin = pair.uses >= Self.familiarUses ? Self.familiarMargin : DecodeResult.confidenceMargin
            return (word: pair.next, rank: (pair.uses, pair.lastUsed), margin: margin)
        }
    }

    private func ranked(_ words: [String]) -> [(word: String, rank: (Int, Date), margin: Double)] {
        words.enumerated().map { index, word in
            (word: word, rank: (words.count - index, Date.distantPast), margin: DecodeResult.confidenceMargin)
        }
    }

    /// Nil when no follower is close enough to move ahead. Callers that have personal memory
    /// then try the next, less specific list. A personal pair still blocks the static list.
    private func promoting(
        _ followers: [(word: String, rank: (Int, Date), margin: Double)],
        in result: DecodeResult,
        top: DecodeResult.Reading
    ) -> DecodeResult? {
        let ranked = result.readings.enumerated().dropFirst().filter { _, reading in
            guard let follower = followers.first(where: { $0.word == reading.word.lowercased() }) else { return false }
            return top.score - reading.score <= follower.margin
        }
        guard let best = ranked.max(by: { lhs, rhs in
            rank(of: lhs.element.word, in: followers) < rank(of: rhs.element.word, in: followers)
        }) else { return nil }
        var readings = result.readings
        let chosen = readings.remove(at: best.offset)
        readings.insert(
            DecodeResult.Reading(word: chosen.word, score: top.score + 0.01),
            at: 0
        )
        return result.replacingReadings(readings)
    }

    private func rank(of word: String, in followers: [(word: String, rank: (Int, Date), margin: Double)]) -> (Int, Date) {
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
