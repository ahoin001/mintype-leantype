/// What the user asked for. Sessions translate touches into intents; `KeyboardEngine` applies
/// them to the document and keyboard mode.
public enum KeyboardIntent: Hashable, Sendable {
    /// Inserts a character in its unshifted form; the engine applies the current shift state.
    case insert(String)
    case space
    case returnKey
    case deleteWord
    case deleteCharacter
    case restoreCharacter
    case restoreLastDeletion
    /// Moves the cursor one character; negative is left.
    case moveCursor(Int)
    case shiftPressBegan
    case shiftPressEnded
    case switchLayer(KeyboardLayer)
    case nextKeyboard
}

/// Moments worth a haptic or click. The UI layer decides how each one feels.
public enum FeedbackEvent: Hashable, Sendable {
    public enum KeyCategory: Hashable, Sendable {
        case character
        case delete
        case modifier
    }

    case keyDown(KeyCategory)
    case cursorStep
    case deleteStep
    case trackpadEngaged
    case alternatesPresented
    case capsLockEngaged
}
