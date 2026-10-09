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
    private let swipeRefusals: SwipeRefusalMemory
    private let blocklist: Blocklist
    private let context: WordContext
    private let habits: HabitMemory
    private let strokes: StrokeMemory
    private var habitBonuses: [String: Double]
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
        habits habitStore: (any HabitStore)? = nil,
        strokes strokeStore: (any StrokeStore)? = nil,
        blocklist blocklistStore: (any BlocklistStore)? = nil,
        swipeRefusals refusalStore: (any SwipeRefusalStore)? = nil
    ) {
        self.lexicon = lexicon
        self.store = store
        rejections = RejectionMemory(store: rejectionStore)
        swipeRefusals = SwipeRefusalMemory(store: refusalStore)
        blocklist = Blocklist(store: blocklistStore)
        context = WordContext(store: contextStore)
        let memory = HabitMemory(store: habitStore)
        habits = memory
        strokes = StrokeMemory(store: strokeStore)
        habitBonuses = memory.bonuses()
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
        habits: (any HabitStore)? = nil,
        strokes: (any StrokeStore)? = nil,
        blocklist: (any BlocklistStore)? = nil,
        swipeRefusals: (any SwipeRefusalStore)? = nil
    ) -> LanguageModel? {
        guard let lexicon = try? MappedLexicon.bundled() else { return nil }
        return LanguageModel(
            lexicon: lexicon,
            store: store,
            rejections: rejections,
            wordContext: wordContext,
            habits: habits,
            strokes: strokes,
            blocklist: blocklist,
            swipeRefusals: swipeRefusals
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
        corrector.habits = habitBonuses
        return corrector.analyze(word, touches: touches, layout: layout, completionLimit: completionLimit)
    }

    func decode(_ gesture: SwipeGesture, layout: LetterLayout) async -> DecodeResult {
        let result = await decoder.decode(gesture, layout: layout, personal: personalEntries)
        return finish(result, trace: Self.strokeTrace(of: gesture))
    }

    /// One alignment of a whole gesture: taps, anchors, and the keys a stroke only crossed.
    func align(_ gesture: SwipeGesture, layout: LetterLayout, costs: AlignmentCosts = .standard) async -> DecodeResult {
        let expected = context.hasPrecedingWord ? context.expectedWords() : []
        let bonuses = habitBonuses
        let result = await aligner.decode(
            gesture,
            layout: layout,
            personal: personalEntries,
            bigram: preparedBigram(),
            lexicon: lexicon,
            costs: costs,
            expected: expected,
            habits: bonuses
        )
        let path = gesture.strokePaths.first ?? gesture.path
        return finish(strokes.applying(to: result, path: path, layout: layout), trace: Self.strokeTrace(of: gesture))
    }

    /// Words for a sequence of taps and swipe arrivals, best first. Used when a later beat
    /// joins an open word and the original polylines are no longer the thing being scored.
    func sequenceDecode(
        _ observations: [StrokeObservation],
        layout: LetterLayout,
        strokePaths: [[CGPoint]] = [],
        costs: AlignmentCosts = .standard
    ) -> SequenceOutcome {
        guard !observations.isEmpty else { return .empty }
        let evidence = SwipeEvidence.fromObservations(observations)
        let strokeIndexes = Set(observations.filter { !$0.isTap && $0.strokeIndex >= 0 }.map(\.strokeIndex))
        let paths = strokePaths.filter { $0.count >= 2 }
        let gesture = SwipeGesture(
            path: paths.max { StrokeAnalyzer.length(of: $0) < StrokeAnalyzer.length(of: $1) } ?? [],
            strokeCount: max(strokeIndexes.count, paths.isEmpty ? 1 : paths.count),
            strokePaths: paths,
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
            expected: context.hasPrecedingWord ? context.expectedWords() : [],
            habits: habitBonuses,
            pathScore: &pathScore
        )
        let adjusted = strokes.applying(to: result, path: gesture.path, layout: layout)
        return SequenceOutcome(
            result: finish(adjusted, trace: evidence.aimedLetters),
            traced: evidence.aimedLetters
        )
    }

    /// Saved corrections first, then a swipe the user just deleted. The deletion only changes
    /// the order when that same word would have led a similar stroke.
    private func finish(_ result: DecodeResult, trace: String) -> DecodeResult {
        swipeRefusals.applying(
            to: blocklist.applying(to: rejections.applying(to: ranking(result))),
            trace: trace
        )
    }

    /// A familiar word can still lead. The follower bonus is applied in the search,
    /// and again here only when a caller asks for it on a result the search did not score.
    private func ranking(_ result: DecodeResult) -> DecodeResult {
        guard context.hasPrecedingWord else { return result }
        return habits.applyingFamiliar(to: result)
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
    func noteCommitted(_ word: String, display: String? = nil) {
        context.noteCommitted(word)
        habits.note(word, display: display)
        if let display, personal.refreshDisplay(display) {
            personalEntries = personal.entries(logCountRange: lexicon.logCountRange)
            unsavedChanges += 1
        }
        habitBonuses = habits.bonuses()
        swipeRefusals.forget(word: word)
    }

    /// The capitalization to show for `word` under `shift`. Shift off keeps a stored name.
    /// A capital past the first letter, such as "iPhone", is not rewritten at a sentence start.
    /// Caps lock still uppercases the whole word.
    func presenting(_ word: String, shift: ShiftState) -> String {
        let shown = storedDisplay(of: word) ?? word
        switch shift {
        case .off:
            return shown
        case .locked:
            return shown.uppercased()
        case .once:
            if shown.dropFirst().contains(where: \.isUppercase) { return shown }
            return shown.prefix(1).uppercased() + shown.dropFirst()
        }
    }

    private func storedDisplay(of word: String) -> String? {
        if let habit = habits.display(of: word), habit != habit.lowercased() { return habit }
        if let personal = personal.display(of: word), personal != personal.lowercased() { return personal }
        return nil
    }

    /// Words the next stroke is likely to be, from the words just written.
    func expectedWords() -> [String] {
        context.expectedWords()
    }

    /// The one word the strip may offer after a committed word. Sentence starters are not offered
    /// when nothing has been written yet.
    func offeredFollower() -> String? {
        guard context.hasPrecedingWord, let next = context.expectedWords().first, !next.isEmpty else { return nil }
        return next
    }

    /// The ranking bump earned by committing `word`. Zero until the second commit.
    func habitBonus(of word: String) -> Double {
        habitBonuses[word.lowercased()] ?? 0
    }

    /// A period, question mark, exclamation, or new line. The next word is a new sentence.
    func noteSentenceEnded() {
        context.noteSentenceEnded()
    }

    /// What a swipe would rank once the preceding word is taken into account.
    func preferringFollowers(in result: DecodeResult) -> DecodeResult {
        let boosted = result.replacingReadings(
            FollowerPrior.applying(result.readings, expected: context.expectedWords())
        )
        return ranking(boosted)
    }

    /// Remembers that the user wanted `preferred` instead of the `rejected` correction.
    func noteRejection(preferred: String, rejected: String) {
        rejections.note(preferred: preferred, rejected: rejected)
    }

    /// The stroke the user just redrew by picking a different word.
    func rememberStroke(_ word: String, path: [CGPoint], layout: LetterLayout) {
        strokes.remember(word, path: path, layout: layout)
    }

    /// Stores the curve when `word` is already one this user commits often.
    func rememberFrequentStroke(_ word: String, path: [CGPoint], layout: LetterLayout) {
        guard habits.uses(of: word) >= WordContext.familiarUses else { return }
        strokes.remember(word, path: path, layout: layout)
    }

    public func useCount(of word: String) -> Int {
        habits.uses(of: word)
    }

    /// Counts `word` enough times to lead a close swipe.
    func moreOften(_ word: String) {
        habits.reinforce(word)
        habitBonuses = habits.bonuses()
    }

    /// Walks the count back one step and drops a stored curve for `word`.
    func lessOften(_ word: String) {
        habits.diminish(word)
        strokes.forget(word)
        habitBonuses = habits.bonuses()
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
    public func learn(_ word: String, display: String? = nil) {
        guard isLearningEnabled, Self.isLearnable(word), needsLearning(word) else { return }
        personal.learn(word, at: Date(), display: display)
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
