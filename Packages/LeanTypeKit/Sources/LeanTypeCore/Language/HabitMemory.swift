import Foundation

/// How often this user commits one word, dictionary words included.
public struct WordHabit: Codable, Hashable, Sendable {
    public var word: String
    public var uses: Int
    public var lastUsed: Date

    public init(word: String, uses: Int = 1, lastUsed: Date) {
        self.word = word
        self.uses = uses
        self.lastUsed = lastUsed
    }
}

/// Where commit counts are kept. A nil file (no Full Access) means the list lasts for this session.
public protocol HabitStore: Sendable {
    func load() -> [WordHabit]
    func save(_ habits: [WordHabit])
}

/// `WordHabits.json` in the App Group, same home as word pairs.
public struct AppGroupHabitStore: HabitStore {
    private let file: CodableFileStore<[WordHabit]>

    public init(fileName: String = "WordHabits.json") {
        file = CodableFileStore { SharedContainer.fileURL(named: fileName) }
    }

    public func load() -> [WordHabit] {
        file.load() ?? []
    }

    public func save(_ habits: [WordHabit]) {
        file.save(habits)
    }
}

/// A short memory of words this user commits, including ones already in the dictionary.
/// The bonus is added on top of the corpus frequency. One use adds nothing, and the bump
/// never grows past a single close call, so a bad shape still loses.
@MainActor
final class HabitMemory {
    static let capacity = 400

    /// `min(0.08 * log2(uses), 0.45)`. Zero for a single commit.
    static func bonus(uses: Int) -> Double {
        guard uses > 1 else { return 0 }
        return min(0.08 * log2(Double(uses)), 0.45)
    }

    private var habits: [WordHabit]
    private let store: (any HabitStore)?

    init(store: (any HabitStore)? = nil) {
        self.store = store
        habits = store?.load() ?? []
        if habits.count > Self.capacity {
            trim()
        }
    }

    func note(_ word: String) {
        let word = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count >= 2, word.count <= 24 else { return }
        if let index = habits.firstIndex(where: { $0.word == word }) {
            habits[index].uses += 1
            habits[index].lastUsed = .now
        } else {
            habits.append(WordHabit(word: word, lastUsed: .now))
        }
        if habits.count > Self.capacity {
            trim()
        }
        store?.save(habits)
    }

    /// Bonuses that can move a ranking. A first use is omitted.
    func bonuses() -> [String: Double] {
        var result: [String: Double] = [:]
        for habit in habits {
            let bonus = Self.bonus(uses: habit.uses)
            if bonus > 0 { result[habit.word] = bonus }
        }
        return result
    }

    private func trim() {
        habits.sort { $0.lastUsed < $1.lastUsed }
        if habits.count > Self.capacity {
            habits.removeFirst(habits.count - Self.capacity)
        }
    }
}
