import CoreGraphics

/// What the user asked for. Sessions translate touches into intents; `KeyboardEngine` applies
/// them to the document and keyboard mode.
public enum KeyboardIntent: Hashable, Sendable {
    /// Inserts a character in its unshifted form; the engine applies the current shift state.
    case insert(String)
    /// A tapped character key and where the finger actually landed, which autocorrect uses
    /// to judge what was meant.
    case tapCharacter(String, at: CGPoint, time: Double)
    case space
    /// Lifts the word touching the cursor so the next typing replaces it.
    case pickUpWord
    /// A space the keyboard adds on the user's behalf (after a slid punctuation mark).
    case autoSpace
    case returnKey
    case deleteWord
    case deleteCharacter
    case deleteSentence
    case restoreCharacter
    case restoreLastDeletion
    /// Undoes the latest autocorrection or removes the latest swiped word, if the cursor is
    /// still right after it. Changes nothing otherwise.
    case undoRecentCommit
    /// Moves the cursor one character; negative is left.
    case moveCursor(Int)
    /// Moves the cursor one word; negative is left.
    case moveCursorByWord(Int)
    /// Commits a decoded swipe. Candidates are best first and never empty. `unsure` means the
    /// top two readings were too close to present the first as the one a space accepts.
    case commitSwipe([String], unsure: Bool, strokes: Int, observations: [StrokeObservation])
    /// Picks a slot in the suggestion bar.
    case acceptCandidate(Int)
    case shiftPressBegan
    case shiftPressEnded
    case switchLayer(KeyboardLayer)
    case showEmojiPage(EmojiCategory)
    case nextKeyboard
}
