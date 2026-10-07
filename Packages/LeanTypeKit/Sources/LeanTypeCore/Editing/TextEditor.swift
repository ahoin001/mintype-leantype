/// Applies editing operations to a `TextDocument` and owns undo-style deletion history.
///
/// Every method reports whether it changed anything, so callers only give feedback (haptics,
/// clicks) for edits that actually happened.
@MainActor
public final class TextEditor {
    private enum LastOperation {
        case none
        case deleteCharacter
        case deleteWord
        case restore
    }

    /// Number of trailing characters compared to detect edits made outside the keyboard.
    private static let anchorLength = 24

    private let document: any TextDocument
    private var deletions = DeletionBuffer()
    private var lastOperation = LastOperation.none
    /// Tail of the text right after our last delete or restore. If the document no longer ends
    /// this way, the user edited elsewhere and the deletion history no longer applies.
    private var anchor: Substring?

    public init(document: any TextDocument) {
        self.document = document
    }

    public var contextBefore: String? { document.contextBefore }
    public var contextAfter: String? { document.contextAfter }

    public var isDocumentEmpty: Bool {
        (document.contextBefore ?? "").isEmpty && (document.contextAfter ?? "").isEmpty
    }

    // MARK: - Insertion

    public func insert(_ text: String) {
        guard !text.isEmpty else { return }
        forgetDeletions()
        document.insert(text)
    }

    /// Turns "word " into "word. " for a double-tapped space. Returns `false` (and changes
    /// nothing) when the text doesn't end in a word followed by a single space.
    public func applyDoubleSpacePeriod() -> Bool {
        guard TextBoundary.canApplyDoubleSpacePeriod(before: document.contextBefore) else { return false }
        forgetDeletions()
        document.deleteBackward()
        document.insert(". ")
        return true
    }

    // MARK: - Deletion

    @discardableResult
    public func deleteWord() -> Bool {
        let before = document.contextBefore
        if hasSelection {
            forgetDeletions()
            document.deleteBackward()
            return true
        }
        guard let before, !before.isEmpty else {
            // No context: the host may still have text we can't see, so send one backspace.
            forgetDeletions()
            document.deleteBackward()
            return false
        }

        let continuesHistory = historyIsValid()
        let length = TextBoundary.wordDeletionLength(before: before)
        let removed = Array(before.suffix(length).reversed())
        for _ in 0..<length {
            document.deleteBackward()
        }
        record(removed, as: .deleteWord, continuingHistory: continuesHistory)
        return true
    }

    @discardableResult
    public func deleteCharacter() -> Bool {
        if hasSelection {
            forgetDeletions()
            document.deleteBackward()
            return true
        }
        guard let last = document.contextBefore?.last else {
            forgetDeletions()
            document.deleteBackward()
            return false
        }
        let continuesHistory = historyIsValid()
        document.deleteBackward()
        record([last], as: .deleteCharacter, continuingHistory: continuesHistory)
        return true
    }

    // MARK: - Restoration

    /// Re-inserts the most recently deleted character.
    @discardableResult
    public func restoreCharacter() -> Bool {
        guard historyIsValid(), let character = deletions.popCharacter() else { return false }
        document.insert(String(character))
        markRestored()
        return true
    }

    /// Re-inserts the most recently deleted word (or scrubbed run) in one step.
    @discardableResult
    public func restoreLastDeletion() -> Bool {
        guard historyIsValid(), let text = deletions.popGroup() else { return false }
        document.insert(text)
        markRestored()
        return true
    }

    // MARK: - Cursor

    /// Moves the cursor one character in `direction` (negative is left). Returns `false` at
    /// either end of the available context so callers can stop accumulating movement.
    @discardableResult
    public func moveCursor(by direction: Int) -> Bool {
        let offset: Int
        if direction < 0 {
            guard let character = document.contextBefore?.last else { return false }
            offset = -character.utf16.count
        } else if direction > 0 {
            guard let character = document.contextAfter?.first else { return false }
            offset = character.utf16.count
        } else {
            return false
        }
        forgetDeletions()
        document.adjustCursor(byUTF16Offset: offset)
        return true
    }

    // MARK: - History bookkeeping

    private var hasSelection: Bool {
        !(document.selectedText ?? "").isEmpty
    }

    /// `continuingHistory` must be checked before deleting, since the deletion itself changes
    /// the text the history anchor is compared against.
    private func record(_ removed: [Character], as operation: LastOperation, continuingHistory: Bool) {
        if !continuingHistory {
            deletions.removeAll()
            lastOperation = .none
        }
        let extend = operation == .deleteCharacter && lastOperation == .deleteCharacter
        deletions.record(removed, extendingLastGroup: extend)
        lastOperation = operation
        anchor = currentAnchor()
    }

    private func markRestored() {
        lastOperation = .restore
        anchor = currentAnchor()
    }

    private func forgetDeletions() {
        deletions.removeAll()
        lastOperation = .none
        anchor = nil
    }

    private func historyIsValid() -> Bool {
        guard let anchor else { return false }
        guard let current = currentAnchor() else { return true }
        return current == anchor
    }

    private func currentAnchor() -> Substring? {
        document.contextBefore.map { $0.suffix(Self.anchorLength) }
    }
}
