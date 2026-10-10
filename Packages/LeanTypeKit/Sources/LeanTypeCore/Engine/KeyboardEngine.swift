import Foundation

/// Everything the renderer needs besides geometry. Published only when something changes.
public struct KeyboardViewState: Hashable, Sendable {
    public var layer: KeyboardLayer
    public var shift: ShiftState
    public var interaction: InteractionState
    public var returnKey: ReturnKeyKind
    public var isReturnKeyEnabled: Bool
    public var candidates: CandidateState
    public var emojiPage: EmojiCategory
    /// Shown on the space bar when words-per-minute is turned on. Otherwise "space".
    public var spaceTitle: String = "space"
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
    /// Text removed or put back by the latest delete or restore inside `perform`.
    var performedText = ""
    private let scheduler: any Scheduler
    private let shift = ShiftController()
    private let words: WordAssistant
    private var layer: KeyboardLayer
    private var emojiPage = EmojiCategory.smileys
    private var showsNextKeyboardKey: Bool
    private var insertionCount = 0
    private var lastSpaceTime: TimeInterval?
    private var lastObservedContext: String?
    /// The context a caret move just produced, so the host echo is not an outside edit.
    private var ownCursorContext: String?
    /// The next host callback is this keyboard's own edit, when the context still matches.
    private var awaitingOwnEcho = false
    /// True while a caret move is in progress, including a host callback from that move.
    private var movingCursor = false
    /// The latest swiped word, still open to another tap or swipe. Nil once it locks.
    private var openWord: OpenWord?
    /// The swipe chunk the next backspace can unroll.
    private var chunks = ChunkHistory()
    /// A tap-open word just committed, and its trailing space is the delimiter.
    private var suppressNextSpace = false
    /// The first letter of the open word was capitalized by sentence shift, not by the user.
    private var sentenceCapitalOnWord = false
    /// Rolling inter-key interval for this session. Scales evidence tuning.
    private var rhythm = TypingRhythm()
    private var lastReportedLeash = TypingRhythm.coldLeash
    /// Fingers currently on the glass.
    private var liveTouches: Set<TouchID> = []
    /// Fingers that went down on the space bar. They move the caret and do not hold a word open.
    private var spaceTouches: Set<TouchID> = []
    /// Exact text lifted by an upward flick on space, so delete or another flick can put it back.
    private var pickedUpText: String?
    /// The joined spelling, while the field is showing the split, and the reverse.
    private var boundaryAlternate: String?
    /// Holds freshly typed letters until the word is finished or a swipe takes them.
    private var composingTimer: (any Cancellable)?
    /// The polyline of the swipe just committed, so picking another word can remember it.
    private var recentStrokePath: [CGPoint] = []
    /// Paste, copy, and cut. The pasteboard string is read only inside the paste handler.
    public var onClipboard: ((ClipboardCommand) -> Void)?

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
        let matcher = AlignmentPathMatcher { [weak self] gesture in
            await self?.decode(gesture) ?? .empty
        }
        let coordinator = SwipeCoordinator(composer: composer, matcher: matcher)
        coordinator.onPreview = { [weak self] result in
            guard let self else { return }
            if let result {
                composingTimer?.cancel()
                if words.showPreview(result) {
                    emit(.swipePreviewChanged)
                }
                if !editor.preservesPreviewEdits, let word = words.previewLeader {
                    editor.setPreviewComposing(applyShift(to: word))
                }
            } else {
                words.clearPreview()
                editor.clearPreviewComposing()
                scheduleComposingFlush()
            }
            publishState()
        }
        coordinator.onFinish = { [weak self] in self?.touchEngine.refreshPresentation() }
        coordinator.onCarryTaps = { [weak self] in
            guard let self else { return [] }
            let draft = editor.typedComposing
            let observations = words.placedObservations().map { observation in
                var observation = observation
                observation.isTap = true
                return observation
            }
            chunks.rememberDraft(draft)
            editor.setTypedComposing("")
            return observations
        }
        coordinator.onStrokePulse = { [weak self] in
            self?.emit(.strokePulse)
        }
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
        language?.recordsGestureTraces = settings.recordsGestureTraces
        self.scheduler = scheduler ?? MainQueueScheduler()
        self.settings = settings
        self.traits = traits
        self.showsNextKeyboardKey = showsNextKeyboardKey

        let layer = Self.initialLayer(for: traits)
        self.layer = layer
        let layout = LayoutProvider.layout(
            for: layer,
            context: LayoutContext(variant: traits.variant, showsNextKeyboardKey: showsNextKeyboardKey, emojiPage: emojiPage)
        )
        geometry = KeyboardGeometry(layout: layout, size: .zero, metrics: metrics)
        state = KeyboardViewState(
            layer: layer,
            shift: .off,
            interaction: .idle,
            returnKey: traits.returnKey,
            isReturnKeyEnabled: true,
            candidates: .empty,
            emojiPage: emojiPage
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
        if geometry.size != .zero, swipe.hasLetterFingerDown || swipe.isCollecting {
            cancelAllTouches()
            flushTypedComposing()
        }
        rebuildGeometry(size: size, metrics: metrics)
    }

    public func setShowsNextKeyboardKey(_ shows: Bool) {
        guard shows != showsNextKeyboardKey else { return }
        showsNextKeyboardKey = shows
        rebuildGeometry()
    }

    public func update(settings: KeyboardSettings) {
        guard settings != self.settings else { return }
        let placementChanged = settings.placement != self.settings.placement
        self.settings = settings
        applySettings()
        if placementChanged { rebuildGeometry() }
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
        let echoed = awaitingOwnEcho && context == lastObservedContext
        if movingCursor || context == ownCursorContext || echoed
            || Self.isOwnEcho(previous: lastObservedContext, current: context, inserted: editor.recentCommit?.inserted) {
            if !movingCursor { ownCursorContext = nil }
            awaitingOwnEcho = false
            refreshTextState()
            return
        }
        awaitingOwnEcho = false
        ownCursorContext = nil
        _ = restorePickedUpWord()
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
        let committed = swipe.finishNow()
        if !committed {
            swipe.reset()
            composer.reset()
        }
        shift.reset()
        flow.reset()
        lastSpaceTime = nil
        openWord = nil
        pickedUpText = nil
        words.clearPickedUp()
        liveTouches = []
        spaceTouches = []
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
                if geometry.key(at: sample.location)?.key.kind == .space {
                    spaceTouches.insert(sample.id)
                }
            case .ended, .cancelled:
                liveTouches.remove(sample.id)
                spaceTouches.remove(sample.id)
            case .moved:
                break
            }
        }
        touchEngine.handle(samples)
        Signposts.input.endInterval("Touch batch", interval)
    }

    public func cancelAllTouches() {
        touchEngine.cancelAll()
        let committed = swipe.finishNow()
        if !committed {
            swipe.reset()
            composer.reset()
        }
        liveTouches = []
        spaceTouches = []
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
        case .emoji:
            perform(.switchLayer(.emoji))
        case let .emojiCategory(page):
            perform(.showEmojiPage(page))
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
        words.restoreConcealed(word)
        DarwinNotifications.post(SharedContainer.learnedWordsDidChangeNotification)
        refreshTextState()
    }

    /// Drops one learned word. The rest of the list stays.
    public func forgetWord(_ word: String) {
        guard language?.forget(word) == true else { return }
        words.dropKept(word)
        words.conceal(word)
        DarwinNotifications.post(SharedContainer.learnedWordsDidChangeNotification)
        refreshTextState()
    }

    /// Keeps `word` out of suggestions until it is remembered or restored.
    public func banWord(_ word: String) {
        guard language?.ban(word) == true else { return }
        words.conceal(word)
        DarwinNotifications.post(SharedContainer.learnedWordsDidChangeNotification)
        refreshTextState()
    }

    public func moreOften(_ word: String) {
        language?.moreOften(word)
        words.nudgeChip(word, forward: true)
        refreshTextState()
    }

    public func lessOften(_ word: String) {
        language?.lessOften(word)
        words.nudgeChip(word, forward: false)
        refreshTextState()
    }

    public func historyMenu(for chip: Int) -> [HistoryMenuRow] {
        words.menuRows(for: chip, in: state.candidates)
    }

    /// A hold-menu row or a gap double-tap.
    public func performStripAction(_ action: Candidate.StripAction) {
        closeOpenWord()
        _ = performStrip(action, text: "")
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
        performedText = ""

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
            if suppressNextSpace {
                suppressNextSpace = false
                changed = true
            } else if swipe.session.phase == .tapOpen, finishBeat(then: []) {
                // commitWord already types the trailing space.
                changed = true
            } else {
                closeOpenWord()
                consumePickedUpWord()
                changed = insertSpace()
            }
        case .pickUpWord:
            closeOpenWord()
            changed = togglePickUp()
        case .autoSpace:
            closeOpenWord()
            changed = !(editor.contextBefore?.last?.isWhitespace ?? true)
            if changed { editor.insertSpace() }
        case .returnKey:
            if attachSuffixDraftIfNeeded() {
                closeOpenWord()
                consumePickedUpWord()
                editor.insert("\n")
                words.noteSentenceEnded()
                if let frame = visualFrame(of: .returnKey) {
                    emit(.returnSent(traits.returnKey.title, from: frame))
                }
            } else if !finishBeat(then: [.returnKey]) {
                closeOpenWord()
                consumePickedUpWord()
                _ = finishWord(trailing: "")
                editor.insert("\n")
                words.noteSentenceEnded()
                if let frame = visualFrame(of: .returnKey) {
                    emit(.returnSent(traits.returnKey.title, from: frame))
                }
            }
            changed = true
        case .deleteWord:
            closeOpenWord()
            changed = deleteRun(editor.deleteWord())
        case .deleteSentence:
            closeOpenWord()
            changed = deleteRun(editor.deleteSentence())
        case .deleteCharacter:
            if swipe.dropLatestObservation() {
                changed = true
                break
            }
            closeOpenWord()
            if let text = editor.deleteCharacter() {
                performedText = text
                changed = true
                words.noteCharacterDeleted()
                flow.noteDeletion()
            } else {
                changed = false
            }
        case .restoreCharacter:
            if let text = editor.restoreCharacter() {
                performedText = text
                changed = true
            } else {
                changed = false
            }
        case .restoreLastDeletion:
            changed = restoreLastDeletion()
        case .undoRecentCommit:
            if !editor.typedComposing.isEmpty {
                changed = false
            } else if let draft = chunks.tapDraft {
                swipe.discardHeldStroke()
                editor.clearPreviewComposing()
                editor.setTypedComposing(draft)
                chunks.clear()
                changed = true
            } else if chunks.restoreAfterCommit == nil,
                      let literal = words.aimedLiteral,
                      let commit = editor.recentCommit,
                      commit.kind == .swiped,
                      literal.compare(commit.word, options: .caseInsensitive) != .orderedSame,
                      editor.reopenMatchedSuffix(commit.inserted, as: literal) {
                chunks.clear()
                changed = true
            } else {
                let restore = chunks.restoreAfterCommit
                changed = undoRecentCommit()
                if changed, let restore, !restore.isEmpty {
                    editor.setTypedComposing(restore)
                }
                chunks.clear()
            }
        case let .moveCursor(direction):
            closeOpenWord()
            movingCursor = true
            changed = editor.moveCursor(by: direction)
            movingCursor = false
            if changed { ownCursorContext = editor.contextBefore }
        case let .moveCursorByWord(direction):
            closeOpenWord()
            movingCursor = true
            changed = editor.moveCursorByWord(direction)
            movingCursor = false
            if changed { ownCursorContext = editor.contextBefore }
        case let .commitSwipe(readings, unsure, strokes, observations, strokePaths):
            changed = commitSwipe(readings, unsure: unsure, strokes: strokes, observations: observations, strokePaths: strokePaths)
        case let .acceptCandidate(index):
            if words.isPreviewing {
                changed = words.promotePreview(at: index)
                changesText = false
            } else {
                closeOpenWord()
                let effect = acceptCandidate(at: index)
                changed = effect.changed
                changesText = effect.changesText
            }
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
        case .shiftPressCancelled:
            shift.cancelPress()
            changed = true
            changesText = false
        case let .switchLayer(target):
            changed = setLayer(target)
            changesText = false
        case let .showEmojiPage(page):
            changed = showEmojiPage(page)
            changesText = false
        case .nextKeyboard:
            delegate?.keyboardEngineDidRequestNextKeyboard(self)
            changed = true
            changesText = false
        }

        if changesText, changed {
            shift.noteContextChanged()
            awaitingOwnEcho = true
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
        consumePickedUpWord()
        let text = displayText(for: character)
        if EmojiCatalog.contains(text) {
            closeOpenWord()
            flushTypedComposing()
            let hadWord = !editor.currentWord.isEmpty
            if hadWord, !finishWord(trailing: " ") {
                editor.insertSpace()
            }
            editor.insert(text)
            if hadWord { completeWord(.tap) }
        } else if let mark = text.first, text.count == 1, TextBoundary.hoppingPunctuation.contains(mark) {
            if finishBeat(then: [.insert(text)]) { return true }
            if attachSuffixDraftIfNeeded() {
                closeOpenWord()
                let smart = settings.smartPunctuationEnabled && traits.variant == .standard
                editor.insertPunctuation(text, hoppingSpace: smart)
                if smart, editor.contextBefore?.last?.isWhitespace != true {
                    editor.insertSpace()
                }
                completeWord(.tap)
                noteSentenceBoundary(in: text)
                insertionCount += 1
                shift.consumeAfterInsertion()
                flow.noteKeystroke()
                return true
            }
            closeOpenWord()
            flushTypedComposing()
            let hadWord = !editor.currentWord.isEmpty
            let smart = settings.smartPunctuationEnabled && traits.variant == .standard
            if !finishWord(trailing: "") {
                editor.insertPunctuation(text, hoppingSpace: smart)
            } else {
                editor.insert(text)
            }
            // After a word, the mark takes a space of its own so the next letter can capitalize.
            // A mark that already hopped over a keyboard space ends in that space.
            if smart, hadWord, editor.contextBefore?.last?.isWhitespace != true {
                editor.insertSpace()
            }
            if hadWord { completeWord(.tap) }
            noteSentenceBoundary(in: text)
        } else if text.count == 1, text.first?.isLetter == true {
            if editor.isEditingPreview || editor.caretIsMidTypedMark {
                editor.insertIntoActiveMark(text)
            } else if editor.typedComposing.isEmpty, TextBoundary.continuesWord(after: editor.contextAfter) {
                editor.insert(text)
            } else {
                holdLetter(text, at: point, time: time)
            }
        } else {
            flushTypedComposing()
            editor.insert(text)
            if text.count > 1 {
                words.noteLiteralText()
            }
            noteSentenceBoundary(in: text)
        }
        insertionCount += 1
        shift.consumeAfterInsertion()
        flow.noteKeystroke()
        return true
    }

    /// Keeps `letter` with the word being typed. A pause commits it; a swipe takes it instead.
    private func holdLetter(_ letter: String, at point: CGPoint?, time: Double) {
        if editor.currentWord.isEmpty, shift.isSentenceCapital {
            sentenceCapitalOnWord = true
        }
        editor.appendTypedComposing(letter)
        words.noteLetter(at: point, time: time)
        scheduleComposingFlush()
    }

    private func flushTypedComposing() {
        composingTimer?.cancel()
        composingTimer = nil
        editor.flushTypedComposing()
    }

    private func scheduleComposingFlush() {
        if swipe.session.phase == .tapOpen {
            composingTimer?.cancel()
            composingTimer = nil
            return
        }
        composingTimer?.cancel()
        composingTimer = scheduler.schedule(after: activeLeash) { [weak self] in
            guard let self else { return }
            if self.swipe.hasLetterFingerDown {
                self.scheduleComposingFlush()
                return
            }
            self.flushTypedComposing()
        }
    }

    /// Commits the open beat before `intents`. Returns false when no beat is waiting.
    private func finishBeat(then intents: [KeyboardIntent]) -> Bool {
        swipe.finishNow(then: intents)
    }

    /// A preview or a commit decode is still running.
    var hasSwipeWorkInFlight: Bool { swipe.isDecoding || swipe.isPreviewing }

    /// The open word is waiting for a delimiter, not for a decode.
    var isTapOpen: Bool { swipe.session.phase == .tapOpen }

    /// Used by tests so a one-finger swipe still commits without waiting out the leash.
    /// A tap-open word stays open; only a delimiter closes it.
    func releaseHeldBeat() {
        guard swipe.session.phase != .tapOpen else { return }
        _ = finishBeat(then: [])
    }

    /// A tap-open draft that is exactly a known suffix replaces the swiped word it follows.
    private func attachSuffixDraftIfNeeded() -> Bool {
        let draft = editor.typedComposing
        guard !draft.isEmpty,
              let commit = editor.recentCommit,
              commit.kind == .swiped,
              let language,
              let joined = InflectionJoiner.joined(previous: commit.word, draft: draft, isKnown: { language.isKnown($0) })
        else { return false }
        let shown = InflectionJoiner.matchingCase(joined, like: commit.word)
        composingTimer?.cancel()
        composingTimer = nil
        editor.setTypedComposing("")
        guard editor.replaceRecentCommitWord(with: shown) else {
            editor.setTypedComposing(draft)
            return false
        }
        swipe.session.seal()
        closeOpenWord()
        chunks.clear()
        return true
    }

    private func insertSpace() -> Bool {
        if attachSuffixDraftIfNeeded() { return true }
        composingTimer?.cancel()
        composingTimer = nil
        editor.commitActiveMark()
        let now = scheduler.now
        if settings.doubleSpacePeriodEnabled,
           let lastSpaceTime,
           now - lastSpaceTime < Self.doubleSpaceInterval,
           editor.applyDoubleSpacePeriod() {
            self.lastSpaceTime = nil
            words.noteSentenceEnded()
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

    /// A sentence mark forgets the words just written. The pairs already learned stay.
    private func noteSentenceBoundary(in text: String) {
        guard text.count == 1, let mark = text.first, TextBoundary.endsSentence(mark) else { return }
        words.noteSentenceEnded()
    }

    /// Ends the current word, autocorrecting it if appropriate. Returns whether a correction
    /// was applied (in which case `trailing` was inserted with it).
    private func finishWord(trailing: String) -> Bool {
        let typed = String(editor.currentWord)
        let corrected = words.finishWord(
            trailing: trailing,
            autocorrects: autocorrects,
            display: displayToRemember(typed)
        )
        if corrected {
            emit(.correctionApplied)
            flow.noteCorrection()
        }
        return corrected
    }

    private func completeWord(_ source: KeyboardEvent.WordSource) {
        sentenceCapitalOnWord = false
        emit(.wordCommitted(source))
        flow.noteWordCompleted()
    }

    private func commitSwipe(
        _ readings: [String],
        unsure: Bool,
        strokes: Int,
        observations: [StrokeObservation],
        strokePaths: [[CGPoint]]
    ) -> Bool {
        consumePickedUpWord()
        guard !readings.isEmpty || !observations.isEmpty else { return false }
        recentStrokePath = strokePaths.max { $0.count < $1.count } ?? []
        let committed = publishBeat(readings, unsure: unsure, strokes: strokes, observations: observations, paths: strokePaths)
        if committed {
            chunks.noteCommitted()
            closeOpenWord()
        }
        return committed
    }

    /// The shape match, or the aimed letters when the beat's taps change which word that is.
    private func publishBeat(
        _ readings: [String],
        unsure: Bool,
        strokes: Int,
        observations: [StrokeObservation],
        paths: [[CGPoint]] = []
    ) -> Bool {
        let outcome = sequenceOutcome(observations, strokePaths: paths)
        let score = outcome.result.readings.first?.score ?? -6
        let wordsToCommit = readings.isEmpty ? [outcome.traced] : readings
        guard let first = wordsToCommit.first, !first.isEmpty else { return false }
        return publishSwipe(
            DecodeResult(readings: wordsToCommit.map { DecodeResult.Reading(word: $0, score: score) }),
            events: observations,
            strokes: strokes,
            countsAsNewWord: true,
            unsure: unsure,
            paths: paths
        )
    }

    /// Types a letter that belongs to the next word, without folding it back into the one just committed.
    private func sequenceOutcome(_ observations: [StrokeObservation], strokePaths: [[CGPoint]] = []) -> SequenceOutcome {
        guard let language = words.language, let layout = words.letterLayout else { return .empty }
        return language.sequenceDecode(observations, layout: layout, strokePaths: strokePaths)
    }

    private func publishSwipe(
        _ result: DecodeResult,
        events: [StrokeObservation],
        strokes: Int,
        countsAsNewWord: Bool,
        unsure: Bool? = nil,
        priorChunks: [OpenBeat] = [],
        paths: [[CGPoint]] = []
    ) -> Bool {
        let edited = editor.consumeEditedPreview()
        if edited == nil {
            guard let word = result.readings.first?.word, !word.isEmpty else { return false }
        }
        editor.clearPreviewComposing()
        if let edited, edited.isEmpty { return false }
        let cased = edited.map { [$0] } ?? result.words.map(applyShift(to:))
        let score = result.readings.first?.score ?? 0
        let margin = words.language?.trust.unsureMargin ?? DecodeResult.confidenceMargin
        let close = result.readings.count >= 2 && result.readings[0].score - result.readings[1].score < margin
        let tentative = unsure ?? (close || score <= WordJoiner.provisionalScore)
        editor.commitWord(cased[0])
        if let layout = words.letterLayout {
            let accepted = priorChunks.flatMap(\.events) + events
            TouchOffsetLog.record(letters: accepted.map(\.letter), points: accepted.map(\.point), layout: layout)
        }
        noteRhythm(priorChunks.flatMap(\.events) + events)
        let literal = BeatChooser.collapse((priorChunks.flatMap(\.events) + events).map(\.letter).joined())
        words.swipeCommitted(
            cased,
            unsure: tentative,
            literal: literal,
            advancesRefusalClock: countsAsNewWord,
            display: displayToRemember(cased[0]),
            scores: result.readings.map(\.score)
        )
        words.language?.noteGesture(aimed: literal, path: recentStrokePath, chosen: cased[0])
        words.language?.trust.note(overridden: false, at: scheduler.now)
        words.suppressAhead = false
        emit(.commitFelt(sure: !tentative))
        if settings.effects.spectacle {
            let kept = (priorChunks.flatMap(\.events) + events).map(\.letter)
            emit(.spectacleLetters(kept))
        }
        if let layout = words.letterLayout, recentStrokePath.count >= 2 {
            words.language?.rememberFrequentStroke(cased[0], path: recentStrokePath, layout: layout)
        }
        var chunks = priorChunks
        chunks.append(OpenBeat(events: events, paths: paths, readings: cased, score: score))
        openWord = OpenWord(chunks: chunks)
        refreshEvidenceTuning()
        insertionCount += 1
        shift.consumeAfterInsertion()
        if countsAsNewWord { completeWord(.swipe) }
        if strokes > 0 { emit(.swipeGestureCommitted(strokes: strokes)) }
        return true
    }

    private func closeOpenWord() {
        openWord = nil
    }

    /// Dwell and retreat follow the current key pitch. Time thresholds stay on the rhythm.
    private func refreshEvidenceTuning() {
        let layout = LetterLayout(geometry: geometry)
        let pitch = layout?.keyWidth ?? StrokeBuffer.referenceKeyWidth
        swipe.evidenceTuning = rhythm.evidenceTuning.scaled(to: pitch)
        swipe.touchBias = TouchBias.load()
        swipe.biasKeyHeight = layout?.keyHeight ?? pitch
    }

    private func acceptCandidate(at index: Int) -> (changed: Bool, changesText: Bool) {
        guard let acceptance = words.accept(index, from: state.candidates) else { return (false, true) }
        switch acceptance {
        case let .keep(word):
            words.acceptLiteral(word)
            return (insertSpace(), true)
        case let .replace(word):
            guard editor.replaceCurrentWord(with: word, kind: .completed) else { return (false, true) }
            words.noteSettled(word)
            lastSpaceTime = nil
            completeWord(.suggestion)
            return (true, true)
        case let .insert(word):
            consumePickedUpWord()
            editor.insert(word)
            return (true, true)
        case let .follow(word):
            let shown = applyShift(to: word)
            let before = editor.contextBefore ?? ""
            let lead = before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\n") ? "" : " "
            editor.insert(lead + shown + " ")
            words.language?.noteCommitted(shown)
            return (true, true)
        case let .swap(word):
            words.noteSwap(preferred: word, rejected: editor.recentCommit?.word)
            words.language?.trust.note(overridden: true, at: scheduler.now)
            if let kind = words.language.flatMap({ _ in
                AlternativeClassifier.kind(of: word, comparedWith: editor.recentCommit?.word ?? "", aimed: "")
            }) {
                words.language?.alternativeBias.note(kind)
            }
            if let layout = words.letterLayout, recentStrokePath.count >= 2 {
                words.rememberStroke(word, path: recentStrokePath, layout: layout)
            }
            return (editor.replaceRecentCommitWord(with: word), true)
        case .revert:
            guard let commit = editor.undoRecentCommit() else { return (false, true) }
            emit(.correctionReverted)
            words.noteAutocorrectRevert(preferred: commit.original, rejected: commit.word)
            return (insertSpace(), true)
        case .settle:
            return (true, false)
        case .refresh:
            return (true, false)
        case let .command(action, text):
            return performStrip(action, text: text)
        }
    }

    private func performStrip(_ action: Candidate.StripAction, text: String) -> (changed: Bool, changesText: Bool) {
        switch action {
        case .insertText:
            editor.insert(text)
            words.rememberEmoji(text)
            emit(.chipChosen)
            return (true, true)
        case let .replaceSuffix(match, replacement):
            let started = scheduler.now
            let changed = editor.replaceMatchedSuffix(match, with: replacement)
            _ = HistoryEditLog.record(elapsed: max(0, scheduler.now - started))
            emit(.chipChosen)
            return (changed, true)
        case .toggleBoundary:
            let changedBoundary = toggleLastBoundary()
            emit(.chipChosen)
            return (changedBoundary, changedBoundary)
        case let .clipboard(command):
            onClipboard?(command)
            emit(.chipChosen)
            return (command == .cut || command == .paste, command == .cut || command == .paste)
        default:
            let started = scheduler.now
            let path = openWord == nil ? nil : recentStrokePath
            _ = words.perform(action, started: started, now: { [scheduler] in scheduler.now }, strokePath: path)
            emit(.chipChosen)
            let editsText: Bool = switch action {
            case .replaceHistory, .replaceDocumentWord, .retype, .merge, .capitalize, .undoEdit:
                true
            default:
                false
            }
            return (true, editsText)
        }
    }

    // MARK: - Deleting

    private func deleteRun(_ removed: String?) -> Bool {
        guard let removed else { return false }
        performedText = removed
        let visible = removed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty {
            emit(.wordDeleted(visible, origin: center(of: .backspace)))
        }
        flow.noteDeletion()
        return true
    }

    private func restoreLastDeletion() -> Bool {
        guard let restored = editor.restoreLastDeletion() else { return false }
        performedText = restored
        let visible = restored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty {
            words.noteSwipedWordRestored(visible)
            emit(.deletionRestored(visible, origin: center(of: .backspace)))
        }
        return true
    }

    /// Backspace right after a unit commit undoes it: corrections go back to what was typed,
    /// a swiped word disappears in one go.
    private func undoRecentCommit() -> Bool {
        if restorePickedUpWord() { return true }
        if peelOpenWord() { return true }
        let rejectedChips = words.shownSwipeChips()
        let rejectedTrace = words.aimedLiteral ?? editor.recentCommit?.word ?? ""
        guard let commit = editor.undoRecentCommit() else { return false }
        switch commit.kind {
        case .corrected:
            emit(.correctionReverted)
            words.noteAutocorrectRevert(preferred: commit.original, rejected: commit.word)
        case .completed:
            words.keep(commit.original)
        case .swiped:
            words.noteWholeWordRejected(chips: rejectedChips, trace: rejectedTrace, word: commit.word)
            emit(.wordDeleted(commit.word, origin: center(of: .backspace)))
        }
        flow.noteDeletion()
        return true
    }

    /// Lifts the word at the cursor, or puts a lifted word back when one is already held.
    private func togglePickUp() -> Bool {
        if pickedUpText != nil { return restorePickedUpWord() }
        guard let pickup = editor.pickUpWordTouchingCursor() else { return false }
        pickedUpText = pickup.removed
        words.notePickedUp(pickup.word)
        return true
    }

    /// Puts the lifted word back where the cursor is and forgets it.
    @discardableResult
    private func restorePickedUpWord() -> Bool {
        guard let text = pickedUpText else { return false }
        pickedUpText = nil
        words.clearPickedUp()
        editor.insert(text)
        return true
    }

    /// The next typing stands in for the lifted word, so delete no longer brings it back.
    private func consumePickedUpWord() {
        guard pickedUpText != nil else { return }
        pickedUpText = nil
        words.clearPickedUp()
    }

    /// Splits a joined word into the chunk before the last one, or joins that split back.
    private func toggleLastBoundary() -> Bool {
        guard let commit = editor.recentCommit, commit.kind == .swiped else { return false }
        if let alternate = boundaryAlternate {
            guard editor.replaceRecentCommitWord(with: alternate) else { return false }
            boundaryAlternate = commit.word
            return true
        }
        guard var open = openWord, open.chunks.count > 1 else { return false }
        let tail = open.chunks.removeLast()
        let headEvents = open.chunks.flatMap(\.events)
        let outcome = sequenceOutcome(headEvents, strokePaths: open.paths)
        let head = outcome.result.readings.first?.word ?? open.chunks.last?.readings.first ?? ""
        let tailWord = tail.readings.first ?? BeatChooser.collapse(tail.events.map(\.letter).joined())
        guard !head.isEmpty, !tailWord.isEmpty else { return false }
        guard editor.replaceRecentCommitWord(with: head + " " + tailWord) else { return false }
        boundaryAlternate = commit.word
        openWord = open
        return true
    }

    /// Drops the last tap or swipe of an open word and restores the reading from before it.
    private func peelOpenWord() -> Bool {
        guard var open = openWord, open.chunks.count > 1, editor.recentCommit?.kind == .swiped else { return false }
        open.chunks.removeLast()
        guard let chunk = open.chunks.last, let word = chunk.readings.first else { return false }
        let remaining = open.chunks.flatMap(\.events)
        let outcome = sequenceOutcome(remaining, strokePaths: open.paths)
        let decoded = outcome.result.readings.first?.word ?? word
        guard editor.replaceRecentCommitWord(with: decoded) else { return false }
        words.suppressAhead = true
        let literal = BeatChooser.collapse(remaining.map(\.letter).joined())
        let readings = outcome.result.readings.map(\.word)
        words.swipeCommitted(readings.isEmpty ? chunk.readings : readings, unsure: true, literal: literal)
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

    /// Shows another emoji page. Opens the emoji keyboard if it isn't already up.
    private func showEmojiPage(_ page: EmojiCategory) -> Bool {
        let opens = layer != .emoji
        guard page != emojiPage || opens else { return false }
        emojiPage = page
        layer = .emoji
        rebuildGeometry()
        return true
    }

    private func applySettings() {
        words.language?.recordsGestureTraces = settings.recordsGestureTraces
        flow.celebratesMilestones = settings.effects.celebrateMilestones
        let swipes = settings.typingMode == .swipe && words.language != nil && traits.supportsSwipe
        touchEngine.arbiter.typingMode = swipes ? SwipeTypingMode(coordinator: swipe) : TapTypingMode()
    }

    private func noteRhythm(_ events: [StrokeObservation]) {
        let times = events.map(\.time).sorted()
        for (previous, next) in zip(times, times.dropFirst()) {
            rhythm.note(gap: next - previous)
        }
        refreshEvidenceTuning()
        let recommended = rhythm.leash
        if abs(recommended - lastReportedLeash) > 0.01 {
            lastReportedLeash = recommended
            SharedContainer.saveRecommendedLeash(recommended)
        }
    }

    /// A chosen join window stays inside 0.2–0.8 seconds. Pace follows the rhythm, which stays inside 0.16–0.55.
    var activeLeash: TimeInterval {
        guard let manual = settings.leashDuration else { return rhythm.leash }
        return min(0.8, max(0.2, manual))
    }

    private func decode(_ gesture: SwipeGesture) async -> DecodeResult {
        guard let language = words.language, let layout = words.letterLayout else { return .empty }
        let result = await language.align(gesture, layout: layout, costs: rhythm.costs)
        let preferred = words.placingChoice(on: result)
        return ContractionPreference.apply(preferred, prefersContraction: gesture.prefersContraction)
    }

    // MARK: - Derived state

    var isReturnKeyEnabled: Bool {
        !traits.enablesReturnKeyAutomatically || !editor.isDocumentEmpty
    }

    private var autocorrects: Bool {
        settings.autocorrectEnabled && traits.supportsLanguageFeatures
    }

    private func applyShift(to word: String) -> String {
        if let language = words.language {
            return language.presenting(word, shift: shift.state)
        }
        switch shift.state {
        case .off: return word
        case .once: return word.prefix(1).uppercased() + word.dropFirst()
        case .locked: return word.uppercased()
        }
    }

    /// A capital past the first letter is the user's. A leading capital is theirs only when
    /// sentence shift did not add it. Caps lock is not a spelling to store.
    private func displayToRemember(_ word: String) -> String? {
        guard shift.state != .locked else { return nil }
        if word.dropFirst().contains(where: \.isUppercase) { return word }
        guard word.first?.isUppercase == true else { return nil }
        if shift.isSentenceCapital || sentenceCapitalOnWord { return nil }
        return word
    }

    private func visualFrame(of kind: KeyKind) -> CGRect? {
        geometry.keys.first { $0.key.kind == kind }?.visualFrame
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

    private var spaceTitle: String {
        guard settings.showsWordsPerMinute, let pace = rhythm.wordsPerMinute else { return "space" }
        return "\(pace)"
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
                autocorrects: autocorrects,
                variant: traits.variant,
                blocksHistory: traits.blocksLexicalEntry
            ),
            emojiPage: emojiPage,
            spaceTitle: spaceTitle
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
            context: LayoutContext(
                variant: traits.variant,
                showsNextKeyboardKey: showsNextKeyboardKey,
                emojiPage: emojiPage
            )
        )
        geometry = KeyboardGeometry(
            layout: layout,
            size: size ?? geometry.size,
            metrics: metrics ?? geometry.metrics
        ).applying(settings.placement)
        words.updateLayout(for: geometry, layer: layer)
        refreshEvidenceTuning()
        delegate?.keyboardEngine(self, didUpdateGeometry: geometry)
        publishState()
    }

    private static func initialLayer(for traits: InputTraits) -> KeyboardLayer {
        traits.variant == .numeric ? .numbers : .letters
    }
}

/// One thumb action that still belongs to the word on screen: the keys, and the curve that hit them.
private struct OpenBeat {
    static let pointCap = 48

    var events: [StrokeObservation]
    var paths: [[CGPoint]]
    var readings: [String]
    var score: Double

    init(events: [StrokeObservation], paths: [[CGPoint]] = [], readings: [String], score: Double) {
        self.events = events
        self.paths = paths.map(Self.capped)
        self.readings = readings
        self.score = score
    }

    static func capped(_ path: [CGPoint]) -> [CGPoint] {
        guard path.count > pointCap else { return path }
        let step = max(1, Int((Double(path.count) / Double(pointCap)).rounded(.up)))
        var kept: [CGPoint] = []
        kept.reserveCapacity(pointCap)
        for index in stride(from: 0, to: path.count, by: step) {
            kept.append(path[index])
        }
        if let last = path.last, kept.last != last { kept.append(last) }
        return kept
    }
}

/// The swiped word that a later tap or swipe can still rewrite.
private struct OpenWord {
    var chunks: [OpenBeat]

    var events: [StrokeObservation] {
        chunks.flatMap(\.events).inReadingOrder()
    }

    var paths: [[CGPoint]] {
        chunks.flatMap(\.paths)
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

    func commitTapOpenWord() -> Bool {
        guard swipe.session.phase == .tapOpen else { return false }
        return finishBeat(then: [])
    }

    func suppressDelimiterSpace() {
        suppressNextSpace = true
    }

    var isInsideComposingWord: Bool {
        switch swipe.session.phase {
        case .tapOpen, .swipeOpen: true
        case .contact, .idle: composingTimer != nil
        }
    }

    var caretIsInsideWord: Bool {
        !editor.currentWord.isEmpty && TextBoundary.continuesWord(after: editor.contextAfter)
    }

    var caretIsInsideMark: Bool { editor.caretIsInsideMark }

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
