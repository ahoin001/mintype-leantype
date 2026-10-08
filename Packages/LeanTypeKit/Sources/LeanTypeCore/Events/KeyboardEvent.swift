import CoreGraphics

/// Something worth reacting to: a haptic, a click, a visual effect, or a statistic.
///
/// Events describe what happened in the keyboard's own terms and carry the context effects
/// need, in key-area coordinates (the dock sits above, at negative y). They never carry the
/// user's text beyond the single word an effect animates, and observers must not store it.
public enum KeyboardEvent: Hashable, Sendable {
    public enum KeyCategory: Hashable, Sendable {
        case character
        case delete
        case modifier
    }

    /// How a word reached the document.
    public enum WordSource: Hashable, Sendable {
        case tap
        case swipe
        case suggestion
    }

    /// A finger landed on a key.
    case keyDown(KeyCategory, at: CGPoint)
    /// A whole word (or run) was removed by a backspace tap or hold. `origin` is the backspace key.
    case wordDeleted(String, origin: CGPoint)
    /// A deleted word came back via a right swipe on backspace.
    case deletionRestored(String, origin: CGPoint)
    /// One step of a backspace scrub or repeat. `character` is what left or came back.
    case deleteStep(character: String, restoring: Bool)
    /// Holding backspace moved up a gear (characters to words, or words to sentences).
    /// One event per gear, never per deleted character.
    case deleteEscalated(DeleteGear)
    /// A double-space period ended a sentence. `at` is the space bar's center.
    case sentenceEnded(at: CGPoint)
    /// The space-bar trackpad engaged; `bar` is the space key's frame.
    case trackpadEngaged(bar: CGRect)
    case trackpadEnded
    /// The trackpad moved the cursor. `byWord` steps jump a whole word.
    case cursorStep(direction: Int, byWord: Bool)
    case alternatesPresented
    /// A hold row started its wait. `key` is that key's frame, in key-area coordinates.
    case holdArmed(CGRect)
    /// The hold ended, or the finger moved onto a key with no row.
    case holdEnded
    case capsLockEngaged
    /// A word was finished (by space, punctuation, swipe, or accepting a suggestion).
    case wordCommitted(WordSource)
    /// A swipe landed as a word. `strokes` is how many thumbs drew it.
    case swipeGestureCommitted(strokes: Int)
    /// The word the swipe is about to commit changed while the fingers are still down.
    case swipePreviewChanged
    case correctionApplied
    case correctionReverted
    /// Return inserted a newline. `title` is the key's label; `key` is its frame.
    case returnSent(String, from: CGRect)
    /// Typing rhythm changed noticeably.
    case flowChanged(FlowLevel)
    /// The user hit a streak milestone of clean words (25, 50, ...).
    case flowMilestone(Int)
}

/// The gear hold-to-delete just entered. A tap's starting gear is not announced;
/// only the step up from it is.
public enum DeleteGear: Hashable, Sendable {
    case character
    case word
    case sentence
}

/// Anything that reacts to keyboard events: feedback, effects, statistics.
@MainActor
public protocol KeyboardEventObserver: AnyObject {
    func handle(_ event: KeyboardEvent)
}
