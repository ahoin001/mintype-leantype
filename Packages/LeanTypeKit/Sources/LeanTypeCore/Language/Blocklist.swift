import Foundation

/// A spelling the user asked the keyboard not to suggest.
public struct BlockedSpelling: Codable, Hashable, Sendable {
    public var word: String
    public var blockedAt: Date

    public init(word: String, blockedAt: Date) {
        self.word = word
        self.blockedAt = blockedAt
    }
}

/// Where banned spellings are kept. A nil file (no Full Access) means the list lasts for this session.
public protocol BlocklistStore: Sendable {
    func load() -> [BlockedSpelling]
    func save(_ entries: [BlockedSpelling])
}

/// `BlockedWords.json` in the App Group, same home as learned words.
public struct AppGroupBlocklistStore: BlocklistStore {
    private let file: CodableFileStore<[BlockedSpelling]>

    public init(fileName: String = "BlockedWords.json") {
        file = CodableFileStore { SharedContainer.fileURL(named: fileName) }
    }

    public func load() -> [BlockedSpelling] {
        file.load() ?? []
    }

    public func save(_ entries: [BlockedSpelling]) {
        file.save(entries)
    }
}

/// Spellings that stay out of swipe readings and autocorrect until the user puts one back.
@MainActor
final class Blocklist {
    static let capacity = 300

    private var entries: [BlockedSpelling]
    private let store: (any BlocklistStore)?

    init(store: (any BlocklistStore)? = nil) {
        self.store = store
        entries = store?.load() ?? []
        if entries.count > Self.capacity {
            trim()
        }
    }

    func reload() {
        entries = store?.load() ?? []
        if entries.count > Self.capacity {
            trim()
        }
    }

    func contains(_ word: String) -> Bool {
        let word = Self.normalized(word)
        return entries.contains { $0.word == word }
    }

    var spellings: [BlockedSpelling] { entries }

    @discardableResult
    func block(_ word: String, at date: Date = .now) -> Bool {
        let word = Self.normalized(word)
        guard !word.isEmpty else { return false }
        entries.removeAll { $0.word == word }
        entries.append(BlockedSpelling(word: word, blockedAt: date))
        if entries.count > Self.capacity {
            trim()
        }
        store?.save(entries)
        return true
    }

    /// Puts `word` back into suggestions. Returns whether it was banned.
    @discardableResult
    func restore(_ word: String) -> Bool {
        let word = Self.normalized(word)
        let before = entries.count
        entries.removeAll { $0.word == word }
        guard entries.count != before else { return false }
        store?.save(entries)
        return true
    }

    /// Drops banned spellings. The next reading leads when the old one was banned.
    func applying(to result: DecodeResult) -> DecodeResult {
        guard !entries.isEmpty else { return result }
        let kept = result.readings.filter { !contains($0.word) }
        guard kept.count != result.readings.count else { return result }
        return DecodeResult(readings: kept)
    }

    private func trim() {
        entries.sort { $0.blockedAt < $1.blockedAt }
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
