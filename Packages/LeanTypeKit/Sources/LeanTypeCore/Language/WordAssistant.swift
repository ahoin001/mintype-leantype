import CoreGraphics

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
    /// Set while a finger is still drawing; cleared when the swipe commits or is cancelled.
    private var preview: DecodeResult?
    private var cached: (key: CacheKey, state: CandidateState)?

    private struct CacheKey: Equatable {
        let word: Substring
        let touchCount: Int?
        let commit: TextEditor.RecentCommit?
        let readings: [String]
        let autocorrects: Bool
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
        releaseLiteralIfStale()
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
    func finishWord(trailing: String, autocorrects: Bool) -> Bool {
        defer {
            touches = []
            touchTimes = []
        }
        let word = String(editor.currentWord)
        guard let language, !word.isEmpty, !TextBoundary.continuesWord(after: editor.contextAfter) else { return false }
        if literalWord == word {
            literalWord = nil
            return false
        }
        if keptWord == word {
            keptWord = nil
            language.learn(word)
            return false
        }
        keptWord = nil
        let analysis = language.analyze(word, touches: touches, layout: letterLayout, completionLimit: 0)
        if autocorrects, let correction = analysis.correction, correction != word {
            return editor.replaceCurrentWord(with: correction, kind: .corrected, trailing: trailing)
        }
        language.learn(word)
        return false
    }

    /// The user undid an autocorrection; leave `word` alone when it ends.
    func keep(_ word: String) {
        keptWord = word
    }

    func swipeCommitted(_ readings: [String], unsure _: Bool) {
        swipeReadings = readings
        preview = nil
        touches = []
        touchTimes = []
        cached = nil
    }

    /// Shows `result` in the suggestion strip without touching the document. An empty result
    /// leaves the previous preview up, so a momentary miss doesn't flash the wordmark.
    func showPreview(_ result: DecodeResult) {
        guard !result.isEmpty else { return }
        preview = result
        cached = nil
    }

    func clearPreview() {
        guard preview != nil else { return }
        preview = nil
        cached = nil
    }

    // MARK: - Suggestions

    func candidates(suggests: Bool, autocorrects: Bool) -> CandidateState {
        if let preview {
            let shown = preview.readings.prefix(CandidateState.capacity).map { Candidate($0.word, role: .alternative) }
            // Close calls get no pill, so the preview never looks like the word a space will lock in.
            return CandidateState(shown, highlightedIndex: preview.isUnsure ? nil : 0, isTentative: true)
        }
        // Search and URL fields hide suggestions, but a finished swipe still offers its other readings.
        if !suggests, let commit = editor.recentCommit, commit.kind == .swiped,
           !TextBoundary.continuesWord(after: editor.contextAfter) {
            let alternatives = swipeReadings.filter { $0 != commit.word }.map { Candidate($0, role: .alternative) }
            return CandidateState(alternatives)
        }
        guard suggests, let language, !TextBoundary.continuesWord(after: editor.contextAfter) else { return .empty }
        releaseLiteralIfStale()
        if literalWord == String(editor.currentWord) {
            cached = nil
            return .empty
        }
        let key = CacheKey(
            word: editor.currentWord,
            touchCount: touches?.count,
            commit: editor.recentCommit,
            readings: swipeReadings,
            autocorrects: autocorrects
        )
        if let cached, cached.key == key { return cached.state }
        let state = makeCandidates(key, language: language)
        cached = (key, state)
        return state
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
                let alternatives = key.readings.filter { $0 != commit.word }.map { Candidate($0, role: .alternative) }
                return CandidateState(alternatives)
            case .corrected:
                return CandidateState([Candidate(commit.original, role: .revert)])
            case .completed:
                return .empty
            }
        }

        let word = String(key.word)
        guard !word.isEmpty, word.count <= 24 else { return .empty }
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
}
