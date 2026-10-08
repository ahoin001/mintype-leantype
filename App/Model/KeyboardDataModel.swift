import Foundation
import LeanTypeCore
import Observation

/// What the keyboard keeps on this device besides settings: learned words, banned spellings,
/// and flow counters. The app reads them for display and can clear them; the keyboard is told to reload.
@MainActor
@Observable
final class KeyboardDataModel {
    private(set) var learnedWords: [LearnedWord] = []
    private(set) var blockedWords: [BlockedSpelling] = []
    private(set) var stats = FlowStats()

    var learnedWordCount: Int { learnedWords.count }
    var blockedWordCount: Int { blockedWords.count }

    @ObservationIgnored private let learnedWordsStore: any LearnedWordsStore
    @ObservationIgnored private let blocklistStore: any BlocklistStore
    @ObservationIgnored private let statsStore: AppGroupFlowStatsStore

    init(
        learnedWords: any LearnedWordsStore = AppGroupLearnedWordsStore(),
        blocklist: any BlocklistStore = AppGroupBlocklistStore(),
        statsStore: AppGroupFlowStatsStore = AppGroupFlowStatsStore()
    ) {
        self.learnedWordsStore = learnedWords
        self.blocklistStore = blocklist
        self.statsStore = statsStore
        refresh()
    }

    func refresh() {
        learnedWords = learnedWordsStore.load().sorted { $0.lastUsed > $1.lastUsed }
        blockedWords = blocklistStore.load().sorted { $0.blockedAt > $1.blockedAt }
        stats = statsStore.load()
    }

    func clearLearnedWords() {
        learnedWordsStore.clear()
        learnedWords = []
        DarwinNotifications.post(SharedContainer.learnedWordsDidChangeNotification)
    }

    /// Drops one word, and the note that said to keep that spelling.
    func forgetLearnedWord(_ word: String) {
        let key = word.lowercased()
        var words = learnedWordsStore.load()
        words.removeAll { $0.word.lowercased() == key }
        learnedWordsStore.save(words)
        var rejections = AppGroupRejectionStore().load()
        let before = rejections.count
        rejections.removeAll { $0.preferred == key }
        if rejections.count != before {
            AppGroupRejectionStore().save(rejections)
        }
        refresh()
        DarwinNotifications.post(SharedContainer.learnedWordsDidChangeNotification)
    }

    /// Puts a banned spelling back into suggestions.
    func restoreBlockedWord(_ word: String) {
        let key = word.lowercased()
        var entries = blocklistStore.load()
        entries.removeAll { $0.word.lowercased() == key }
        blocklistStore.save(entries)
        refresh()
        DarwinNotifications.post(SharedContainer.learnedWordsDidChangeNotification)
    }
}
