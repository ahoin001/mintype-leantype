import Foundation

/// Everything the keyboard knows about English words: the memory-mapped dictionary, the
/// user's personal words, tap autocorrect, and the swipe decoder.
///
/// Optional throughout the engine: without it the keyboard still types, it just doesn't
/// suggest, correct, or decode swipes.
@MainActor
public final class LanguageModel {
    public let lexicon: MappedLexicon
    let decoder: PathDecoder

    /// Learning only happens when this is on (the setting plus Full Access).
    public var isLearningEnabled = false

    private let store: (any LearnedWordsStore)?
    private let rejections: RejectionMemory
    private var personal: PersonalLexicon
    private var personalEntries: [PersonalLexicon.Entry]
    private var supplementaryWords: [String] = []
    private var unsavedChanges = 0

    /// Learned words are written out after this many changes (and when the keyboard hides).
    static let saveInterval = 20

    public init(
        lexicon: MappedLexicon,
        store: (any LearnedWordsStore)? = nil,
        rejections rejectionStore: (any RejectionStore)? = nil
    ) {
        self.lexicon = lexicon
        self.store = store
        rejections = RejectionMemory(store: rejectionStore)
        decoder = PathDecoder(lexicon: lexicon)
        personal = PersonalLexicon(learned: store?.load() ?? [])
        personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
    }

    /// Loads the bundled dictionary; `nil` if it's missing or unreadable.
    public static func bundled(
        store: (any LearnedWordsStore)? = nil,
        rejections: (any RejectionStore)? = nil
    ) -> LanguageModel? {
        guard let lexicon = try? MappedLexicon.bundled() else { return nil }
        return LanguageModel(lexicon: lexicon, store: store, rejections: rejections)
    }

    // MARK: - Queries

    public func isKnown(_ word: some StringProtocol) -> Bool {
        personal.contains(word) || lexicon.contains(word)
    }

    func analyze(_ word: String, touches: [CGPoint]?, layout: LetterLayout?, completionLimit: Int = 2) -> WordAnalysis {
        var corrector = TapCorrector(lexicon: lexicon, personal: personalEntries) { [personal] in personal.contains($0) }
        corrector.isRejected = { [rejections] typed, chosen in
            rejections.rejects(replacing: typed, with: chosen)
        }
        return corrector.analyze(word, touches: touches, layout: layout, completionLimit: completionLimit)
    }

    func decode(_ gesture: SwipeGesture, layout: LetterLayout) async -> DecodeResult {
        let result = await decoder.decode(gesture, layout: layout, personal: personalEntries)
        return rejections.applying(to: result)
    }

    /// Remembers that the user wanted `preferred` instead of the `rejected` correction.
    func noteRejection(preferred: String, rejected: String) {
        rejections.note(preferred: preferred, rejected: rejected)
    }

    func applyingRejections(to result: DecodeResult) -> DecodeResult {
        rejections.applying(to: result)
    }

    // MARK: - Learning

    /// Notes that the user typed `word` on purpose. Dictionary words are ignored, except rare
    /// ones autocorrect would otherwise keep "fixing".
    public func learn(_ word: String) {
        guard isLearningEnabled, word.count >= 2, word.count <= 24, needsLearning(word) else { return }
        personal.learn(word, at: Date())
        personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
        unsavedChanges += 1
        if unsavedChanges >= Self.saveInterval {
            save()
        }
    }

    /// Contact names and text-replacement words from the system's supplementary lexicon.
    public func setSupplementaryWords(_ words: [String]) {
        supplementaryWords = words
        personal.setSupplementary(words)
        personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
    }

    /// Re-reads learned words (after the app cleared them).
    public func reloadLearnedWords() {
        personal = PersonalLexicon(learned: store?.load() ?? [], supplementary: supplementaryWords)
        personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
        unsavedChanges = 0
    }

    public func save() {
        guard unsavedChanges > 0, let store else { return }
        store.save(personal.learnedWords)
        unsavedChanges = 0
    }

    private func needsLearning(_ word: String) -> Bool {
        let matches = lexicon.indices(ofKey: LexiconKey.make(word))
        guard !matches.isEmpty else { return true }
        return matches.allSatisfy { TapCorrector.isCorrectable(logCount: lexicon.logCount(at: $0)) }
    }
}
