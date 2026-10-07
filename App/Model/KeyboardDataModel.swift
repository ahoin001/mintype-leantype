import Foundation
import LeanTypeCore
import Observation

/// What the keyboard keeps on this device besides settings: learned words and flow counters.
/// The app reads them for display and can clear them; the keyboard is told to reload.
@MainActor
@Observable
final class KeyboardDataModel {
    private(set) var learnedWords: [LearnedWord] = []
    private(set) var stats = FlowStats()

    var learnedWordCount: Int { learnedWords.count }

    @ObservationIgnored private let learnedWordsStore: any LearnedWordsStore
    @ObservationIgnored private let statsStore: AppGroupFlowStatsStore

    init(learnedWords: any LearnedWordsStore = AppGroupLearnedWordsStore(), statsStore: AppGroupFlowStatsStore = AppGroupFlowStatsStore()) {
        self.learnedWordsStore = learnedWords
        self.statsStore = statsStore
        refresh()
    }

    func refresh() {
        learnedWords = learnedWordsStore.load().sorted { $0.lastUsed > $1.lastUsed }
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
}
