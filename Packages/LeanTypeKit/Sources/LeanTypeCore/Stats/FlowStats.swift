import Foundation

/// Typing counters for the app's "Your flow" card. Counts only, never text, kept on device.
public struct FlowStats: Codable, Hashable, Sendable {
    /// Words finished per day, keyed by days since the reference date in the user's calendar.
    /// Only the last `retainedDays` are kept.
    public private(set) var wordsByDay: [Int: Int] = [:]
    public private(set) var wordsSwiped = 0
    /// Most words in a row without touching backspace.
    public private(set) var longestStreak = 0
    /// Deleted words brought back with a swipe on backspace.
    public private(set) var wordsRestored = 0

    static let retainedDays = 14

    public init() {}

    public static func day(of date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: Date(timeIntervalSinceReferenceDate: 0), to: start).day ?? 0
    }

    /// Words finished in the seven days ending on `date`'s day.
    public func wordsThisWeek(asOf date: Date = .now, calendar: Calendar = .current) -> Int {
        let today = Self.day(of: date, calendar: calendar)
        return wordsByDay.reduce(0) { total, entry in
            (today - 6...today).contains(entry.key) ? total + entry.value : total
        }
    }

    public var isEmpty: Bool {
        wordsByDay.isEmpty && wordsRestored == 0 && longestStreak == 0
    }

    // MARK: - Recording

    mutating func recordWord(on day: Int, swiped: Bool) {
        wordsByDay[day, default: 0] += 1
        if swiped { wordsSwiped += 1 }
    }

    mutating func recordStreak(_ length: Int) {
        longestStreak = max(longestStreak, length)
    }

    mutating func recordRestore() {
        wordsRestored += 1
    }

    /// Adds `other`'s counts to these, keeping the longer streak, then drops old days.
    mutating func merge(_ other: FlowStats, today: Int) {
        for (day, count) in other.wordsByDay {
            wordsByDay[day, default: 0] += count
        }
        wordsSwiped += other.wordsSwiped
        wordsRestored += other.wordsRestored
        longestStreak = max(longestStreak, other.longestStreak)
        wordsByDay = wordsByDay.filter { today - $0.key < Self.retainedDays }
    }
}

/// `FlowStats` in the App Group: written by the keyboard (with Full Access), read by the app.
public struct AppGroupFlowStatsStore: Sendable {
    private let file: CodableFileStore<FlowStats>

    public init(fileName: String = "FlowStats.json") {
        file = CodableFileStore { SharedContainer.fileURL(named: fileName) }
    }

    init(file: CodableFileStore<FlowStats>) {
        self.file = file
    }

    public func load() -> FlowStats { file.load() ?? FlowStats() }
    public func save(_ stats: FlowStats) { file.save(stats) }
    public func reset() { file.remove() }
}

/// Turns keyboard events into `FlowStats` counts, held in memory and merged into the store
/// when the keyboard hides, so typing never waits on a file write.
@MainActor
public final class FlowStatsRecorder: KeyboardEventObserver {
    private let store: AppGroupFlowStatsStore
    private let now: () -> Date
    private var pending = FlowStats()
    private var streak = 0

    /// Off without Full Access: the shared container isn't writable then anyway.
    public var isEnabled = false

    public init(store: AppGroupFlowStatsStore = AppGroupFlowStatsStore(), now: @escaping () -> Date = { .now }) {
        self.store = store
        self.now = now
    }

    public func handle(_ event: KeyboardEvent) {
        guard isEnabled else { return }
        switch event {
        case let .wordCommitted(source):
            pending.recordWord(on: FlowStats.day(of: now()), swiped: source == .swipe)
            streak += 1
            pending.recordStreak(streak)
        case .keyDown(.delete, _):
            streak = 0
        case .deletionRestored:
            pending.recordRestore()
        default:
            break
        }
    }

    /// Merges what was recorded into the shared store.
    public func flush() {
        guard isEnabled, !pending.isEmpty else { return }
        var stats = store.load()
        stats.merge(pending, today: FlowStats.day(of: now()))
        store.save(stats)
        pending = FlowStats()
    }
}
