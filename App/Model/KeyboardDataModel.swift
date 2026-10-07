import Foundation
import LeanTypeCore
import Observation

/// What the keyboard keeps on this device besides settings: learned words and flow counters.
/// The app reads them for display and can clear them; the keyboard is told to reload.
@MainActor
@Observable
final class KeyboardDataModel {
    private(set) var learnedWordCount = 0
    private(set) var stats = FlowStats()

    @ObservationIgnored private let learnedWords: any LearnedWordsStore
    @ObservationIgnored private let statsStore: AppGroupFlowStatsStore

    init(learnedWords: any LearnedWordsStore = AppGroupLearnedWordsStore(), statsStore: AppGroupFlowStatsStore = AppGroupFlowStatsStore()) {
        self.learnedWords = learnedWords
        self.statsStore = statsStore
        refresh()
    }

    func refresh() {
        learnedWordCount = learnedWords.load().count
        stats = statsStore.load()
    }

    func clearLearnedWords() {
        learnedWords.clear()
        learnedWordCount = 0
        DarwinNotifications.post(SharedContainer.learnedWordsDidChangeNotification)
    }
}
