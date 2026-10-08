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
    /// The user asked for this spelling not to be suggested.
    case blocked
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
    let aligner: AlignmentDecoder

    /// Learning only happens when this is on (the setting plus Full Access).
    public var isLearningEnabled = false

    private let store: (any LearnedWordsStore)?
    private let rejections: RejectionMemory
    private let swipeRefusals = SwipeRefusalMemory()
    private let blocklist: Blocklist
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
        wordContext contextStore: (any WordContextStore)? = nil,
        blocklist blocklistStore: (any BlocklistStore)? = nil
    ) {
        self.lexicon = lexicon
        self.store = store
        rejections = RejectionMemory(store: rejectionStore)
        blocklist = Blocklist(store: blocklistStore)
        context = WordContext(store: contextStore)
        decoder = PathDecoder(lexicon: lexicon)
        aligner = AlignmentDecoder()
        personal = PersonalLexicon(learned: store?.load() ?? [])
        personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
    }

    /// Loads the bundled dictionary; `nil` if it's missing or unreadable.
    public static func bundled(
        store: (any LearnedWordsStore)? = nil,
        rejections: (any RejectionStore)? = nil,
        wordContext: (any WordContextStore)? = nil,
        blocklist: (any BlocklistStore)? = nil
    ) -> LanguageModel? {
        guard let lexicon = try? MappedLexicon.bundled() else { return nil }
        return LanguageModel(
            lexicon: lexicon,
            store: store,
            rejections: rejections,
            wordContext: wordContext,
            blocklist: blocklist
        )
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
        corrector.isBlocked = { [blocklist] word in
            blocklist.contains(word)
        }
        return corrector.analyze(word, touches: touches, layout: layout, completionLimit: completionLimit)
    }

    func decode(_ gesture: SwipeGesture, layout: LetterLayout) async -> DecodeResult {
        let result = await decoder.decode(gesture, layout: layout, personal: personalEntries)
        return finish(result, trace: Self.strokeTrace(of: gesture))
    }

    /// One alignment of a whole gesture: taps, anchors, and the keys a stroke only crossed.
    func align(_ gesture: SwipeGesture, layout: LetterLayout, costs: AlignmentCosts = .standard) async -> DecodeResult {
        let result = await aligner.decode(
            gesture,
            layout: layout,
            personal: personalEntries,
            bigram: preparedBigram(),
            lexicon: lexicon,
            costs: costs
        )
        return finish(result, trace: Self.strokeTrace(of: gesture))
    }

    /// Words for a sequence of taps and swipe arrivals, best first. Used when a later beat
    /// joins an open word and the original polylines are no longer the thing being scored.
    func sequenceDecode(_ observations: [StrokeObservation], layout: LetterLayout, costs: AlignmentCosts = .standard) -> SequenceOutcome {
        guard !observations.isEmpty else { return .empty }
        let evidence = SwipeEvidence.fromObservations(observations)
        let strokes = Set(observations.filter { !$0.isTap && $0.strokeIndex >= 0 }.map(\.strokeIndex))
        let gesture = SwipeGesture(
            path: [],
            strokeCount: max(strokes.count, 1),
            tracedLetters: evidence.aimedLetters,
            observations: observations,
            evidence: evidence
        )
        var pathScore = PathScore()
        let result = AlignmentSearch.decode(
            gesture,
            layout: layout,
            lexicon: lexicon,
            personal: personalEntries,
            bigram: preparedBigram(),
            costs: costs,
            pathScore: &pathScore
        )
        return SequenceOutcome(
            result: finish(result, trace: evidence.aimedLetters),
            traced: evidence.aimedLetters
        )
    }

    /// Saved corrections first, then a swipe the user just deleted. The deletion only changes
    /// the order when that same word would have led a similar stroke.
    private func finish(_ result: DecodeResult, trace: String) -> DecodeResult {
        swipeRefusals.applying(
            to: blocklist.applying(to: rejections.applying(to: context.applying(to: result))),
            trace: trace
        )
    }

    private static func strokeTrace(of gesture: SwipeGesture) -> String {
        gesture.tracedLetters.isEmpty ? gesture.evidence.aimedLetters : gesture.tracedLetters
    }

    private func preparedBigram() -> LetterBigram {
        if letterBigram == nil {
            letterBigram = LetterBigram(lexicon: lexicon)
        }
        return letterBigram ?? LetterBigram(lexicon: lexicon)
    }

    /// The word that just landed, so the next swipe can prefer what usually follows it.
    func noteCommitted(_ word: String) {
        context.noteCommitted(word)
    }

    /// A period, question mark, exclamation, or new line. The next word is a new sentence.
    func noteSentenceEnded() {
        context.noteSentenceEnded()
    }

    /// What a swipe would rank once the preceding word is taken into account.
    func preferringFollowers(in result: DecodeResult) -> DecodeResult {
        context.applying(to: result)
    }

    /// Remembers that the user wanted `preferred` instead of the `rejected` correction.
    func noteRejection(preferred: String, rejected: String) {
        rejections.note(preferred: preferred, rejected: rejected)
    }

    /// The user deleted this swipe the moment it landed. The next similar stroke tries another word.
    func noteSwipeRefusal(word: String, trace: String) {
        swipeRefusals.note(word: word, trace: trace)
    }

    /// A right-swipe on backspace put the deleted word back.
    func forgetSwipeRefusal(word: String) {
        swipeRefusals.forget(word: word)
    }

    /// A new swiped word landed, so older refusals step closer to being forgotten.
    func noteSwipeLanded() {
        swipeRefusals.noteSwipeLanded()
    }

    func applyingSwipeRefusals(to result: DecodeResult, trace: String) -> DecodeResult {
        swipeRefusals.applying(to: result, trace: trace)
    }

    func applyingRejections(to result: DecodeResult) -> DecodeResult {
        rejections.applying(to: result)
    }

    func applyingBlocks(to result: DecodeResult) -> DecodeResult {
        blocklist.applying(to: result)
    }

    func isBlocked(_ word: String) -> Bool {
        blocklist.contains(word)
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
        if blocklist.contains(word) { return .blocked }
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
        let restored = blocklist.restore(word)
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLearningEnabled, Self.isLearnable(word), personal.remember(word, at: Date()) else { return restored }
        persistPersonalChange()
        return true
    }

    /// Keeps `word` out of suggestions until it is remembered or restored from the companion.
    @discardableResult
    public func ban(_ word: String) -> Bool {
        blocklist.block(word)
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
        blocklist.reload()
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
