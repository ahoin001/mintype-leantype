import Foundation

/// A word the user taught the keyboard by typing it.
public struct LearnedWord: Codable, Hashable, Sendable {
    public let word: String
    public var uses: Int
    public var lastUsed: Date

    public init(word: String, uses: Int = 1, lastUsed: Date) {
        self.word = word
        self.uses = uses
        self.lastUsed = lastUsed
    }
}

/// Words outside the dictionary that this user actually writes: names from contacts and text
/// replacements (iOS's supplementary lexicon), plus a rolling list of recently typed words.
///
/// Personal words are never autocorrected away and take part in suggestions and swipe
/// decoding. The learned list is capped; the least recently used word makes room.
public struct PersonalLexicon: Sendable {
    public static let capacity = 1000
    /// Uses before a learned word starts appearing as a suggestion.
    static let usesBeforeSuggesting = 2

    /// A personal word ready for matching: its display form, key, and an estimated log count
    /// comparable with the dictionary's.
    public struct Entry: Hashable, Sendable {
        public let display: String
        public let key: [UInt8]
        public let logCount: Double
    }

    private var learned: [String: LearnedWord] = [:]
    private var supplementary: [String: String] = [:]

    public init(learned: [LearnedWord] = [], supplementary: [String] = []) {
        for word in learned {
            self.learned[Self.storageKey(word.word)] = word
        }
        setSupplementary(supplementary)
    }

    public var learnedWords: [LearnedWord] { Array(learned.values) }
    public var isEmpty: Bool { learned.isEmpty && supplementary.isEmpty }

    public func contains(_ word: some StringProtocol) -> Bool {
        let key = Self.storageKey(word)
        return learned[key] != nil || supplementary[key] != nil
    }

    public mutating func setSupplementary(_ words: [String]) {
        supplementary = [:]
        for word in words where !word.contains(" ") && !LexiconKey.make(word).isEmpty {
            supplementary[Self.storageKey(word)] = word
        }
    }

    /// Records a use of `word`. Returns `true` if the list changed shape (a new word).
    @discardableResult
    public mutating func learn(_ word: String, at date: Date) -> Bool {
        let key = Self.storageKey(word)
        guard !key.isEmpty else { return false }
        if var existing = learned[key] {
            existing.uses += 1
            existing.lastUsed = date
            learned[key] = existing
            return false
        }
        if learned.count >= Self.capacity, let oldest = learned.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            learned[oldest.key] = nil
        }
        learned[key] = LearnedWord(word: word, lastUsed: date)
        return true
    }

    public mutating func forgetLearned() {
        learned = [:]
    }

    /// Entries for matching, given the dictionary's log-count range so personal words rank
    /// alongside dictionary words: a word used often climbs toward common-word territory.
    public func entries(logCountRange: ClosedRange<Double>) -> [Entry] {
        let span = logCountRange.upperBound - logCountRange.lowerBound
        var result: [Entry] = []
        result.reserveCapacity(learned.count + supplementary.count)
        for word in learned.values where word.uses >= Self.usesBeforeSuggesting {
            let boost = min(0.35 + 0.08 * log2(Double(word.uses)), 0.75)
            result.append(Entry(display: word.word, key: LexiconKey.make(word.word), logCount: logCountRange.lowerBound + span * boost))
        }
        for display in supplementary.values {
            result.append(Entry(display: display, key: LexiconKey.make(display), logCount: logCountRange.lowerBound + span * 0.55))
        }
        return result
    }

    private static func storageKey(_ word: some StringProtocol) -> String {
        word.lowercased()
    }
}

/// Where learned words persist between keyboard sessions.
public protocol LearnedWordsStore: Sendable {
    func load() -> [LearnedWord]
    func save(_ words: [LearnedWord])
    func clear()
}
