import Foundation

/// Learned words in the App Group, so they survive between keyboard sessions and the app can
/// count or clear them. Never leaves the device; unavailable (and so never written) without
/// Full Access.
public struct AppGroupLearnedWordsStore: LearnedWordsStore {
    private let file: CodableFileStore<[LearnedWord]>

    public init(fileName: String = "LearnedWords.json") {
        file = CodableFileStore { LearningDirectory.fileURL(named: fileName) }
    }

    public func load() -> [LearnedWord] { file.load() ?? [] }
    public func save(_ words: [LearnedWord]) { file.save(words) }
    public func clear() { file.remove() }
}
