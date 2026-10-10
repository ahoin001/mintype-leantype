/// Applies editing operations to a `TextDocument` and owns the short-term memory that makes
/// them reversible: deletion history (scrub back, restore a word), the most recent word the
/// keyboard committed as a unit (undo an autocorrection, swap a swiped word), and whether the
/// last space was the keyboard's own (so punctuation can hop over it).
///
/// Every piece of memory is guarded by an anchor: the tail of the text right after the edit.
/// If the document no longer ends that way, the user edited elsewhere and the memory is void.
@MainActor
public final class TextEditor {
    /// A word the keyboard inserted (or rewrote) in one step.
    public struct RecentCommit: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case swiped
            case corrected
            case completed
        }

        public let kind: Kind
        /// What the commit replaced (the typed word for corrections and completions).
        public let original: String
        public let leading: String
        public let word: String
        public let trailing: String

        var inserted: String { leading + word + trailing }
    }

    private enum LastDeletion {
        case none
        case character
        case word
        case restore
    }

    /// Number of trailing characters compared to detect edits made outside the keyboard.
    private static let anchorLength = 24

    private let document: any TextDocument
    private var deletions = DeletionBuffer()
    private var lastDeletion = LastDeletion.none
    private var deletionAnchor: Substring?
    private var commit: (value: RecentCommit, anchor: Substring?)?
    private var spaceAnchor: Substring?
    /// The swipe ghost was edited from the caret, so lift commits those letters.
    private var previewEdited = false

    /// The pending swipe ghost was changed. Later previews leave it alone until lift.
    public var preservesPreviewEdits: Bool { previewEdited }

    /// The edited ghost, once. Empty when every letter was deleted.
    public func consumeEditedPreview() -> String? {
        guard previewEdited else { return nil }
        previewEdited = false
        return document.previewComposing
    }

    public init(document: any TextDocument) {
        self.document = document
    }

    public var contextBefore: String? {
        let prefix = markPrefix
        guard let base = document.contextBefore else {
            return prefix.isEmpty ? nil : prefix
        }
        return base + prefix
    }

    public var contextAfter: String? {
        let suffix = markSuffix
        guard let base = document.contextAfter else {
            return suffix.isEmpty ? nil : suffix
        }
        return suffix + base
    }

    public var isDocumentEmpty: Bool {
        (document.contextBefore ?? "").isEmpty
            && (document.contextAfter ?? "").isEmpty
            && document.activeMark.isEmpty
    }

    /// The swipe ghost is the visible mark, so a typed letter joins it instead of hiding it.
    public var isEditingPreview: Bool {
        document.typedComposing.isEmpty && !document.previewComposing.isEmpty
    }

    /// The caret sits before the last held letter.
    public var caretIsMidTypedMark: Bool {
        let typed = document.typedComposing
        return !typed.isEmpty && document.markCaret < typed.count
    }

    /// The word right before the cursor, if the cursor is at the end of one.
    /// Held letters are already in `contextBefore`.
    public var currentWord: Substring {
        TextBoundary.currentWord(before: contextBefore)
    }

    /// Letters typed into the open word and not yet flushed into the document.
    public var typedComposing: String { document.typedComposing }

    /// The most recent unit commit, if the cursor is still right after it.
    public var recentCommit: RecentCommit? {
        guard let commit, isValid(commit.anchor), !caretIsInsideMark else { return nil }
        return commit.value
    }

    // MARK: - Insertion

    public func insert(_ text: String) {
        guard !text.isEmpty else { return }
        forgetEverything()
        document.insert(text)
    }

    /// Types a space and remembers it was the keyboard's, so punctuation can hop over it.
    public func insertSpace() {
        insert(" ")
        spaceAnchor = currentAnchor()
    }

    public func setTypedComposing(_ text: String) {
        document.setTypedComposing(text)
    }

    public func setPreviewComposing(_ text: String) {
        document.setPreviewComposing(text)
    }

    public func flushTypedComposing() {
        document.flushTypedComposing()
    }

    public func appendTypedComposing(_ letter: String) {
        document.setTypedComposing(document.typedComposing + letter)
    }

    /// Inserts `letter` at the caret inside the visible mark.
    public func insertIntoActiveMark(_ letter: String) {
        guard !letter.isEmpty else { return }
        if isEditingPreview {
            let caret = min(document.markCaret, document.previewComposing.count)
            var characters = Array(document.previewComposing)
            characters.insert(contentsOf: letter, at: caret)
            document.setPreviewComposing(String(characters), caret: caret + letter.count)
            previewEdited = true
            return
        }
        let caret = min(document.markCaret, document.typedComposing.count)
        var characters = Array(document.typedComposing)
        characters.insert(contentsOf: letter, at: caret)
        document.setTypedComposing(String(characters), caret: caret + letter.count)
    }

    /// Writes the visible mark into the document once, with the caret left where it was.
    public func commitActiveMark() {
        guard !document.activeMark.isEmpty else { return }
        previewEdited = false
        document.commitActiveMark()
    }

    public func clearPreviewComposing() {
        previewEdited = false
        document.setPreviewComposing("")
    }

    /// Types hopping punctuation. Right after a space the keyboard added ("word |"), the mark
    /// takes the space's place and the space moves after it ("word.| "). Returns whether it hopped.
    @discardableResult
    public func insertPunctuation(_ mark: String, hoppingSpace: Bool) -> Bool {
        let canHop = hoppingSpace
            && isValid(spaceAnchor)
            && TextBoundary.endsWithWordAndSingleSpace(document.contextBefore)
        guard canHop else {
            insert(mark)
            return false
        }
        forgetEverything()
        document.deleteBackward()
        document.insert(mark + " ")
        spaceAnchor = currentAnchor()
        return true
    }

    /// Turns "word " into "word. " for a double-tapped space. Returns `false` (and changes
    /// nothing) when the text doesn't end in a word followed by a single space.
    public func applyDoubleSpacePeriod() -> Bool {
        guard TextBoundary.canApplyDoubleSpacePeriod(before: document.contextBefore) else { return false }
        forgetEverything()
        document.deleteBackward()
        document.insert(". ")
        spaceAnchor = currentAnchor()
        return true
    }

    // MARK: - Word commits

    /// Inserts a whole word as one unit (from a swipe), with a space before it if the cursor is
    /// mid-text and a space after it so the next word can follow.
    public func commitWord(_ word: String) {
        let leading = TextBoundary.needsSpaceBeforeWord(document.contextBefore) ? " " : ""
        let value = RecentCommit(kind: .swiped, original: "", leading: leading, word: word, trailing: " ")
        forgetEverything()
        document.insert(value.inserted)
        remember(value)
    }

    /// Replaces the word before the cursor (an autocorrection or an accepted completion),
    /// followed by `trailing` (usually a space). Returns `false` if there is no current word.
    @discardableResult
    public func replaceCurrentWord(with replacement: String, kind: RecentCommit.Kind, trailing: String = " ") -> Bool {
        let original = String(currentWord)
        guard !original.isEmpty else { return false }
        forgetEverything()
        for _ in 0..<original.count {
            document.deleteBackward()
        }
        let value = RecentCommit(kind: kind, original: original, leading: "", word: replacement, trailing: trailing)
        document.insert(value.inserted)
        remember(value)
        return true
    }

    /// Swaps the word of the most recent commit (e.g. picking another swipe candidate).
    @discardableResult
    public func replaceRecentCommitWord(with word: String) -> Bool {
        guard let current = recentCommit else { return false }
        removeInserted(current)
        let value = RecentCommit(
            kind: current.kind,
            original: current.original,
            leading: current.leading,
            word: word,
            trailing: current.trailing
        )
        document.insert(value.inserted)
        remember(value)
        return true
    }

    /// Replaces one earlier word and puts the caret back where it was.
    /// `suffix` is the field ending that still has to be there. A mismatch changes nothing.
    @discardableResult
    public func replaceEarlierWord(
        _ word: TextBoundary.EarlierWord,
        with replacement: String,
        confirming suffix: String? = nil
    ) -> Bool {
        guard !replacement.isEmpty, word.characters > 0 else { return false }
        if let suffix {
            guard let before = document.contextBefore, before.hasSuffix(suffix) else { return false }
        }
        forgetEverything()
        document.flushTypedComposing()
        document.adjustCursor(byUTF16Offset: -word.utf16After)
        for _ in 0..<word.characters {
            document.deleteBackward()
        }
        document.insert(replacement)
        if word.utf16After != 0 {
            document.adjustCursor(byUTF16Offset: word.utf16After)
        }
        return true
    }

    /// Replaces a field ending and leaves the caret after the replacement.
    @discardableResult
    public func replaceMatchedSuffix(_ suffix: String, with replacement: String) -> Bool {
        guard !suffix.isEmpty, let before = document.contextBefore, before.hasSuffix(suffix) else { return false }
        forgetEverything()
        document.flushTypedComposing()
        for _ in suffix {
            document.deleteBackward()
        }
        if !replacement.isEmpty {
            document.insert(replacement)
        }
        return true
    }

    /// Puts `composing` back where `suffix` was, so typing continues inside that word.
    @discardableResult
    public func reopenMatchedSuffix(_ suffix: String, as composing: String) -> Bool {
        guard replaceMatchedSuffix(suffix, with: "") else { return false }
        document.setTypedComposing(composing)
        return true
    }

    /// Undoes the most recent commit if the cursor is still right after it: a correction or
    /// completion goes back to what was typed (without the space), a swiped word is removed
    /// and can be restored with a right swipe on backspace.
    @discardableResult
    public func undoRecentCommit() -> RecentCommit? {
        guard let current = recentCommit else { return nil }
        removeInserted(current)
        forgetEverything()
        switch current.kind {
        case .corrected, .completed:
            document.insert(current.original)
        case .swiped:
            deletions.record(Array(current.inserted.reversed()), extendingLastGroup: false)
            lastDeletion = .word
            deletionAnchor = currentAnchor()
        }
        return current
    }

    // MARK: - Deletion

    /// Deletes the previous word. Returns the removed text, or `nil` when there was nothing
    /// visible to remove (a single backspace is still sent for the host).
    @discardableResult
    public func deleteWord() -> String? {
        deleteRun(length: TextBoundary.wordDeletionLength(before:))
    }

    /// Deletes back to the end of the previous sentence.
    @discardableResult
    public func deleteSentence() -> String? {
        deleteRun(length: TextBoundary.sentenceDeletionLength(before:))
    }

    @discardableResult
    public func deleteCharacter() -> String? {
        if let removed = deleteInsideMark() { return removed }
        if hasSelection {
            forgetEverything()
            document.deleteBackward()
            return ""
        }
        guard let last = document.contextBefore?.last else {
            forgetEverything()
            document.deleteBackward()
            return nil
        }
        let continuesHistory = deletionHistoryIsValid()
        document.deleteBackward()
        record([last], as: .character, continuingHistory: continuesHistory)
        return String(last)
    }

    /// Deletes the character before the caret inside the marked word. The document stays put.
    private func deleteInsideMark() -> String? {
        let typed = document.typedComposing
        let mark = typed.isEmpty ? document.previewComposing : typed
        let caret = min(document.markCaret, mark.count)
        guard !mark.isEmpty, caret > 0 else { return nil }
        var characters = Array(mark)
        let removed = characters.remove(at: caret - 1)
        let text = String(characters)
        if !typed.isEmpty {
            document.setTypedComposing(text, caret: caret - 1)
        } else {
            document.setPreviewComposing(text, caret: caret - 1)
            previewEdited = true
        }
        return String(removed)
    }

    // MARK: - Restoration

    /// Re-inserts the most recently deleted character.
    @discardableResult
    public func restoreCharacter() -> String? {
        guard deletionHistoryIsValid(), let character = deletions.popCharacter() else { return nil }
        document.insert(String(character))
        markRestored()
        return String(character)
    }

    /// Re-inserts the most recently deleted word (or scrubbed run) in one step and returns it.
    @discardableResult
    public func restoreLastDeletion() -> String? {
        guard deletionHistoryIsValid(), let text = deletions.popGroup() else { return nil }
        document.insert(text)
        markRestored()
        return text
    }

    // MARK: - Cursor

    /// Moves the cursor one character in `direction` (negative is left). Returns `false` at
    /// either end of the available context so callers can stop accumulating movement.
    /// A step that stays inside a pending mark only moves that caret.
    @discardableResult
    public func moveCursor(by direction: Int) -> Bool {
        switch travelMark(direction, byWord: false) {
        case .absent, .continueOutside:
            break
        case let .handled(moved):
            return moved
        }
        return moveDocumentCaret(direction, byWord: false)
    }

    /// Moves the cursor to the start of the previous word or the end of the next one.
    /// Inside a pending mark, the first step lands on the near end of that mark.
    @discardableResult
    public func moveCursorByWord(_ direction: Int) -> Bool {
        switch travelMark(direction, byWord: true) {
        case .absent, .continueOutside:
            break
        case let .handled(moved):
            return moved
        }
        return moveDocumentCaret(direction, byWord: true)
    }

    private enum MarkTravel {
        case absent
        case handled(Bool)
        /// The swipe ghost was cleared. The same step continues in the document.
        case continueOutside
    }

    private func travelMark(_ direction: Int, byWord: Bool) -> MarkTravel {
        let mark = document.activeMark
        guard !mark.isEmpty, direction != 0 else { return .absent }
        let caret = min(document.markCaret, mark.count)
        if byWord {
            if direction < 0, caret > 0 {
                document.setMarkCaret(0)
                return .handled(true)
            }
            if direction > 0, caret < mark.count {
                document.setMarkCaret(mark.count)
                return .handled(true)
            }
        } else {
            let next = caret + (direction < 0 ? -1 : 1)
            if (0...mark.count).contains(next) {
                document.setMarkCaret(next)
                return .handled(true)
            }
        }
        return leaveMark()
    }

    /// The mark is already in the field. Committing it writes those letters once, then the same step continues outside.
    private func leaveMark() -> MarkTravel {
        guard !document.activeMark.isEmpty else { return .absent }
        previewEdited = false
        document.commitActiveMark()
        return .continueOutside
    }

    private func moveDocumentCaret(_ direction: Int, byWord: Bool) -> Bool {
        let offset: Int
        if byWord {
            if direction < 0 {
                let before = document.contextBefore ?? ""
                offset = -before.suffix(TextBoundary.wordMovementLength(before: before)).utf16.count
            } else if direction > 0 {
                let after = document.contextAfter ?? ""
                offset = after.prefix(TextBoundary.wordMovementLength(after: after)).utf16.count
            } else {
                return false
            }
        } else if direction < 0 {
            guard let character = document.contextBefore?.last else { return false }
            offset = -character.utf16.count
        } else if direction > 0 {
            guard let character = document.contextAfter?.first else { return false }
            offset = character.utf16.count
        } else {
            return false
        }
        guard offset != 0 else { return false }
        forgetEverything()
        document.adjustCursor(byUTF16Offset: offset)
        return true
    }

    /// Removes the word touching the cursor and returns the exact text that came off, plus the
    /// word itself with surrounding spaces trimmed. `nil` when there is no word there.
    public func pickUpWordTouchingCursor() -> (removed: String, word: String)? {
        let before = document.contextBefore ?? ""
        let after = document.contextAfter ?? ""
        let range = TextBoundary.pickupRange(before: before, after: after)
        guard range.prefix > 0 || range.suffix > 0 else { return nil }
        let prefix = String(before.suffix(range.prefix))
        let suffix = String(after.prefix(range.suffix))
        let removed = prefix + suffix
        let word = removed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return nil }
        forgetEverything()
        if !suffix.isEmpty {
            document.adjustCursor(byUTF16Offset: suffix.utf16.count)
        }
        for _ in removed {
            document.deleteBackward()
        }
        return (removed, word)
    }

    // MARK: - Memory bookkeeping

    var hasSelection: Bool {
        !(document.selectedText ?? "").isEmpty
    }

    private func deleteRun(length: (String?) -> Int) -> String? {
        // Held letters are part of the word on screen. The count has to include them,
        // because each backward delete spends one step on that composing text first.
        let before = contextBefore
        if hasSelection {
            forgetEverything()
            document.deleteBackward()
            return ""
        }
        guard let before, !before.isEmpty else {
            // No context: the host may still have text we can't see, so send one backspace.
            forgetEverything()
            document.deleteBackward()
            return nil
        }
        let continuesHistory = deletionHistoryIsValid()
        let count = length(before)
        let removed = before.suffix(count)
        for _ in 0..<count {
            document.deleteBackward()
        }
        record(Array(removed.reversed()), as: .word, continuingHistory: continuesHistory)
        return String(removed)
    }

    private func removeInserted(_ value: RecentCommit) {
        for _ in 0..<value.inserted.count {
            document.deleteBackward()
        }
    }

    /// `continuingHistory` must be checked before deleting, since the deletion itself changes
    /// the text the history anchor is compared against.
    private func record(_ removed: [Character], as operation: LastDeletion, continuingHistory: Bool) {
        commit = nil
        spaceAnchor = nil
        if !continuingHistory {
            deletions.removeAll()
            lastDeletion = .none
        }
        let extend = operation == .character && lastDeletion == .character
        deletions.record(removed, extendingLastGroup: extend)
        lastDeletion = operation
        deletionAnchor = currentAnchor()
    }

    private func markRestored() {
        commit = nil
        spaceAnchor = nil
        lastDeletion = .restore
        deletionAnchor = currentAnchor()
    }

    private func remember(_ value: RecentCommit) {
        let anchor = currentAnchor()
        commit = (value, anchor)
        spaceAnchor = value.trailing == " " ? anchor : nil
    }

    private func forgetEverything() {
        deletions.removeAll()
        lastDeletion = .none
        deletionAnchor = nil
        commit = nil
        spaceAnchor = nil
    }

    private func deletionHistoryIsValid() -> Bool {
        deletionAnchor != nil && isValid(deletionAnchor)
    }

    private func isValid(_ anchor: Substring?) -> Bool {
        guard let anchor else { return false }
        guard let current = currentAnchor() else { return true }
        return current == anchor
    }

    private func currentAnchor() -> Substring? {
        document.contextBefore.map { $0.suffix(Self.anchorLength) }
    }

    /// The caret has moved into a pending mark, so the previous commit is not what backspace should remove.
    public var caretIsInsideMark: Bool {
        let mark = document.activeMark
        return !mark.isEmpty && document.markCaret < mark.count
    }

    private var markPrefix: String {
        let mark = document.activeMark
        return String(mark.prefix(min(document.markCaret, mark.count)))
    }

    private var markSuffix: String {
        let mark = document.activeMark
        return String(mark.dropFirst(min(document.markCaret, mark.count)))
    }
}
