import Foundation

/// First and last letter of a stroke. "there" and "three" share one, "the" does too,
/// and a clean "hello" does not.
struct SwipeBucket: Hashable, Sendable {
    var first: Character
    var last: Character

    static func make(_ trace: String) -> SwipeBucket? {
        let letters = trace.lowercased().filter(\.isLetter)
        guard let first = letters.first, let last = letters.last else { return nil }
        return SwipeBucket(first: first, last: last)
    }
}

/// A swipe guess the user deleted. It stays down for this first and last letter until they
/// commit that word on purpose. The list is capped; the least recent refusal makes room.
public struct RefusedSwipe: Codable, Hashable, Sendable {
    public var word: String
    public var first: String
    public var last: String
    public var lastUsed: Date

    public init(word: String, first: String, last: String, lastUsed: Date) {
        self.word = word
        self.first = first
        self.last = last
        self.lastUsed = lastUsed
    }
}

public protocol SwipeRefusalStore: Sendable {
    func load() -> [RefusedSwipe]
    func save(_ entries: [RefusedSwipe])
}

public struct AppGroupSwipeRefusalStore: SwipeRefusalStore {
    private let file: CodableFileStore<[RefusedSwipe]>

    public init(fileName: String = "SwipeRefusals.json") {
        file = CodableFileStore { LearningDirectory.fileURL(named: fileName) }
    }

    public func load() -> [RefusedSwipe] {
        file.load() ?? []
    }

    public func save(_ entries: [RefusedSwipe]) {
        file.save(entries)
    }
}

/// Swipe guesses the user deleted on the spot. A later stroke with the same first and last
/// letter tries another reading. Committing the word on purpose clears the refusal. A stroke
/// with a different shape is left alone.
@MainActor
final class SwipeRefusalMemory {
    static let capacity = 64

    private var entries: [RefusedSwipe]
    private let store: (any SwipeRefusalStore)?

    init(store: (any SwipeRefusalStore)? = nil) {
        self.store = store
        entries = store?.load() ?? []
        if entries.count > Self.capacity {
            trim()
        }
    }

    /// `word` was the guess just deleted. `trace` is the letters the stroke aimed at.
    func note(word: String, trace: String) {
        let word = word.lowercased()
        guard !word.isEmpty, let bucket = SwipeBucket.make(trace) else { return }
        entries.removeAll { $0.word == word && $0.first == String(bucket.first) && $0.last == String(bucket.last) }
        entries.append(RefusedSwipe(
            word: word,
            first: String(bucket.first),
            last: String(bucket.last),
            lastUsed: .now
        ))
        if entries.count > Self.capacity {
            trim()
        }
        store?.save(entries)
    }

    /// The deleted word came back, or the user committed it on purpose.
    func forget(word: String) {
        let word = word.lowercased()
        let before = entries.count
        entries.removeAll { $0.word == word }
        if entries.count != before {
            store?.save(entries)
        }
    }

    /// Later swipes no longer expire a refusal. Kept so callers can still mark a landing.
    func noteSwipeLanded() {}

    /// If the leading word was refused for this kind of stroke, the next reading leads
    /// instead. When every reading was refused, the original order stays.
    func applying(to result: DecodeResult, trace: String) -> DecodeResult {
        guard result.readings.count >= 2, let bucket = SwipeBucket.make(trace) else { return result }
        let first = String(bucket.first)
        let last = String(bucket.last)
        let refused = Set(entries.filter { $0.first == first && $0.last == last }.map(\.word))
        guard !refused.isEmpty,
              let index = result.readings.firstIndex(where: { !refused.contains($0.word.lowercased()) }),
              index != 0
        else { return result }
        var readings = result.readings
        let chosen = readings.remove(at: index)
        readings.insert(chosen, at: 0)
        return result.replacingReadings(readings)
    }

    private func trim() {
        entries.sort { $0.lastUsed < $1.lastUsed }
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }
}
