import Foundation

/// How often this user commits one word, dictionary words included.
public struct WordHabit: Codable, Hashable, Sendable {
    public var word: String
    /// The capitalization this user committed. Missing from older files, which keep `word`.
    public var display: String
    public var uses: Int
    public var lastUsed: Date

    public init(word: String, display: String? = nil, uses: Int = 1, lastUsed: Date) {
        self.word = word
        self.display = display ?? word
        self.uses = uses
        self.lastUsed = lastUsed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decode(String.self, forKey: .word)
        uses = try container.decode(Int.self, forKey: .uses)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        display = try container.decodeIfPresent(String.self, forKey: .display) ?? word
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(word, forKey: .word)
        try container.encode(display, forKey: .display)
        try container.encode(uses, forKey: .uses)
        try container.encode(lastUsed, forKey: .lastUsed)
    }

    private enum CodingKeys: String, CodingKey {
        case word, display, uses, lastUsed
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
        file = CodableFileStore { LearningDirectory.fileURL(named: fileName) }
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
    /// A commit this recent keeps its full bonus.
    static let freshDays = 7.0
    /// A commit this old, or older, adds nothing.
    static let fadeDays = 45.0

    /// `min(0.08 * log2(uses), 0.45)`, then faded by age. Full for a week, zero after 45 days.
    /// One use adds nothing.
    static func bonus(uses: Int, lastUsed: Date = .now, now: Date = .now) -> Double {
        guard uses > 1 else { return 0 }
        let raw = min(0.08 * log2(Double(uses)), 0.45)
        let days = now.timeIntervalSince(lastUsed) / 86_400
        if days <= freshDays { return raw }
        if days >= fadeDays { return 0 }
        return raw * (1 - (days - freshDays) / (fadeDays - freshDays))
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

    func note(_ word: String, display: String? = nil) {
        let shown = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = shown.lowercased()
        guard word.count >= 2, word.count <= 24 else { return }
        let casing = display?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = habits.firstIndex(where: { $0.word == word }) {
            habits[index].uses += 1
            habits[index].lastUsed = .now
            if let casing, !casing.isEmpty { habits[index].display = casing }
        } else {
            habits.append(WordHabit(word: word, display: casing ?? word, lastUsed: .now))
        }
        if habits.count > Self.capacity {
            trim()
        }
        store?.save(habits)
    }

    /// Enough commits to become familiar, or one more if it already is.
    func reinforce(_ word: String) {
        let shown = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = shown.lowercased()
        guard key.count >= 2, key.count <= 24 else { return }
        if let index = habits.firstIndex(where: { $0.word == key }) {
            habits[index].uses = max(habits[index].uses + 1, WordContext.familiarUses)
            habits[index].lastUsed = .now
            if shown != key { habits[index].display = shown }
        } else {
            habits.append(WordHabit(word: key, display: shown, uses: WordContext.familiarUses, lastUsed: .now))
        }
        if habits.count > Self.capacity { trim() }
        store?.save(habits)
    }

    /// Walks one commit back. The word stays in the language; it is not banned.
    func diminish(_ word: String) {
        let key = word.lowercased()
        guard let index = habits.firstIndex(where: { $0.word == key }) else { return }
        habits[index].uses -= 1
        if habits[index].uses < 1 {
            habits.remove(at: index)
        }
        store?.save(habits)
    }

    /// The capitalization stored for `word`, when this user has committed one.
    func display(of word: String) -> String? {
        let key = word.lowercased()
        return habits.first { $0.word == key }?.display
    }

    func uses(of word: String) -> Int {
        habits.first { $0.word == word.lowercased() }?.uses ?? 0
    }

    /// Moves a word this user has committed enough times ahead of a close reading.
    /// A clearly better path stays first. The caller skips this at the start of a sentence.
    func applyingFamiliar(to result: DecodeResult) -> DecodeResult {
        guard result.readings.count > 1, let top = result.readings.first else { return result }
        let familiar = habits.filter { $0.uses >= WordContext.familiarUses }
        guard !familiar.isEmpty else { return result }
        let ranked = result.readings.enumerated().dropFirst().filter { _, reading in
            familiar.contains { $0.word == reading.word.lowercased() }
                && top.score - reading.score <= WordContext.familiarMargin
        }
        guard let best = ranked.max(by: { lhs, rhs in
            uses(of: lhs.element.word, in: familiar) < uses(of: rhs.element.word, in: familiar)
        }) else { return result }
        var readings = result.readings
        let chosen = readings.remove(at: best.offset)
        readings.insert(DecodeResult.Reading(word: chosen.word, score: top.score + 0.01), at: 0)
        return result.replacingReadings(readings)
    }

    private func uses(of word: String, in familiar: [WordHabit]) -> Int {
        familiar.first { $0.word == word.lowercased() }?.uses ?? 0
    }

    /// Bonuses that can move a ranking. A first use is omitted.
    func bonuses() -> [String: Double] {
        var result: [String: Double] = [:]
        for habit in habits {
            let bonus = Self.bonus(uses: habit.uses, lastUsed: habit.lastUsed)
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
