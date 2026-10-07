import Foundation

/// Everything the renderer needs besides geometry. Published only when something changes.
public struct KeyboardViewState: Hashable, Sendable {
    public var layer: KeyboardLayer
    public var shift: ShiftState
    public var interaction: InteractionState
    public var returnKey: ReturnKeyKind
    public var isReturnKeyEnabled: Bool
    public var candidates: CandidateState
}

@MainActor
public protocol KeyboardEngineDelegate: AnyObject {
    func keyboardEngine(_ engine: KeyboardEngine, didUpdateGeometry geometry: KeyboardGeometry)
    func keyboardEngine(_ engine: KeyboardEngine, didUpdateState state: KeyboardViewState)
    func keyboardEngine(_ engine: KeyboardEngine, didEmit event: KeyboardEvent)
    func keyboardEngineDidRequestNextKeyboard(_ engine: KeyboardEngine)
}

/// The keyboard's brain: turns touches into edits and mode changes, and publishes what should
/// be drawn. UIKit-free, so the whole input pipeline is unit-testable and reusable by the
/// companion app's live preview.
@MainActor
public final class KeyboardEngine {
    static let doubleSpaceInterval: TimeInterval = 0.45
    /// How long a word stays open after the last finger lifts. A finger that is still down
    /// keeps it open. About a third of a second: long enough for the other thumb, short
    /// enough that the next word does not fall into this one.
    static let wordLeash: TimeInterval = 0.34

    public weak var delegate: (any KeyboardEngineDelegate)?

    public private(set) var settings: KeyboardSettings
    public private(set) var traits: InputTraits
    public private(set) var geometry: KeyboardGeometry
    public private(set) var state: KeyboardViewState

    private let editor: TextEditor
    private let scheduler: any Scheduler
    private let shift = ShiftController()
    private let words: WordAssistant
    private var layer: KeyboardLayer
    private var showsNextKeyboardKey: Bool
    private var insertionCount = 0
    private var lastSpaceTime: TimeInterval?
    private var lastObservedContext: String?
    /// The latest swiped word, still open to another tap or swipe. Nil once it locks.
    private var openWord: OpenWord?
    /// The word just before this one, kept so a letter tapped during the latest stroke can
    /// pull the two back together ("es" + "tagged" + N becomes "estranged").
    private var rejoin: Rejoin?
    /// When the open word stops accepting another beat. Infinity while a finger that landed
    /// in time is still down.
    private var openDeadline: TimeInterval?
    /// Fingers currently on the glass.
    private var liveTouches: Set<TouchID> = []

    lazy var composer = InputComposer { [weak self] intents in
        self?.performBatch(intents)
    }

    private lazy var touchEngine: TouchEngine = {
        let engine = TouchEngine(context: self)
        engine.onInteractionChange = { [weak self] _ in self?.publishState() }
        return engine
    }()

    private lazy var flow = FlowMonitor(scheduler: scheduler) { [weak self] event in
        self?.emit(event)
    }

    private lazy var swipe: SwipeCoordinator = {
        let coordinator = SwipeCoordinator(composer: composer) { [weak self] gesture in
            await self?.decode(gesture) ?? .empty
        }
        coordinator.onPreview = { [weak self] result in
            guard let self else { return }
            if let result {
                words.showPreview(result)
            } else {
                words.clearPreview()
            }
            publishState()
        }
        coordinator.onFinish = { [weak self] in self?.touchEngine.refreshPresentation() }
        return coordinator
    }()

    public init(
        document: any TextDocument,
        settings: KeyboardSettings = .default,
        traits: InputTraits = .default,
        showsNextKeyboardKey: Bool = true,
        metrics: KeyboardMetrics = .portrait,
        language: LanguageModel? = nil,
        scheduler: (any Scheduler)? = nil
    ) {
        editor = TextEditor(document: document)
        words = WordAssistant(editor: editor)
        words.language = language
        self.scheduler = scheduler ?? MainQueueScheduler()
        self.settings = settings
        self.traits = traits
        self.showsNextKeyboardKey = showsNextKeyboardKey

        let layer = Self.initialLayer(for: traits)
        self.layer = layer
        let layout = LayoutProvider.layout(
            for: layer,
            context: LayoutContext(variant: traits.variant, showsNextKeyboardKey: showsNextKeyboardKey)
        )
        geometry = KeyboardGeometry(layout: layout, size: .zero, metrics: metrics)
        state = KeyboardViewState(
            layer: layer,
            shift: .off,
            interaction: .idle,
            returnKey: traits.returnKey,
            isReturnKeyEnabled: true,
            candidates: .empty
        )
        applySettings()
        refreshTextState()
    }

    /// Height the keyboard wants for its current metrics, dock included.
    public var preferredHeight: CGFloat {
        geometry.metrics.totalHeight(rowCount: geometry.layout.rows.count)
    }

    public var language: LanguageModel? { words.language }

    // MARK: - Inputs from the host

    /// Sets the key area size (excluding the dock) and spacing; recomputes frames if changed.
    public func updateLayout(size: CGSize, metrics: KeyboardMetrics) {
        guard size != geometry.size || metrics != geometry.metrics else { return }
        rebuildGeometry(size: size, metrics: metrics)
    }

    public func setShowsNextKeyboardKey(_ shows: Bool) {
        guard shows != showsNextKeyboardKey else { return }
        showsNextKeyboardKey = shows
        rebuildGeometry()
    }

    public func update(settings: KeyboardSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        applySettings()
        refreshTextState()
    }

    public func update(traits: InputTraits) {
        guard traits != self.traits else { return }
        let variantChanged = traits.variant != self.traits.variant
        self.traits = traits
        if variantChanged {
            layer = Self.initialLayer(for: traits)
            rebuildGeometry()
        }
        applySettings()
        refreshTextState()
    }

    /// Installs (or removes) the language model: suggestions, autocorrect, and swipe.
    public func setLanguageModel(_ model: LanguageModel?) {
        words.language = model
        applySettings()
        refreshTextState()
    }

    /// Call when the host reports text or selection changes. Hosts also report our own edits,
    /// so a manual shift choice only resets when the visible context actually differs.
    public func documentDidChange() {
        let context = editor.contextBefore
        if Self.isOwnEcho(previous: lastObservedContext, current: context, inserted: editor.recentCommit?.inserted) {
            refreshTextState()
            return
        }
        closeOpenWord()
        shift.noteContextChanged()
        words.noteContextChanged()
        refreshTextState()
    }

    /// The field echoed an insert this keyboard just made. A cursor move or an outside edit
    /// does not look like the previous text plus that commit, or like the same text with only
    /// the trailing word replaced.
    static func isOwnEcho(previous: String?, current: String?, inserted: String?) -> Bool {
        if current == previous { return true }
        guard let current, let previous, let inserted, !inserted.isEmpty else { return false }
        if previous + inserted == current { return true }
        if current.hasSuffix(inserted), previous.hasSuffix(inserted), previous.hasSuffix(current) {
            return true
        }
        // The trailing word was rewritten ("pil " became "pile ") and the text before it matches.
        return current.hasSuffix(inserted)
            && !previous.hasSuffix(inserted)
            && droppingLastWord(previous) == droppingLastWord(current)
    }

    /// The text before the trailing word, including the space that separates it.
    private static func droppingLastWord(_ text: String) -> Substring {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        while end > text.startIndex, !text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return text[..<end]
    }

    /// Returns to a fresh state, e.g. when the keyboard reappears in a new field.
    public func reset() {
        touchEngine.cancelAll()
        swipe.reset()
        composer.reset()
        shift.reset()
        flow.reset()
        lastSpaceTime = nil
        openWord = nil
        openDeadline = nil
        liveTouches = []
        let initial = Self.initialLayer(for: traits)
        if initial != layer {
            layer = initial
            rebuildGeometry()
        }
        refreshTextState()
    }

    public func handle(_ samples: [TouchSample]) {
        let interval = Signposts.input.beginInterval("Touch batch")
        for sample in samples {
            switch sample.phase {
            case .began:
                liveTouches.insert(sample.id)
                if openWord != nil, let openDeadline, sample.timestamp <= openDeadline {
                    self.openDeadline = .infinity
                }
            case .ended, .cancelled:
                liveTouches.remove(sample.id)
            case .moved:
                break
            }
        }
        touchEngine.handle(samples)
        if openWord != nil {
            if liveTouches.isEmpty {
                if openDeadline == .infinity {
                    openDeadline = scheduler.now + Self.wordLeash
                }
            } else if let openDeadline, openDeadline.isFinite, scheduler.now <= openDeadline {
                self.openDeadline = .infinity
            }
        }
        Signposts.input.endInterval("Touch batch", interval)
    }

    public func cancelAllTouches() {
        touchEngine.cancelAll()
        swipe.reset()
        composer.reset()
        liveTouches = []
    }

    /// Direct activation for assistive technologies (VoiceOver), bypassing gestures.
    public func activateKey(_ id: KeyID) {
        guard let frame = geometry.frame(for: id) else { return }
        switch frame.key.kind {
        case let .character(character):
            perform(.insert(character))
        case .space:
            perform(.space)
        case .backspace:
            perform(.deleteCharacter)
        case .shift:
            perform(.shiftPressBegan)
            perform(.shiftPressEnded)
        case let .layerSwitch(target):
            perform(.switchLayer(target))
        case .returnKey:
            if isReturnKeyEnabled { perform(.returnKey) }
        case .nextKeyboard:
            perform(.nextKeyboard)
        }
    }

    /// Accepts suggestion slot `index`, in order with any typing still in flight.
    /// Pins `word` in the personal list and, when it is the word being typed, leaves it alone.
    public func rememberWord(_ word: String) {
        guard language?.remember(word) == true else { return }
        let current = String(editor.currentWord)
        if current.compare(word, options: .caseInsensitive) == .orderedSame {
            words.keep(current)
        }
        DarwinNotifications.post(SharedContainer.learnedWordsDidChangeNotification)
        refreshTextState()
    }

    /// Drops one learned word. The rest of the list stays.
    public func forgetWord(_ word: String) {
        guard language?.forget(word) == true else { return }
        words.dropKept(word)
        DarwinNotifications.post(SharedContainer.learnedWordsDidChangeNotification)
        refreshTextState()
    }

    /// Re-reads the personal list after the app, or this keyboard, changed it.
    public func reloadLearnedWords() {
        language?.reloadLearnedWords()
        refreshTextState()
    }

    public func acceptCandidate(_ index: Int) {
        let ticket = composer.reserve()
        composer.commit(ticket, [.acceptCandidate(index)])
    }

    // MARK: - Applying intents

    @discardableResult
    func perform(_ intent: KeyboardIntent) -> Bool {
        let interval = Signposts.input.beginInterval("Commit")
        defer { Signposts.input.endInterval("Commit", interval) }

        if intent != .space {
            lastSpaceTime = nil
        }

        let changed: Bool
        var changesText = true
        switch intent {
        case let .insert(character):
            changed = insertCharacter(character, at: nil, time: scheduler.now)
        case let .tapCharacter(character, point, time):
            changed = insertCharacter(character, at: point, time: time)
        case .space:
            closeOpenWord()
            changed = insertSpace()
        case .autoSpace:
            closeOpenWord()
            changed = !(editor.contextBefore?.last?.isWhitespace ?? true)
            if changed { editor.insertSpace() }
        case .returnKey:
            closeOpenWord()
            _ = finishWord(trailing: "")
            editor.insert("\n")
            changed = true
        case .deleteWord:
            closeOpenWord()
            changed = deleteRun(editor.deleteWord())
        case .deleteSentence:
            closeOpenWord()
            changed = deleteRun(editor.deleteSentence())
        case .deleteCharacter:
            closeOpenWord()
            changed = editor.deleteCharacter() != nil
            words.noteCharacterDeleted()
            flow.noteDeletion()
        case .restoreCharacter:
            changed = editor.restoreCharacter()
        case .restoreLastDeletion:
            changed = restoreLastDeletion()
        case .undoRecentCommit:
            changed = undoRecentCommit()
        case let .moveCursor(direction):
            closeOpenWord()
            changed = editor.moveCursor(by: direction)
        case let .moveCursorByWord(direction):
            closeOpenWord()
            changed = editor.moveCursorByWord(direction)
        case let .commitSwipe(readings, unsure, strokes, observations):
            changed = commitSwipe(readings, unsure: unsure, strokes: strokes, observations: observations)
        case let .acceptCandidate(index):
            closeOpenWord()
            changed = acceptCandidate(at: index)
        case .shiftPressBegan:
            if shift.pressBegan(at: scheduler.now, insertionCount: insertionCount) {
                emit(.capsLockEngaged)
            }
            changed = true
            changesText = false
        case .shiftPressEnded:
            shift.pressEnded(at: scheduler.now, insertionCount: insertionCount)
            changed = true
            changesText = false
        case let .switchLayer(target):
            changed = setLayer(target)
            changesText = false
        case .nextKeyboard:
            delegate?.keyboardEngineDidRequestNextKeyboard(self)
            changed = true
            changesText = false
        }

        if changesText, changed {
            shift.noteContextChanged()
        }
        refreshTextState()
        return changed
    }

    private func performBatch(_ intents: [KeyboardIntent]) {
        for intent in intents {
            perform(intent)
        }
    }

    // MARK: - Typing

    private func insertCharacter(_ character: String, at point: CGPoint?, time: Double) -> Bool {
        let text = displayText(for: character)
        if let mark = text.first, text.count == 1, TextBoundary.hoppingPunctuation.contains(mark) {
            closeOpenWord()
            let hadWord = !editor.currentWord.isEmpty
            if !finishWord(trailing: "") {
                editor.insertPunctuation(text, hoppingSpace: settings.smartPunctuationEnabled && traits.variant == .standard)
            } else {
                editor.insert(text)
            }
            if hadWord { completeWord(.tap) }
        } else if text.count == 1, text.first?.isLetter == true, reviseOpenWord(with: text, at: point, time: time) {
            // The letter joined the swiped word already on screen.
        } else {
            editor.insert(text)
            if text.count == 1, text.first?.isLetter == true {
                words.noteLetter(at: point, time: time)
            } else if text.count > 1 {
                words.noteLiteralText()
            }
        }
        insertionCount += 1
        shift.consumeAfterInsertion()
        flow.noteKeystroke()
        return true
    }

    private func insertSpace() -> Bool {
        let now = scheduler.now
        if settings.doubleSpacePeriodEnabled,
           let lastSpaceTime,
           now - lastSpaceTime < Self.doubleSpaceInterval,
           editor.applyDoubleSpacePeriod() {
            self.lastSpaceTime = nil
            emit(.sentenceEnded(at: center(of: .space)))
        } else {
            let hadWord = !editor.currentWord.isEmpty
            if !finishWord(trailing: " ") {
                editor.insertSpace()
            }
            if hadWord { completeWord(.tap) }
            lastSpaceTime = now
        }
        insertionCount += 1
        if layer != .letters {
            setLayer(.letters)
        }
        return true
    }

    /// Ends the current word, autocorrecting it if appropriate. Returns whether a correction
    /// was applied (in which case `trailing` was inserted with it).
    private func finishWord(trailing: String) -> Bool {
        let corrected = words.finishWord(trailing: trailing, autocorrects: autocorrects)
        if corrected {
            emit(.correctionApplied)
            flow.noteCorrection()
        }
        return corrected
    }

    private func completeWord(_ source: KeyboardEvent.WordSource) {
        emit(.wordCommitted(source))
        flow.noteWordCompleted()
    }

    private func commitSwipe(
        _ readings: [String],
        unsure: Bool,
        strokes: Int,
        observations: [StrokeObservation]
    ) -> Bool {
        guard !readings.isEmpty || !observations.isEmpty else { return false }
        let choice = resolvedBeat(readings, unsure: unsure, strokes: strokes, observations: observations)
        let readings = choice.readings
        let unsure = choice.unsure
        let observations = choice.events
        let trailing = choice.trailingTaps
        guard !readings.isEmpty || !observations.isEmpty else { return false }

        let typed = words.placedObservations()
        let committed: Bool
        if !typed.isEmpty {
            let merged = (typed + observations).inReadingOrder()
            if let joined = joinedReading(existing: typed, adding: observations, merged: merged), acceptsJoin(joined) {
                erasePlacedLetters(typed.count)
                committed = publishSwipe(joined, events: merged, strokes: strokes, countsAsNewWord: true)
            } else {
                closeOpenWord()
                _ = finishWord(trailing: " ")
                committed = publishBeat(readings, unsure: unsure, strokes: strokes, observations: observations)
            }
        } else if let open = openWord, editor.recentCommit?.kind == .swiped {
            let displayed = editor.recentCommit?.word ?? ""
            let finished = isFinishedWord(displayed, events: open.events)
            let started = observations.map(\.time).min() ?? scheduler.now
            let merged = (open.events + observations).inReadingOrder()
            let existing = sequenceOutcome(open.events)
            if mayExtend(finished: finished, ownReading: choice.hasOwnReading, at: started),
               let joined = joinedReading(existing: existing, adding: observations, merged: merged),
               acceptsJoin(joined) {
                committed = revise(open, with: joined, batch: observations, strokes: strokes)
            } else {
                // A fragment can still be pulled back by a later letter. A word that is already
                // right cannot: the next beat must not rewrite it.
                if !finished, !choice.hasOwnReading, let word = editor.recentCommit?.word {
                    let events = open.events
                    closeOpenWord()
                    rejoin = Rejoin(events: events, word: word)
                } else {
                    closeOpenWord()
                }
                committed = publishBeat(readings, unsure: unsure, strokes: strokes, observations: observations)
            }
        } else {
            committed = publishBeat(readings, unsure: unsure, strokes: strokes, observations: observations)
        }
        if committed, !trailing.isEmpty {
            closeOpenWord()
            for tap in trailing {
                insertLoose(tap.letter, at: tap.point, time: tap.time)
            }
        }
        return committed
    }

    /// The shape match, or the aimed letters when the beat's taps change which word that is.
    private func resolvedBeat(
        _ readings: [String],
        unsure: Bool,
        strokes: Int,
        observations: [StrokeObservation]
    ) -> (readings: [String], unsure: Bool, events: [StrokeObservation], trailingTaps: [StrokeObservation], hasOwnReading: Bool) {
        let path = DecodeResult(readings: readings.map { DecodeResult.Reading(word: $0, score: 0) })
        let sequence = sequenceOutcome(observations)
        switch BeatChooser.choose(path: path, sequence: sequence, strokes: strokes, observations: observations) {
        case let .path(result):
            return (result.words, unsure, observations, [], !result.words.isEmpty)
        case let .aligned(result):
            return (result.words, result.isUnsure, observations, [], !result.words.isEmpty)
        case let .split(result, taps):
            return (result.words, result.isUnsure, observations.filter { !$0.isTap }, taps, !result.words.isEmpty)
        case .traced:
            let letters = BeatChooser.collapse(sequence.traced)
            return (letters.isEmpty ? [] : [letters], true, observations, [], false)
        }
    }

    private func publishBeat(
        _ readings: [String],
        unsure: Bool,
        strokes: Int,
        observations: [StrokeObservation]
    ) -> Bool {
        let outcome = sequenceOutcome(observations)
        let score = outcome.result.readings.first?.score ?? -6
        let wordsToCommit = readings.isEmpty ? [outcome.traced] : readings
        guard let first = wordsToCommit.first, !first.isEmpty else { return false }
        return publishSwipe(
            DecodeResult(readings: wordsToCommit.map { DecodeResult.Reading(word: $0, score: score) }),
            events: observations,
            strokes: strokes,
            countsAsNewWord: true,
            unsure: unsure
        )
    }

    /// Types a letter that belongs to the next word, without folding it back into the one just committed.
    private func insertLoose(_ letter: String, at point: CGPoint, time: Double) {
        let text = displayText(for: letter)
        editor.insert(text)
        if text.count == 1, text.first?.isLetter == true {
            words.noteLetter(at: point, time: time)
        }
        insertionCount += 1
        shift.consumeAfterInsertion()
        flow.noteKeystroke()
    }

    /// A letter typed while a swiped word is still open. Returns whether it rewrote that word.
    private func reviseOpenWord(with letter: String, at point: CGPoint?, time: Double) -> Bool {
        guard let open = openWord, !open.events.isEmpty, editor.recentCommit?.kind == .swiped else { return false }
        var directionX: CGFloat = 0
        var directionY: CGFloat = 0
        let location = point ?? .zero
        if let previous = open.events.max(by: { $0.time < $1.time }) {
            let rawX = location.x - previous.point.x
            let rawY = location.y - previous.point.y
            let length = hypot(rawX, rawY)
            if length > 1 {
                directionX = rawX / length
                directionY = rawY / length
            }
        }
        let batch = [StrokeObservation(
            time: time,
            point: location,
            directionX: directionX,
            directionY: directionY,
            letter: letter.lowercased(),
            isTap: true
        )]
        let displayed = editor.recentCommit?.word ?? ""
        let finished = isFinishedWord(displayed, events: open.events)
        if !mayExtend(finished: finished, ownReading: false, at: time) {
            closeOpenWord()
            return false
        }
        let merged = (open.events + batch).inReadingOrder()
        let existing = sequenceOutcome(open.events)
        if let joined = joinedReading(existing: existing, adding: batch, merged: merged), acceptsJoin(joined) {
            return revise(open, with: joined, batch: batch, strokes: 0)
        }
        if !finished, reassemble(adding: batch) { return true }
        closeOpenWord()
        return false
    }

    /// Pulls the previous word back in when a letter tapped during this stroke finishes one
    /// word out of both.
    private func reassemble(adding batch: [StrokeObservation]) -> Bool {
        guard let prior = rejoin, let open = openWord, let current = editor.recentCommit, current.kind == .swiped else { return false }
        guard !isKnownWord(current.word) else { return false }
        let started = batch.map(\.time).min() ?? scheduler.now
        guard leashAllows(at: started) else { return false }
        let merged = (prior.events + open.events + batch).inReadingOrder()
        let outcome = sequenceOutcome(merged)
        guard let best = WordJoiner.alignedReading(in: outcome) else { return false }
        guard LexiconKey.make(best.word).count + 1 >= merged.count else { return false }
        let suffix = (prior.word + " " + current.word + " ").lowercased()
        guard editor.contextBefore?.lowercased().hasSuffix(suffix) == true else { return false }
        guard editor.undoRecentCommit() != nil else { return false }
        for _ in 0..<(prior.word.count + 1) {
            guard editor.deleteCharacter() != nil else { return false }
        }
        rejoin = nil
        let result = DecodeResult(readings: [.init(word: best.word, score: best.score)])
        return publishSwipe(result, events: merged, strokes: 0, countsAsNewWord: false)
    }

    private func joinedReading(
        existing typed: [StrokeObservation],
        adding: [StrokeObservation],
        merged: [StrokeObservation]
    ) -> DecodeResult? {
        let outcome = sequenceOutcome(typed)
        return joinedReading(existing: outcome, adding: adding, merged: merged)
    }

    private func joinedReading(
        existing: SequenceOutcome,
        adding: [StrokeObservation],
        merged: [StrokeObservation]
    ) -> DecodeResult? {
        guard words.letterLayout != nil else { return nil }
        let extended = sequenceOutcome(merged)
        return WordJoiner.choose(
            extended: extended,
            alone: sequenceOutcome(adding),
            fragmentContinues: fragmentContinues(existing: existing, extended: extended)
        )
    }

    /// The letters actually hit still begin a longer dictionary word, and that longer word is
    /// more common than stopping at the letters already typed. "wa" continues toward "wait";
    /// "the" does not continue toward "theater".
    private func fragmentContinues(existing: SequenceOutcome, extended: SequenceOutcome) -> Bool {
        guard let lexicon = words.language?.lexicon else { return false }
        let extendedKey = LexiconKey.make(extended.traced)
        let existingKey = LexiconKey.make(existing.traced)
        guard extendedKey.count > existingKey.count, extendedKey.count >= 2 else { return false }
        var existingCount = -Double.infinity
        for index in lexicon.indices(ofKey: existingKey) {
            existingCount = max(existingCount, lexicon.logCount(at: index))
        }
        for index in lexicon.indices(withPrefix: extendedKey) {
            guard lexicon.key(at: index).count > extendedKey.count else { continue }
            if lexicon.logCount(at: index) > existingCount { return true }
        }
        return false
    }

    private func sequenceOutcome(_ observations: [StrokeObservation]) -> SequenceOutcome {
        guard let language = words.language, let layout = words.letterLayout else { return .empty }
        return language.sequenceDecode(observations, layout: layout)
    }

    private func publishSwipe(
        _ result: DecodeResult,
        events: [StrokeObservation],
        strokes: Int,
        countsAsNewWord: Bool,
        unsure: Bool? = nil
    ) -> Bool {
        guard let word = result.readings.first?.word, !word.isEmpty else { return false }
        let cased = result.words.map(applyShift(to:))
        let score = result.readings[0].score
        let tentative = unsure ?? (result.isUnsure || score <= WordJoiner.provisionalScore)
        editor.commitWord(cased[0])
        words.swipeCommitted(cased, unsure: tentative)
        openWord = OpenWord(chunks: [OpenChunk(events: events, readings: cased, score: score)])
        noteWordOpened()
        insertionCount += 1
        shift.consumeAfterInsertion()
        if countsAsNewWord { completeWord(.swipe) }
        if strokes > 0 { emit(.swipeGestureCommitted(strokes: strokes)) }
        return true
    }

    private func revise(_ open: OpenWord, with result: DecodeResult, batch: [StrokeObservation], strokes: Int) -> Bool {
        guard let word = result.readings.first?.word, !word.isEmpty else { return false }
        let cased = result.words.map(applyShift(to:))
        guard editor.replaceRecentCommitWord(with: cased[0]) else { return false }
        let score = result.readings[0].score
        let tentative = result.isUnsure || score <= WordJoiner.provisionalScore
        words.swipeCommitted(cased, unsure: tentative)
        var open = open
        open.chunks.append(OpenChunk(events: batch, readings: cased, score: score))
        openWord = open
        noteWordOpened()
        if strokes > 0 {
            insertionCount += 1
            shift.consumeAfterInsertion()
            emit(.swipeGestureCommitted(strokes: strokes))
        }
        return true
    }

    private func erasePlacedLetters(_ count: Int) {
        for _ in 0..<count {
            guard editor.deleteCharacter() != nil else { break }
            words.noteCharacterDeleted()
        }
    }

    private func closeOpenWord() {
        openWord = nil
        rejoin = nil
        openDeadline = nil
    }

    /// A finished word stays open for a quick tap that lengthens it. It locks when the next
    /// beat is already a word, when that tap is turned off, or when the leash has closed.
    /// A fragment stays open only while the leash is open; a finger still down holds the leash.
    private func mayExtend(finished: Bool, ownReading: Bool, at time: Double) -> Bool {
        guard leashAllows(at: time) else { return false }
        if finished {
            return settings.extendFinishedWords && !ownReading
        }
        return true
    }

    private func leashAllows(at time: Double) -> Bool {
        guard let openDeadline else { return false }
        return time <= openDeadline
    }

    private func noteWordOpened() {
        openDeadline = scheduler.now + Self.wordLeash
    }

    private func isKnownWord(_ word: String) -> Bool {
        words.language?.isKnown(word) == true
    }

    /// A lexicon word the fingers have actually spelled. A completion that runs ahead of the
    /// keys ("priva" shown as "private") stays open so the rest of the word can still arrive.
    /// A shape match that is a different word ("pull" for P–I–L) is finished.
    private func isFinishedWord(_ word: String, events: [StrokeObservation]) -> Bool {
        guard isKnownWord(word) else { return false }
        let traced = BeatChooser.collapse(events.map(\.letter).joined())
        if WordJoiner.aligns(word, traced: traced) { return true }
        let target = LexiconKey.make(word)
        let source = LexiconKey.make(traced)
        if source.count < target.count, Array(target.prefix(source.count)) == source { return false }
        return true
    }

    /// A dictionary word, or the letters of a real prefix while that word is still being typed.
    /// Never the two gestures written out in a row.
    private func acceptsJoin(_ result: DecodeResult) -> Bool {
        guard let reading = result.readings.first, !reading.word.isEmpty else { return false }
        if isKnownWord(reading.word) { return true }
        return reading.score <= WordJoiner.provisionalScore
    }

    private func acceptCandidate(at index: Int) -> Bool {
        guard let acceptance = words.accept(index, from: state.candidates) else { return false }
        switch acceptance {
        case let .keep(word):
            words.keep(word)
            return insertSpace()
        case let .replace(word):
            guard editor.replaceCurrentWord(with: word, kind: .completed) else { return false }
            lastSpaceTime = nil
            completeWord(.suggestion)
            return true
        case let .swap(word):
            if let current = editor.recentCommit?.word {
                words.rememberRejection(preferred: word, rejected: current)
            }
            return editor.replaceRecentCommitWord(with: word)
        case .revert:
            guard let commit = editor.undoRecentCommit() else { return false }
            emit(.correctionReverted)
            words.rememberRejection(preferred: commit.original, rejected: commit.word)
            words.keep(commit.original)
            return insertSpace()
        }
    }

    // MARK: - Deleting

    private func deleteRun(_ removed: String?) -> Bool {
        guard let removed else { return false }
        let visible = removed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty {
            emit(.wordDeleted(visible, origin: center(of: .backspace)))
        }
        flow.noteDeletion()
        return true
    }

    private func restoreLastDeletion() -> Bool {
        guard let restored = editor.restoreLastDeletion() else { return false }
        let visible = restored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty {
            emit(.deletionRestored(visible, origin: center(of: .backspace)))
        }
        return true
    }

    /// Backspace right after a unit commit undoes it: corrections go back to what was typed,
    /// a swiped word disappears in one go.
    private func undoRecentCommit() -> Bool {
        if peelOpenWord() { return true }
        guard let commit = editor.undoRecentCommit() else { return false }
        switch commit.kind {
        case .corrected:
            emit(.correctionReverted)
            words.rememberRejection(preferred: commit.original, rejected: commit.word)
            words.keep(commit.original)
        case .completed:
            words.keep(commit.original)
        case .swiped:
            emit(.wordDeleted(commit.word, origin: center(of: .backspace)))
        }
        flow.noteDeletion()
        return true
    }

    /// Drops the last tap or swipe of an open word and restores the reading from before it.
    private func peelOpenWord() -> Bool {
        guard var open = openWord, open.chunks.count > 1, editor.recentCommit?.kind == .swiped else { return false }
        open.chunks.removeLast()
        guard let chunk = open.chunks.last, let word = chunk.readings.first else { return false }
        guard editor.replaceRecentCommitWord(with: word) else { return false }
        words.swipeCommitted(chunk.readings, unsure: chunk.score <= WordJoiner.provisionalScore)
        openWord = open
        flow.noteDeletion()
        return true
    }

    // MARK: - Modes

    @discardableResult
    private func setLayer(_ target: KeyboardLayer) -> Bool {
        guard target != layer else { return false }
        layer = target
        rebuildGeometry()
        return true
    }

    private func applySettings() {
        flow.celebratesMilestones = settings.effects.celebrateMilestones
        let swipes = settings.typingMode == .swipe && words.language != nil && traits.supportsSwipe
        touchEngine.arbiter.typingMode = swipes ? SwipeTypingMode(coordinator: swipe) : TapTypingMode()
    }

    private func decode(_ gesture: SwipeGesture) async -> DecodeResult {
        guard let language = words.language, let layout = words.letterLayout else { return .empty }
        let path = await language.decode(gesture, layout: layout)
        let sequence = language.sequenceDecode(gesture.observations, layout: layout)
        return BeatChooser.reading(
            path: path,
            sequence: sequence,
            strokes: gesture.strokeCount,
            observations: gesture.observations
        )
    }

    // MARK: - Derived state

    var isReturnKeyEnabled: Bool {
        !traits.enablesReturnKeyAutomatically || !editor.isDocumentEmpty
    }

    private var autocorrects: Bool {
        settings.autocorrectEnabled && traits.supportsLanguageFeatures
    }

    private func applyShift(to word: String) -> String {
        switch shift.state {
        case .off: word
        case .once: word.prefix(1).uppercased() + word.dropFirst()
        case .locked: word.uppercased()
        }
    }

    private func center(of kind: KeyKind) -> CGPoint {
        guard let frame = geometry.keys.first(where: { $0.key.kind == kind }) else {
            return CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        return CGPoint(x: frame.visualFrame.midX, y: frame.visualFrame.midY)
    }

    private func refreshTextState() {
        let context = editor.contextBefore
        lastObservedContext = context
        let shouldCapitalize = settings.autoCapitalizationEnabled
            && TextBoundary.shouldAutoCapitalize(before: context, mode: traits.autocapitalization)
        shift.applyAutomatic(shouldCapitalize)
        publishState()
    }

    private func publishState() {
        let next = KeyboardViewState(
            layer: layer,
            shift: shift.state,
            interaction: touchEngine.interaction,
            returnKey: traits.returnKey,
            isReturnKeyEnabled: isReturnKeyEnabled,
            candidates: words.candidates(
                suggests: settings.suggestionsEnabled && traits.supportsLanguageFeatures,
                autocorrects: autocorrects
            )
        )
        guard next != state else { return }
        state = next
        delegate?.keyboardEngine(self, didUpdateState: next)
    }

    private func rebuildGeometry(size: CGSize? = nil, metrics: KeyboardMetrics? = nil) {
        let interval = Signposts.layout.beginInterval("Rebuild geometry")
        defer { Signposts.layout.endInterval("Rebuild geometry", interval) }

        let layout = LayoutProvider.layout(
            for: layer,
            context: LayoutContext(variant: traits.variant, showsNextKeyboardKey: showsNextKeyboardKey)
        )
        geometry = KeyboardGeometry(
            layout: layout,
            size: size ?? geometry.size,
            metrics: metrics ?? geometry.metrics
        )
        words.updateLayout(for: geometry, layer: layer)
        delegate?.keyboardEngine(self, didUpdateGeometry: geometry)
        publishState()
    }

    private static func initialLayer(for traits: InputTraits) -> KeyboardLayer {
        traits.variant == .numeric ? .numbers : .letters
    }
}

/// The swiped word before the one on screen, in case the next letter belongs to both.
private struct Rejoin {
    var events: [StrokeObservation]
    var word: String
}

/// One thumb action that still belongs to the word on screen, and the reading it produced.
private struct OpenChunk {
    var events: [StrokeObservation]
    var readings: [String]
    var score: Double
}

/// The swiped word that a later tap or swipe can still rewrite.
private struct OpenWord {
    var chunks: [OpenChunk]

    var events: [StrokeObservation] {
        chunks.flatMap(\.events).inReadingOrder()
    }

    var score: Double {
        chunks.last?.score ?? WordJoiner.provisionalScore
    }
}

// MARK: - SessionContext

extension KeyboardEngine: SessionContext {
    var currentLayer: KeyboardLayer { layer }

    var calloutBounds: CGRect {
        let dock = geometry.metrics.dockHeight
        return CGRect(x: 0, y: -dock, width: geometry.size.width, height: geometry.size.height + dock)
    }

    func displayText(for character: String) -> String {
        guard character.count == 1, shift.state != .off else { return character }
        let upper = character.uppercased()
        return upper.count == character.count ? upper : character
    }

    func emit(_ event: KeyboardEvent) {
        delegate?.keyboardEngine(self, didEmit: event)
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        scheduler.schedule(after: delay) { [weak self] in
            action()
            self?.touchEngine.refreshPresentation()
        }
    }
}
