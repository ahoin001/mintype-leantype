import Foundation

/// The last swipe chunk, so the first backspace can unroll it.
///
/// A swipe that joined a tap-open word remembers the letters from before that swipe.
/// Undoing puts those letters back into composing. A swipe that was the whole word
/// has no draft; undoing removes the committed word and the next backspace deletes
/// normally.
struct ChunkHistory: Equatable, Sendable {
    /// Composing text captured when a swipe joined a tap-open word, before that swipe commits.
    var tapDraft: String?
    /// The same draft, kept after the joined word commits.
    var restoreAfterCommit: String?

    mutating func rememberDraft(_ text: String) {
        guard !text.isEmpty else { return }
        tapDraft = text
    }

    mutating func noteCommitted() {
        restoreAfterCommit = tapDraft
        tapDraft = nil
    }

    mutating func clear() {
        tapDraft = nil
        restoreAfterCommit = nil
    }
}
