import CoreGraphics
import Foundation
import Testing
@testable import LeanTypeCore

@MainActor
@Suite("Flow stats")
struct FlowStatsTests {
    private let url = FileManager.default.temporaryDirectory.appending(path: "FlowStats-\(UUID().uuidString).json")

    private func makeStore() -> AppGroupFlowStatsStore {
        let url = url
        return AppGroupFlowStatsStore(file: CodableFileStore { url })
    }

    @Test func countsWordsStreaksAndRestores() {
        let store = makeStore()
        defer { store.reset() }
        let recorder = FlowStatsRecorder(store: store)
        recorder.isEnabled = true

        for _ in 0..<5 { recorder.handle(.wordCommitted(.tap)) }
        recorder.handle(.keyDown(.delete, at: .zero))
        recorder.handle(.wordCommitted(.swipe))
        recorder.handle(.wordCommitted(.swipe))
        recorder.handle(.deletionRestored("hello", origin: .zero))
        recorder.flush()

        let stats = store.load()
        #expect(stats.wordsThisWeek() == 7)
        #expect(stats.wordsSwiped == 2)
        #expect(stats.longestStreak == 5)
        #expect(stats.wordsRestored == 1)
    }

    @Test func flushesMergeIntoWhatsStored() {
        let store = makeStore()
        defer { store.reset() }
        let recorder = FlowStatsRecorder(store: store)
        recorder.isEnabled = true

        recorder.handle(.wordCommitted(.tap))
        recorder.flush()
        recorder.handle(.wordCommitted(.tap))
        recorder.handle(.wordCommitted(.suggestion))
        recorder.flush()
        recorder.flush()

        #expect(store.load().wordsThisWeek() == 3)
        #expect(store.load().longestStreak == 3, "A streak carries across flushes within a session")
    }

    @Test func recordsNothingWhenDisabled() {
        let store = makeStore()
        defer { store.reset() }
        let recorder = FlowStatsRecorder(store: store)
        recorder.handle(.wordCommitted(.tap))
        recorder.flush()
        #expect(store.load().isEmpty)
    }

    @Test func weekCountsOnlyTheLastSevenDays() {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = makeStore()
        defer { store.reset() }
        let recorder = FlowStatsRecorder(store: store) { now }
        recorder.isEnabled = true

        recorder.handle(.wordCommitted(.tap))
        recorder.flush()
        now += 8 * 86400
        recorder.handle(.wordCommitted(.tap))
        recorder.handle(.wordCommitted(.tap))
        recorder.flush()

        #expect(store.load().wordsThisWeek(asOf: now) == 2)
        now += 30 * 86400
        recorder.handle(.wordCommitted(.tap))
        recorder.flush()
        #expect(store.load().wordsByDay.count == 1, "Days past the retention window are dropped")
    }

    @Test func fileStoreRoundTripsAndSurvivesGarbage() throws {
        let url = url
        let file = CodableFileStore<[LearnedWord]> { url }
        defer { file.remove() }
        #expect(file.load() == nil)

        let words = [LearnedWord(word: "Zorbly", uses: 3, lastUsed: Date(timeIntervalSinceReferenceDate: 0))]
        file.save(words)
        #expect(file.load() == words)

        try Data("not json".utf8).write(to: url)
        #expect(file.load() == nil)
    }
}
