import CoreGraphics
import Foundation

/// The engine's word-level helper: remembers where each letter of the current word was
/// touched, decides on autocorrect when a word ends, learns words, and builds the suggestion
/// strip. Owns no text; it reads and edits through the shared `TextEditor`.
@MainActor
final class WordAssistant {
    /// What accepting a suggestion means for the text.
    enum Acceptance: Equatable {
        /// Keep the typed word as is (and stop autocorrecting it).
        case keep(String)
        /// Replace the typed word.
        case replace(String)
        /// Swap the word just swiped for another reading.
        case swap(String)
        /// Put back the word autocorrect replaced.
        case revert
        /// Type a word that was lifted off the page.
        case insert(String)
        /// Type the suggested next word, with a space after it.
        case follow(String)
        /// The landed word was confirmed. The document stays as it is.
        case settle
        /// The bar changed and the document did not: a drill, a hint, a learned chip.
        case refresh
        /// Run a history or field action. `text` is the chip label, used when the action inserts it.
        case command(Candidate.StripAction, text: String)
    }

    var language: LanguageModel?
    private(set) var letterLayout: LetterLayout?

    private let editor: TextEditor
    /// Touch points of the current word's letters; `nil` once they can't be trusted.
    private var touches: [CGPoint]? = []
    /// When each of those letters was touched, on the same clock as swipe arrivals.
    private var touchTimes: [Double] = []
    /// A word the user insisted on; the next space leaves it alone.
    private var keptWord: String?
    /// The trailing word fragment of a multi-character shortcut. Left alone until the user
    /// edits it, so "com" at the end of an email is not autocorrected or offered as a fix.
    private var literalWord: String?
    private var swipeReadings: [String] = []
    private var history = WordHistory()
    private var stagedHistory: HistoryEntry?
    private var drill: HistoryDrill?
    private var pendingUndo: HistoryUndo?
    private var learnedNotice: String?
    private var previewThumbs: [Int] = []
    private var snippets = SnippetBook.load()
    private var emojiRecents = EmojiWords.loadRecents()
    private var hintRemaining = StripHintStore.remaining()
    private var hintCounted = false
    /// Set by the engine when `detectPatterns` says the pasteboard has something. The string is not read here.
    var pasteboardMayContainText = false
    /// Letters the last swipe aimed at, so deleting that word can refuse it for a similar stroke.
    private var swipeTrace: String?
    /// Aimed letters from the swipe, kept on the strip when they are not the committed word.
    private var tracedLiteral: String?
    /// Set while a finger is still drawing; cleared when the swipe commits or is cancelled.
    private var preview: DecodeResult?
    /// The leader stays until this instant when a challenger is clearly ahead.
    private var previewHeldUntil: Date?
    /// A preview word the user tapped, kept at the front until the fingers lift.
    private var chosenPreview: String?
    /// The word that just ended. Stays on the strip, unhighlighted, until the next letter.
    private var settledWord: String?
    /// A word lifted off the page, shown until it is replaced or put back.
    private var pickedUpWord: String?
    private var cached: (key: CacheKey, state: CandidateState)?

    var hasPickedUpWord: Bool { pickedUpWord != nil }

    private struct CacheKey: Equatable {
        let word: Substring
        let touchCount: Int?
        let commit: TextEditor.RecentCommit?
        let readings: [String]
        let autocorrects: Bool
        let settled: String?
        let literal: String?
    }

    init(editor: TextEditor) {
        self.editor = editor
    }

    func updateLayout(for geometry: KeyboardGeometry, layer: KeyboardLayer) {
        guard layer == .letters, let layout = LetterLayout(geometry: geometry) else { return }
        letterLayout = layout
        cached = nil
    }

    // MARK: - Tracking the current word

    func noteLetter(at point: CGPoint?, time: Double) {
        clearSettled()
        releaseLiteralIfStale()
        if editor.currentWord.count <= 1 {
            touches = []
            touchTimes = []
        }
        guard let point else {
            touches = nil
            touchTimes = []
            return
        }
        touches?.append(point)
        touchTimes.append(time)
    }

    func noteCharacterDeleted() {
        releaseLiteralIfStale()
        if touches?.isEmpty == false {
            touches?.removeLast()
        }
        if !touchTimes.isEmpty {
            touchTimes.removeLast()
        }
    }

    func noteContextChanged() {
        clearSettled()
        releaseLiteralIfStale()
        sealHistory()
        let context = editor.contextBefore
        if context == nil {
            history.clear()
            drill = nil
            pendingUndo = nil
        } else {
            history.dropIfStale(contextBefore: context)
            if let pendingUndo, context?.hasSuffix(pendingUndo.match) != true {
                self.pendingUndo = nil
            }
            if drill?.context != context {
                drill = nil
            }
        }
        if editor.currentWord.isEmpty {
            touches = []
            touchTimes = []
        }
    }

    /// The text just inserted is a shortcut, not a word being typed.
    func noteLiteralText() {
        let word = String(editor.currentWord)
        literalWord = word.isEmpty ? nil : word
        touches = nil
        touchTimes = []
        cached = nil
    }

    /// Letters of the word being tapped, in order, so a following swipe can fold them in.
    func placedObservations() -> [StrokeObservation] {
        guard let touches, touches.count == touchTimes.count else { return [] }
        let letters = editor.currentWord.lowercased().map { String($0) }
        guard letters.count == touches.count, letters.allSatisfy({ $0.allSatisfy(\.isLetter) }) else { return [] }
        var observations: [StrokeObservation] = []
        for index in letters.indices {
            var directionX: CGFloat = 0
            var directionY: CGFloat = 0
            if index > 0 {
                let rawX = touches[index].x - touches[index - 1].x
                let rawY = touches[index].y - touches[index - 1].y
                let length = hypot(rawX, rawY)
                if length > 1 {
                    directionX = rawX / length
                    directionY = rawY / length
                }
            }
            observations.append(StrokeObservation(
                time: touchTimes[index],
                point: touches[index],
                directionX: directionX,
                directionY: directionY,
                letter: letters[index]
            ))
        }
        return observations
    }

    // MARK: - Word boundaries

    /// The current word just ended. Autocorrects it (inserting `trailing` after the correction)
    /// when appropriate and returns whether it did; otherwise learns it if it's new.
    func finishWord(trailing: String, autocorrects: Bool, display: String? = nil) -> Bool {
        defer {
            touches = []
            touchTimes = []
        }
        let word = String(editor.currentWord)
        guard let language, !word.isEmpty, !TextBoundary.continuesWord(after: editor.contextAfter) else { return false }
        if let layout = letterLayout, let touches {
            let letters = word.lowercased().filter(\.isLetter).map { String($0) }
            if letters.count == touches.count {
                TouchOffsetLog.record(letters: letters, points: touches, layout: layout)
            }
        }
        if literalWord == word {
            literalWord = nil
            language.noteCommitted(word, display: display)
            stageHistory(text: word, readings: [HistoryReading(word: word, score: 0)], aimed: word, unsure: false, trailing: trailing)
            return false
        }
        if keptWord == word {
            keptWord = nil
            noteLearnedCrossing(word, display: display)
            language.noteCommitted(word, display: display)
            stageHistory(text: word, readings: [HistoryReading(word: word, score: 0)], aimed: word, unsure: false, trailing: trailing)
            settle(word)
            return false
        }
        keptWord = nil
        if snippets.expansion(for: word) != nil {
            language.noteCommitted(word, display: display)
            stageHistory(text: word, readings: [HistoryReading(word: word, score: 0)], aimed: word, unsure: false, trailing: trailing)
            settle(word)
            return false
        }
        let analysis = language.analyze(word, touches: touches, layout: letterLayout, completionLimit: 0)
        let correction = beamCorrection(of: word, fallback: analysis.correction, language: language)
        if autocorrects, let correction, correction != word {
            let replaced = editor.replaceCurrentWord(with: correction, kind: .corrected, trailing: trailing)
            if replaced {
                language.noteCommitted(correction, display: display)
                stageHistory(
                    text: correction,
                    readings: [
                        HistoryReading(word: correction, score: 0),
                        HistoryReading(word: word, score: -0.2),
                    ],
                    aimed: word,
                    unsure: false,
                    trailing: trailing
                )
                settle(correction)
            }
            return replaced
        }
        noteLearnedCrossing(word, display: display)
        language.noteCommitted(word, display: display)
        stageHistory(text: word, readings: [HistoryReading(word: word, score: 0)], aimed: word, unsure: false, trailing: trailing)
        settle(word)
        return false
    }

    /// The alignment search may replace a tapped word when it leads the typed spelling by more
    /// than an exact hit. A name that is not a rearrangement of a dictionary word stays.
    private func beamCorrection(of word: String, fallback: String?, language: LanguageModel) -> String? {
        guard let layout = letterLayout,
              let touches, touches.count == touchTimes.count,
              let result = language.tapReading(word: word, touches: touches, times: touchTimes, layout: layout),
              let winner = result.readings.first,
              winner.word.compare(word, options: .caseInsensitive) != .orderedSame
        else { return fallback }
        if let typed = result.readings.first(where: {
            $0.word.compare(word, options: .caseInsensitive) == .orderedSame
        }) {
            let appended = winner.score - DecodeResult.confidenceMargin - 1
            let synthetic = !language.isKnown(word) && abs(typed.score - appended) < 0.05
            if !synthetic, winner.score > typed.score + ReadingPolicy.exactLead {
                return winner.word
            }
        }
        let rival = result.readings.dropFirst().first?.score ?? -.infinity
        if sameLetters(winner.word, word), winner.score > rival + ReadingPolicy.exactLead {
            return winner.word
        }
        return fallback
    }

    private func sameLetters(_ left: String, _ right: String) -> Bool {
        let a = left.lowercased().filter(\.isLetter).sorted()
        let b = right.lowercased().filter(\.isLetter).sorted()
        return a == b && !a.isEmpty
    }

    /// The user deleted a swipe the moment it landed. The next similar stroke tries another word.
    func noteSwipedWordRefused(_ word: String) {
        language?.noteSwipeRefusal(word: word, trace: swipeTrace ?? word)
    }

    /// Backspace brought a deleted swipe back, so that guess is welcome again.
    func noteSwipedWordRestored(_ word: String) {
        language?.forgetSwipeRefusal(word: word)
    }

    /// The user picked `preferred` instead of the word a swipe just wrote. One choice pins it,
    /// so the next similar aim can find a spelling the dictionary does not know.
    func noteSwap(preferred: String, rejected: String?) {
        if let rejected {
            language?.noteRejection(preferred: preferred, rejected: rejected)
        }
        _ = language?.remember(preferred)
    }

    /// The user undid an autocorrection; leave `word` alone when it ends.
    func keep(_ word: String) {
        keptWord = word
    }

    /// The literal on the bar was tapped. Pin it now, so one choice makes the spelling known.
    func acceptLiteral(_ word: String) {
        keptWord = word
        let before = language?.personalUses(of: word) ?? 0
        _ = language?.remember(word)
        if before < PersonalLexicon.usesBeforeKnown {
            learnedNotice = word
        }
    }

    /// The user forgot `word`, so the next space may correct it again.
    func dropKept(_ word: String) {
        guard keptWord?.lowercased() == word.lowercased() else { return }
        keptWord = nil
        cached = nil
    }

    /// The sentence just ended, so the next word is not a follower of the one before the period.
    func noteSentenceEnded() {
        language?.noteSentenceEnded()
    }

    func swipeCommitted(
        _ readings: [String],
        unsure: Bool,
        literal: String? = nil,
        advancesRefusalClock: Bool = false,
        display: String? = nil,
        scores: [Double] = []
    ) {
        if advancesRefusalClock {
            language?.noteSwipeLanded()
        }
        if let word = readings.first {
            language?.noteCommitted(word, display: display)
        }
        swipeReadings = readings
        swipeTrace = literal
        tracedLiteral = readings.first { reading in
            guard let literal else { return false }
            return reading.compare(literal, options: .caseInsensitive) == .orderedSame
                && reading.compare(readings[0], options: .caseInsensitive) != .orderedSame
        }
        preview = nil
        chosenPreview = nil
        previewHeldUntil = nil
        previewThumbs = []
        touches = []
        touchTimes = []
        settledWord = nil
        cached = nil
        if let word = readings.first {
            let paired = readings.enumerated().map { index, reading in
                HistoryReading(word: reading, score: scores.indices.contains(index) ? scores[index] : Double(-index))
            }
            rememberHistory(
                text: word,
                readings: paired,
                aimed: literal ?? word,
                unsure: unsure,
                trailing: " "
            )
        }
    }

    /// The word that just finished stays on the strip until the next letter.
    func noteSettled(_ word: String) {
        settle(word)
    }

    /// `word` was lifted off the page and should fill the strip until it is replaced or restored.
    func notePickedUp(_ word: String) {
        pickedUpWord = word
        settledWord = nil
        cached = nil
    }

    func clearPickedUp() {
        guard pickedUpWord != nil else { return }
        pickedUpWord = nil
        cached = nil
    }

    /// Shows `result` in the suggestion strip without touching the document. An empty result
    /// leaves the previous preview up, so a momentary miss doesn't flash the wordmark.
    /// A word the user already tapped stays in front when it is still in the result.
    /// Returns whether the leading word changed.
    @discardableResult
    func showPreview(_ result: DecodeResult) -> Bool {
        if result.withdrawsPreview {
            guard preview != nil || chosenPreview != nil else { return false }
            clearPreview()
            return true
        }
        guard !result.isEmpty else { return false }
        let ordered = holding(placingChoice(on: result))
        let previous = preview?.readings.first?.word
        preview = ordered
        cached = nil
        return ordered.readings.first?.word != previous
    }

    /// The word the strip is about to commit.
    var previewLeader: String? { preview?.readings.first?.word }

    /// Keeps the current leader unless the challenger is clearly ahead on two updates in a row.
    private func holding(_ result: DecodeResult) -> DecodeResult {
        guard let previous = preview?.readings.first?.word,
              let incoming = result.readings.first,
              incoming.word.compare(previous, options: .caseInsensitive) != .orderedSame,
              let held = result.readings.first(where: {
                  $0.word.compare(previous, options: .caseInsensitive) == .orderedSame
              })
        else {
            previewHeldUntil = nil
            return result
        }
        let gap = incoming.score - held.score
        let now = Date()
        if gap < DecodeResult.confidenceMargin {
            previewHeldUntil = nil
            return leading(held, in: result)
        }
        if previewHeldUntil == nil {
            previewHeldUntil = now.addingTimeInterval(0.08)
        }
        if let until = previewHeldUntil, now < until {
            return leading(held, in: result)
        }
        previewHeldUntil = nil
        return result
    }

    private func leading(_ held: DecodeResult.Reading, in result: DecodeResult) -> DecodeResult {
        var readings = result.readings
        readings.removeAll { $0.word.compare(held.word, options: .caseInsensitive) == .orderedSame }
        readings.insert(held, at: 0)
        return result.replacingReadings(readings)
    }

    /// Moves a preview reading to the front. The callout and the lit keys follow it,
    /// and the lift commits it when the word is still in the result.
    @discardableResult
    func promotePreview(at index: Int) -> Bool {
        guard let preview, preview.readings.indices.contains(index) else { return false }
        chosenPreview = preview.readings[index].word
        self.preview = placingChoice(on: preview)
        cached = nil
        return true
    }

    /// The user's preview choice, applied to a decode that still contains that word.
    func placingChoice(on result: DecodeResult) -> DecodeResult {
        guard let chosenPreview,
              let index = result.readings.firstIndex(where: {
                  $0.word.compare(chosenPreview, options: .caseInsensitive) == .orderedSame
              }),
              index != 0
        else { return result }
        var readings = result.readings
        let chosen = readings.remove(at: index)
        let top = result.readings[0].score
        readings.insert(DecodeResult.Reading(word: chosen.word, score: top + 0.01), at: 0)
        return result.replacingReadings(readings)
    }

    var isPreviewing: Bool { preview != nil }

    func clearPreview() {
        guard preview != nil || chosenPreview != nil else { return }
        preview = nil
        chosenPreview = nil
        previewHeldUntil = nil
        previewThumbs = []
        cached = nil
    }

    func rememberStroke(_ word: String, path: [CGPoint], layout: LetterLayout) {
        language?.rememberStroke(word, path: path, layout: layout)
    }

    // MARK: - Suggestions

    func notePreviewThumbs(_ thumbs: [Int]) {
        previewThumbs = thumbs
    }

    func candidates(suggests: Bool, autocorrects: Bool, variant: KeyboardVariant = .standard, blocksHistory: Bool = false) -> CandidateState {
        sealHistory()
        if blocksHistory || editor.contextBefore == nil {
            history.clear()
            drill = nil
        }
        if let preview {
            let shown = preview.readings.prefix(CandidateState.capacity).enumerated().map { index, reading in
                Candidate(reading.word, role: .alternative, unsure: preview.isUnsure && index == 0, letterThumbs: index == 0 ? previewThumbs : [])
            }
            // Close calls get no pill, so the preview never looks like the word a space will lock in.
            return CandidateState(shown, highlightedIndex: preview.isUnsure ? nil : 0, isTentative: true)
        }
        if pickedUpWord != nil {
            return pickedUpCandidates()
        }
        if editor.hasSelection, !blocksHistory, editor.contextBefore != nil {
            return CandidateState(fieldChips(variant: variant), isHistory: true)
        }
        // Search and URL fields hide suggestions, but a finished swipe still offers its other readings.
        if !suggests, let commit = editor.recentCommit, commit.kind == .swiped,
           !TextBoundary.continuesWord(after: editor.contextAfter) {
            return swipeStrip(word: commit.word, readings: swipeReadings, settled: settledWord, literal: tracedLiteral)
        }
        let fieldBar = variant == .email || variant == .url
        guard (suggests || fieldBar), !blocksHistory, let language, !TextBoundary.continuesWord(after: editor.contextAfter) else {
            return .empty
        }
        releaseLiteralIfStale()
        if literalWord == String(editor.currentWord) {
            cached = nil
            return .empty
        }
        if !suggests {
            return showingHistory(insteadOf: .empty, variant: variant)
        }
        let key = CacheKey(
            word: editor.currentWord,
            touchCount: touches?.count,
            commit: editor.recentCommit,
            readings: swipeReadings,
            autocorrects: autocorrects,
            settled: settledWord,
            literal: tracedLiteral
        )
        if let cached, cached.key == key {
            return appendingSnippet(to: showingHistory(insteadOf: cached.state, variant: variant))
        }
        let state = makeCandidates(key, language: language)
        cached = (key, state)
        return appendingSnippet(to: showingHistory(insteadOf: state, variant: variant))
    }

    private func appendingSnippet(to state: CandidateState) -> CandidateState {
        guard !state.isHistory, !state.isTentative, !state.isDrilled, state.candidates.count < CandidateState.capacity else { return state }
        let token = state.candidates.first?.text ?? ""
        guard let expansion = snippets.expansion(for: token) else { return state }
        let chip = Candidate(expansion, role: .history, action: .replaceSuffix(match: token + " ", with: expansion + " "))
        return CandidateState(
            state.candidates + [chip],
            highlightedIndex: state.highlightedIndex,
            isTentative: state.isTentative
        )
    }

    /// The word that just landed stays until the next letter. Once that repair is gone and
    /// nothing is being typed, the bar lists the words already written.
    private func showingHistory(insteadOf state: CandidateState, variant: KeyboardVariant) -> CandidateState {
        guard !state.isTentative, editor.currentWord.isEmpty else { return state }
        if !state.candidates.isEmpty { return state }
        if let drill {
            return drilledState(drill)
        }
        return idleHistory(variant: variant)
    }

    func historyChoices(for word: String) -> [String] {
        var choices: [String] = []
        if let commit = editor.recentCommit?.word, commit.compare(word, options: .caseInsensitive) == .orderedSame {
            choices.append(contentsOf: swipeReadings.filter {
                $0.compare(word, options: .caseInsensitive) != .orderedSame
            })
        }
        if choices.isEmpty, let language {
            let analysis = language.analyze(word, touches: nil, layout: letterLayout, completionLimit: 0)
            if let correction = analysis.correction,
               correction.compare(word, options: .caseInsensitive) != .orderedSame {
                choices.append(correction)
            }
            let shown = language.presenting(word, shift: .off)
            if shown != word, shown.compare(word, options: .caseInsensitive) == .orderedSame {
                choices.append(shown)
            }
        }
        var seen = Set<String>()
        return choices.filter { seen.insert($0.lowercased()).inserted }
    }

    /// The user put back a word the keyboard had replaced.
    func rememberRejection(preferred: String, rejected: String) {
        language?.noteRejection(preferred: preferred, rejected: rejected)
    }

    func accept(_ index: Int, from state: CandidateState) -> Acceptance? {
        guard !state.isTentative, state.candidates.indices.contains(index) else { return nil }
        let candidate = state.candidates[index]
        switch candidate.role {
        case .typed:
            return .keep(candidate.text)
        case .correction, .completion:
            return .replace(candidate.text)
        case .alternative:
            if let current = editor.recentCommit?.word, let position = swipeReadings.firstIndex(of: candidate.text) {
                swipeReadings[position] = current
            }
            return .swap(candidate.text)
        case .revert:
            return .revert
        case .settled:
            swipeReadings = []
            tracedLiteral = nil
            settle(candidate.text)
            return .settle
        case .picked:
            return .insert(candidate.text)
        case .follow:
            return .follow(candidate.text)
        case .history:
            guard let action = candidate.action else { return nil }
            return .command(action, text: candidate.text)
        }
    }

    /// Rows for the hold menu on one visible chip.
    func menuRows(for chip: Int, in state: CandidateState) -> [HistoryMenuRow] {
        guard state.candidates.indices.contains(chip) else { return [] }
        let candidate = state.candidates[chip]
        switch candidate.action {
        case let .openHistory(index):
            return rows(forEntry: index)
        case let .openDocumentWord(index):
            return rows(forDocument: index)
        case .retireLearned:
            return [
                HistoryMenuRow(title: "Undo", action: .forgetLearned),
                HistoryMenuRow(title: "Block", action: .blockLearned),
            ]
        default:
            return []
        }
    }

    func openHistoryChip(_ action: Candidate.StripAction) {
        switch action {
        case let .openHistory(index):
            guard let entry = history.entry(index) else { return }
            let previous = index > 0 ? history.entry(index - 1)?.text : nil
            let next = history.entry(index + 1)?.text
            drill = HistoryDrill(
                source: .entry(index),
                choices: ranked(entry, previous: previous, next: next),
                context: editor.contextBefore
            )
        case let .openDocumentWord(index):
            let earlier = TextBoundary.earlierWords(before: editor.contextBefore, limit: CandidateState.historyLimit)
            guard earlier.indices.contains(index) else { return }
            let word = earlier[index].text
            var choices = historyChoices(for: word)
            choices.append(contentsOf: HistoryRanking.extras(for: word, known: isKnownWord))
            if !choices.contains(where: { $0.compare(word, options: .caseInsensitive) == .orderedSame }) {
                choices.insert(word, at: 0)
            }
            drill = HistoryDrill(source: .document(index), choices: choices, context: editor.contextBefore)
        default:
            break
        }
        cached = nil
    }

    func closeDrill() {
        guard drill != nil else { return }
        drill = nil
        cached = nil
    }

    func rememberEmoji(_ symbol: String) {
        guard let word = history.entries.last?.text else { return }
        emojiRecents[word.lowercased()] = symbol
        EmojiWords.remember(word, symbol: symbol)
    }

    /// Applies one history edit when the field still ends with what was stored.
    /// Returns the elapsed-time record when a replacement was attempted.
    @discardableResult
    func perform(_ action: Candidate.StripAction, started: Double, now: () -> Double, strokePath: [CGPoint]?) -> HistoryEditLog.Record? {
        switch action {
        case .openHistory, .openDocumentWord:
            openHistoryChip(action)
            return nil
        case .closeDrill:
            closeDrill()
            return nil
        case .dismissHint:
            hintRemaining = 0
            StripHintStore.save(0)
            hintCounted = true
            cached = nil
            return nil
        case .retireLearned, .forgetLearned:
            if action == .forgetLearned, let learnedNotice {
                _ = language?.forget(learnedNotice)
            }
            learnedNotice = nil
            cached = nil
            return nil
        case .blockLearned:
            if let learnedNotice {
                _ = language?.ban(learnedNotice)
                _ = language?.forget(learnedNotice)
            }
            learnedNotice = nil
            cached = nil
            return nil
        case .undoEdit:
            undoEdit()
            return nil
        case let .replaceHistory(entry, text):
            return replaceEntry(entry, with: text, started: started, now: now, strokePath: strokePath)
        case let .replaceDocumentWord(index, text):
            return replaceDocument(index, with: text, started: started, now: now)
        case let .retype(entry):
            retype(entry)
            return nil
        case let .merge(entry):
            return merge(entry, started: started, now: now)
        case let .capitalize(entry, upper):
            capitalize(entry, upper: upper)
            return nil
        case .insertText, .replaceSuffix, .clipboard:
            return nil
        }
    }

    // MARK: - Private

    private func releaseLiteralIfStale() {
        guard let literalWord, String(editor.currentWord) != literalWord else { return }
        self.literalWord = nil
        cached = nil
    }

    private func makeCandidates(_ key: CacheKey, language: LanguageModel) -> CandidateState {
        if let commit = key.commit {
            switch commit.kind {
            case .swiped:
                return swipeStrip(word: commit.word, readings: key.readings, settled: key.settled, literal: key.literal)
            case .corrected:
                return CandidateState([Candidate(commit.original, role: .revert)])
            case .completed:
                return appendingFollow(to: settledCandidate(), language: language)
            }
        }

        let word = String(key.word)
        guard !word.isEmpty, word.count <= 24 else {
            return appendingFollow(to: settledCandidate(), language: language)
        }
        let analysis = language.analyze(word, touches: touches, layout: letterLayout)
        var candidates = [Candidate(word, role: .typed)]
        var highlighted: Int?
        if let correction = analysis.correction {
            candidates.append(Candidate(correction, role: .correction))
            if key.autocorrects { highlighted = 1 }
        }
        candidates += analysis.completions.map { Candidate($0, role: .completion) }
        return CandidateState(candidates, highlightedIndex: highlighted)
    }

    /// One alternative, the word that just landed, one alternative. The landed word is the
    /// highlighted center. The traced letters keep a side slot when they are not that word.
    /// Confirming the center leaves a single settled word.
    private func swipeStrip(word: String, readings: [String], settled: String?, literal: String?) -> CandidateState {
        if settled == word, readings.isEmpty || readings == [word] {
            let settledState = CandidateState([Candidate(word, role: .settled)])
            guard let language else { return settledState }
            return appendingFollow(to: settledState, language: language)
        }
        var others = readings.filter { $0.compare(word, options: .caseInsensitive) != .orderedSame }
        let literalSlot = literal.flatMap { literal in
            others.first { $0.compare(literal, options: .caseInsensitive) == .orderedSame }
        }
        if let literalSlot {
            others.removeAll { $0.compare(literalSlot, options: .caseInsensitive) == .orderedSame }
        }
        var slots: [Candidate] = []
        if let left = others.first {
            slots.append(Candidate(left, role: .alternative))
        }
        let center = slots.count
        slots.append(Candidate(word, role: .settled))
        if let literalSlot {
            slots.append(Candidate(literalSlot, role: .alternative))
        } else if others.count > 1 {
            slots.append(Candidate(others[1], role: .alternative))
        }
        return CandidateState(slots, highlightedIndex: center)
    }

    private func settle(_ word: String) {
        guard !word.isEmpty else { return }
        settledWord = word
        cached = nil
    }

    private func clearSettled() {
        guard settledWord != nil else { return }
        settledWord = nil
        cached = nil
    }

    /// Adds the next-word chip beside a word that just finished. It is not highlighted, so a
    /// space does not type it, and it never replaces the settled word or the history list.
    private func appendingFollow(to state: CandidateState, language: LanguageModel) -> CandidateState {
        guard state.candidates.contains(where: { $0.role == .settled }),
              let next = language.offeredFollower() else { return state }
        let shown = language.presenting(next, shift: .off)
        guard !state.candidates.contains(where: {
            $0.text.compare(shown, options: .caseInsensitive) == .orderedSame
        }) else { return state }
        return CandidateState(
            state.candidates + [Candidate(shown, role: .follow)],
            highlightedIndex: state.highlightedIndex,
            isTentative: state.isTentative,
            isHistory: state.isHistory,
            isDrilled: state.isDrilled
        )
    }

    private func settledCandidate() -> CandidateState {
        guard let settledWord else { return .empty }
        return CandidateState([Candidate(settledWord, role: .settled)])
    }

    /// The lifted word, and a correction when one exists. Nothing is highlighted, so a space
    /// does not type it; a tap does.
    private func pickedUpCandidates() -> CandidateState {
        guard let pickedUpWord else { return .empty }
        var candidates = [Candidate(pickedUpWord, role: .picked)]
        if let language {
            let analysis = language.analyze(pickedUpWord, touches: nil, layout: letterLayout, completionLimit: 0)
            if let correction = analysis.correction,
               correction.compare(pickedUpWord, options: .caseInsensitive) != .orderedSame {
                candidates.append(Candidate(correction, role: .picked))
            }
        }
        return CandidateState(candidates)
    }

    // MARK: - History

    private func noteLearnedCrossing(_ word: String, display: String?) {
        let before = language?.personalUses(of: word) ?? 0
        language?.learn(word, display: display)
        let after = language?.personalUses(of: word) ?? 0
        if before < PersonalLexicon.usesBeforeKnown, after >= PersonalLexicon.usesBeforeKnown {
            learnedNotice = word
        }
    }

    private func stageHistory(text: String, readings: [HistoryReading], aimed: String, unsure: Bool, trailing: String) {
        stagedHistory = HistoryEntry(
            text: text,
            readings: readings,
            aimed: aimed,
            unsure: unsure,
            trailing: trailing,
            startsSentence: false
        )
        sealHistory()
    }

    private func rememberHistory(text: String, readings: [HistoryReading], aimed: String, unsure: Bool, trailing: String) {
        stageHistory(text: text, readings: readings, aimed: aimed, unsure: unsure, trailing: trailing)
    }

    private func sealHistory() {
        guard var entry = stagedHistory, let before = editor.contextBefore else { return }
        if before.hasSuffix(entry.suffix), !entry.suffix.isEmpty, !(entry.trailing.isEmpty && before.hasSuffix(entry.text)) {
            stagedHistory = nil
            history.record(entry, contextBefore: before)
            return
        }
        guard let range = before.range(of: entry.text, options: [.backwards, .caseInsensitive]) else { return }
        let trailing = String(before[range.upperBound...])
        guard !trailing.isEmpty, trailing.allSatisfy({ !$0.isLetter && !$0.isNumber }) else { return }
        entry.trailing = trailing
        stagedHistory = nil
        history.record(entry, contextBefore: before)
    }

    private func isKnownWord(_ word: String) -> Bool {
        language?.isKnown(word) == true || word.count == 1
    }

    private func ranked(_ entry: HistoryEntry, previous: String?, next: String?) -> [String] {
        HistoryRanking.alternatives(
            for: entry,
            previous: previous,
            next: next,
            known: isKnownWord,
            pair: { [language] previous, next in language?.pairStrength(previous: previous, next: next) ?? 0 }
        )
    }

    private func idleHistory(variant: KeyboardVariant) -> CandidateState {
        if editor.hasSelection {
            return CandidateState(fieldChips(variant: variant), isHistory: true)
        }
        var chips: [Candidate] = []
        if let pendingUndo {
            chips.append(Candidate("Undo", role: .history, action: .undoEdit))
            _ = pendingUndo
        }
        if let learnedNotice {
            chips.append(Candidate("learned: \(learnedNotice)", role: .history, action: .retireLearned))
        }
        if history.matches(editor.contextBefore) {
            for (index, entry) in history.entries.enumerated() {
                chips.append(Candidate(entry.text, role: .history, action: .openHistory(index), unsure: entry.unsure))
            }
            if !hintCounted, hintRemaining > 0 {
                chips.append(Candidate("Tap a word to fix it", role: .history, action: .dismissHint))
                hintRemaining -= 1
                hintCounted = true
                StripHintStore.save(hintRemaining)
            }
        } else {
            let words = TextBoundary.earlierWords(before: editor.contextBefore, limit: CandidateState.historyLimit)
            for (index, word) in words.enumerated() {
                chips.append(Candidate(word.text, role: .history, action: .openDocumentWord(index)))
            }
        }
        chips.append(contentsOf: fieldChips(variant: variant))
        guard !chips.isEmpty else { return .empty }
        return CandidateState(chips, isHistory: true)
    }

    private func fieldChips(variant: KeyboardVariant) -> [Candidate] {
        if editor.hasSelection {
            return [
                Candidate("Copy", role: .history, action: .clipboard(.copy)),
                Candidate("Cut", role: .history, action: .clipboard(.cut)),
                Candidate("Paste", role: .history, action: .clipboard(.paste)),
                Candidate("Select word", role: .history, action: .clipboard(.selectWord)),
            ]
        }
        var chips: [Candidate] = []
        let context = editor.contextBefore ?? ""
        let token = String(editor.currentWord).isEmpty ? history.entries.last?.text ?? "" : String(editor.currentWord)
        if let expansion = snippets.expansion(for: token) {
            let match = history.matches(context) ? (history.entry(history.entries.count - 1)?.suffix ?? token) : token
            chips.append(Candidate(expansion, role: .history, action: .replaceSuffix(match: match, with: expansion + " ")))
        }
        if let symbol = EmojiWords.symbol(for: token, recents: emojiRecents) {
            chips.append(Candidate(symbol, role: .history, action: .insertText))
        }
        if let expression = ExpressionValue.token(in: context), let result = ExpressionValue.result(of: expression) {
            chips.append(Candidate(result, role: .history, action: .replaceSuffix(match: expression, with: result)))
        }
        switch variant {
        case .email:
            chips.append(Candidate("@", role: .history, action: .insertText))
            for domain in ["gmail.com", "icloud.com", ".com"] {
                chips.append(Candidate(domain, role: .history, action: .insertText))
            }
        case .url:
            for piece in ["www.", ".com", "/"] {
                chips.append(Candidate(piece, role: .history, action: .insertText))
            }
        case .standard, .numeric:
            break
        }
        if pasteboardMayContainText {
            chips.append(Candidate("Paste", role: .history, action: .clipboard(.paste)))
        }
        return chips
    }

    private func drilledState(_ drill: HistoryDrill) -> CandidateState {
        var chips = [Candidate("Back", role: .history, action: .closeDrill)]
        for choice in drill.choices {
            let action: Candidate.StripAction = switch drill.source {
            case let .entry(index): .replaceHistory(entry: index, text: choice)
            case let .document(index): .replaceDocumentWord(index: index, text: choice)
            }
            chips.append(Candidate(choice, role: .history, action: action))
        }
        return CandidateState(chips, isHistory: true, isDrilled: true)
    }

    private func rows(forEntry index: Int) -> [HistoryMenuRow] {
        guard let entry = history.entry(index) else { return [] }
        let previous = index > 0 ? history.entry(index - 1)?.text : nil
        let next = history.entry(index + 1)?.text
        var rows = ranked(entry, previous: previous, next: next).map {
            HistoryMenuRow(title: $0, action: .replaceHistory(entry: index, text: $0))
        }
        rows.append(HistoryMenuRow(title: "Retype", action: .retype(entry: index)))
        rows.append(HistoryMenuRow(title: "Capitalize", action: .capitalize(entry: index, upper: true)))
        rows.append(HistoryMenuRow(title: "Lowercase", action: .capitalize(entry: index, upper: false)))
        return rows
    }

    private func rows(forDocument index: Int) -> [HistoryMenuRow] {
        let earlier = TextBoundary.earlierWords(before: editor.contextBefore, limit: CandidateState.historyLimit)
        guard earlier.indices.contains(index) else { return [] }
        let word = earlier[index].text
        var choices = historyChoices(for: word)
        choices.append(contentsOf: HistoryRanking.extras(for: word, known: isKnownWord))
        var rows = choices.map { HistoryMenuRow(title: $0, action: .replaceDocumentWord(index: index, text: $0)) }
        rows.append(HistoryMenuRow(title: "Capitalize", action: .replaceDocumentWord(index: index, text: word.capitalized)))
        rows.append(HistoryMenuRow(title: "Lowercase", action: .replaceDocumentWord(index: index, text: word.lowercased())))
        return rows
    }

    private func replaceEntry(_ index: Int, with replacement: String, started: Double, now: () -> Double, strokePath: [CGPoint]?) -> HistoryEditLog.Record? {
        guard history.matches(editor.contextBefore), let entry = history.entry(index), let tail = history.suffix(from: index) else {
            history.clear()
            drill = nil
            return nil
        }
        let shown = cased(replacement, like: entry)
        let rest = history.entries[(index + 1)...].map(\.suffix).joined()
        let replacementSuffix = shown + entry.trailing + rest
        guard editor.replaceMatchedSuffix(tail, with: replacementSuffix) else {
            history.clear()
            drill = nil
            return nil
        }
        let record = HistoryEditLog.record(elapsed: max(0, now() - started))
        pendingUndo = HistoryUndo(match: replacementSuffix, previous: tail)
        language?.noteRejection(preferred: shown, rejected: entry.text)
        language?.noteCommitted(shown, display: shown)
        if let strokePath, strokePath.count >= 2, index == history.entries.count - 1, let layout = letterLayout {
            language?.rememberStroke(shown, path: strokePath, layout: layout)
        }
        history.rewrite(at: index, text: shown)
        drill = nil
        cached = nil
        return record
    }

    private func replaceDocument(_ index: Int, with replacement: String, started: Double, now: () -> Double) -> HistoryEditLog.Record? {
        let earlier = TextBoundary.earlierWords(before: editor.contextBefore, limit: CandidateState.historyLimit)
        guard earlier.indices.contains(index), let context = editor.contextBefore else { return nil }
        let word = earlier[index]
        let units = word.utf16After + word.text.utf16.count
        guard let suffix = context.suffix(utf16Count: units) else { return nil }
        let shown = replacement
        guard editor.replaceEarlierWord(word, with: shown, confirming: suffix) else {
            history.clear()
            drill = nil
            return nil
        }
        let record = HistoryEditLog.record(elapsed: max(0, now() - started))
        language?.noteRejection(preferred: shown, rejected: word.text)
        language?.noteCommitted(shown, display: shown)
        drill = nil
        cached = nil
        return record
    }

    private func retype(_ index: Int) {
        guard let match = history.suffix(from: index), let entry = history.entry(index), history.matches(editor.contextBefore) else {
            history.clear()
            return
        }
        let followers = history.entries[(index + 1)...].map(\.suffix).joined()
        if followers.isEmpty {
            guard editor.reopenMatchedSuffix(match, as: entry.aimed) else {
                history.clear()
                return
            }
        } else {
            let rest = entry.trailing + followers
            guard editor.replaceMatchedSuffix(match, with: entry.aimed + rest) else {
                history.clear()
                return
            }
            for _ in rest {
                guard editor.moveCursor(by: -1) else { break }
            }
        }
        history.clear()
        drill = nil
        cached = nil
    }

    private func merge(_ index: Int, started: Double, now: () -> Double) -> HistoryEditLog.Record? {
        guard history.matches(editor.contextBefore),
              let first = history.entry(index),
              let second = history.entry(index + 1),
              let tail = history.suffix(from: index)
        else { return nil }
        let joined = first.text + second.text
        let rest = history.entries[(index + 2)...].map(\.suffix).joined()
        let replacementSuffix = joined + second.trailing + rest
        guard editor.replaceMatchedSuffix(tail, with: replacementSuffix) else {
            history.clear()
            return nil
        }
        let record = HistoryEditLog.record(elapsed: max(0, now() - started))
        pendingUndo = HistoryUndo(match: replacementSuffix, previous: tail)
        history.merge(at: index, text: joined)
        drill = nil
        cached = nil
        return record
    }

    private func capitalize(_ index: Int, upper: Bool) {
        guard let entry = history.entry(index) else { return }
        let text = upper ? entry.text.prefix(1).uppercased() + entry.text.dropFirst() : entry.text.lowercased()
        _ = replaceEntry(index, with: text, started: 0, now: { 0 }, strokePath: nil)
    }

    private func undoEdit() {
        guard let pendingUndo, editor.contextBefore?.hasSuffix(pendingUndo.match) == true else {
            self.pendingUndo = nil
            return
        }
        guard editor.replaceMatchedSuffix(pendingUndo.match, with: pendingUndo.previous) else { return }
        self.pendingUndo = nil
        history.dropIfStale(contextBefore: editor.contextBefore)
        if !history.matches(editor.contextBefore) {
            history.clear()
        }
        drill = nil
        cached = nil
    }

    /// A replacement keeps the capital the field already had. Autocap-off typing stays lowercase.
    private func cased(_ word: String, like entry: HistoryEntry) -> String {
        guard entry.startsSentence, entry.text.first?.isUppercase == true, let first = word.first, first.isLetter else {
            return word
        }
        if word.dropFirst().contains(where: \.isUppercase) { return word }
        return first.uppercased() + word.dropFirst()
    }
}
