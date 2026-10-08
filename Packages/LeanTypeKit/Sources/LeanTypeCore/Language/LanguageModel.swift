import Foundation

/// Where a word sits in the user's own list.
public enum WordMemory: Equatable, Sendable {
    /// Learning is off, or this isn't a word the list can hold.
    case unavailable
    /// Not stored yet.
    case fresh
    /// Stored, but not yet suggested. Another use, or an explicit remember, promotes it.
    case learning
    /// Stored and eligible to be suggested.
    case remembered
}

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
    private let context: WordContext
    private var personal: PersonalLexicon
    private var personalEntries: [PersonalLexicon.Entry]
    private var letterBigram: LetterBigram?
    private var unsavedChanges = 0

    /// Learned words are written out after this many changes (and when the keyboard hides).
    static let saveInterval = 20

    public init(
        lexicon: MappedLexicon,
        store: (any LearnedWordsStore)? = nil,
        rejections rejectionStore: (any RejectionStore)? = nil,
        wordContext contextStore: (any WordContextStore)? = nil
    ) {
        self.lexicon = lexicon
        self.store = store
        rejections = RejectionMemory(store: rejectionStore)
        context = WordContext(store: contextStore)
        decoder = PathDecoder(lexicon: lexicon)
        personal = PersonalLexicon(learned: store?.load() ?? [])
        personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
    }

    /// Loads the bundled dictionary; `nil` if it's missing or unreadable.
    public static func bundled(
        store: (any LearnedWordsStore)? = nil,
        rejections: (any RejectionStore)? = nil,
        wordContext: (any WordContextStore)? = nil
    ) -> LanguageModel? {
        guard let lexicon = try? MappedLexicon.bundled() else { return nil }
        return LanguageModel(lexicon: lexicon, store: store, rejections: rejections, wordContext: wordContext)
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
        return rejections.applying(to: context.applying(to: result))
    }

    /// Words for a sequence of taps and swipe arrivals, best first. Used when several thumb
    /// actions are still one word. A single continuous swipe keeps using `decode`.
    func sequenceDecode(_ observations: [StrokeObservation], layout: LetterLayout) -> SequenceOutcome {
        guard !observations.isEmpty else { return .empty }
        if letterBigram == nil {
            letterBigram = LetterBigram(lexicon: lexicon)
        }
        guard let letterBigram else { return .empty }
        let outcome = SequenceDecoder.decode(
            observations,
            layout: layout,
            lexicon: lexicon,
            personal: personalEntries,
            bigram: letterBigram
        )
        return SequenceOutcome(result: rejections.applying(to: context.applying(to: outcome.result)), traced: outcome.traced)
    }

    /// The word that just landed, so the next swipe can prefer what usually follows it.
    func noteCommitted(_ word: String) {
        context.noteCommitted(word)
    }

    /// What a swipe would rank once the preceding word is taken into account.
    func preferringFollowers(in result: DecodeResult) -> DecodeResult {
        context.applying(to: result)
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
        guard isLearningEnabled, Self.isLearnable(word), needsLearning(word) else { return }
        personal.learn(word, at: Date())
        personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
        unsavedChanges += 1
        if unsavedChanges >= Self.saveInterval {
            save()
        }
    }

    /// How `word` sits in the personal list, for the suggestion menu.
    public func memory(of word: String) -> WordMemory {
        guard isLearningEnabled, Self.isLearnable(word) else { return .unavailable }
        switch personal.uses(of: word) {
        case nil:
            return .fresh
        case let uses? where uses >= PersonalLexicon.usesBeforeSuggesting:
            return .remembered
        default:
            return .learning
        }
    }

    /// Pins `word` immediately, even if it is a dictionary word autocorrect likes to replace.
    /// One explicit remember is enough for it to be suggested.
    @discardableResult
    public func remember(_ word: String) -> Bool {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLearningEnabled, Self.isLearnable(word), personal.remember(word, at: Date()) else { return false }
        persistPersonalChange()
        return true
    }

    /// Removes one learned word, and any note that said to keep that spelling.
    @discardableResult
    public func forget(_ word: String) -> Bool {
        guard personal.forget(word) else { return false }
        rejections.forget(preferred: word)
        persistPersonalChange()
        return true
    }

    /// Re-reads learned words (after the app cleared them).
    public func reloadLearnedWords() {
        personal = PersonalLexicon(learned: store?.load() ?? [])
        personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
        unsavedChanges = 0
    }

    public func save() {
        guard unsavedChanges > 0, let store else { return }
        store.save(personal.learnedWords)
        unsavedChanges = 0
    }

    private func persistPersonalChange() {
        personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
        unsavedChanges = 0
        store?.save(personal.learnedWords)
    }

    private static func isLearnable(_ word: String) -> Bool {
        guard word.count >= 2, word.count <= 24 else { return false }
        return word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" }
    }

    private func needsLearning(_ word: String) -> Bool {
        let matches = lexicon.indices(ofKey: LexiconKey.make(word))
        guard !matches.isEmpty else { return true }
        return matches.allSatisfy { TapCorrector.isCorrectable(logCount: lexicon.logCount(at: $0)) }
    }
}
