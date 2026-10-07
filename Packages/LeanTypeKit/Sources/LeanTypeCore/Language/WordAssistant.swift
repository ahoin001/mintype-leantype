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
    /// A word the user insisted on; the next space leaves it alone.
    private var keptWord: String?
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

    func noteLetter(at point: CGPoint?) {
        if editor.currentWord.count <= 1 {
            touches = []
        }
        guard let point else {
            touches = nil
            return
        }
        touches?.append(point)
    }

    func noteCharacterDeleted() {
        if touches?.isEmpty == false {
            touches?.removeLast()
        }
    }

    func noteContextChanged() {
        if editor.currentWord.isEmpty {
            touches = []
        }
    }

    // MARK: - Word boundaries

    /// The current word just ended. Autocorrects it (inserting `trailing` after the correction)
    /// when appropriate and returns whether it did; otherwise learns it if it's new.
    func finishWord(trailing: String, autocorrects: Bool) -> Bool {
        defer { touches = [] }
        let word = String(editor.currentWord)
        guard let language, !word.isEmpty, !TextBoundary.continuesWord(after: editor.contextAfter) else { return false }
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
        guard suggests, let language, !TextBoundary.continuesWord(after: editor.contextAfter) else { return .empty }
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
