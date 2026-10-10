/// One slot of the suggestion strip.
public struct Candidate: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        /// Exactly what was typed; accepting it keeps the word and stops autocorrect.
        case typed
        /// What a space will turn the typed word into.
        case correction
        /// A longer word starting with what was typed.
        case completion
        /// Another reading of the word just swiped.
        case alternative
        /// The word as typed before autocorrect changed it.
        case revert
        /// A word that already ended. Shown so it can be trained; tapping it does not type it again.
        case settled
        /// A word lifted off the page. Tapping it, or another reading, types that word.
        case picked
        /// The word the pair model expects next. Tapping it types that word and a space.
        case follow
        /// A word already in the document, shown so it can be corrected. Tapping it opens choices.
        case history
    }

    /// What a tap on this chip does. Nil chips keep the role's older meaning.
    public enum StripAction: Hashable, Sendable {
        case openHistory(Int)
        case openDocumentWord(Int)
        case closeDrill
        case replaceHistory(entry: Int, text: String)
        case replaceDocumentWord(index: Int, text: String)
        case retype(entry: Int)
        case merge(entry: Int)
        case capitalize(entry: Int, upper: Bool)
        case undoEdit
        case retireLearned
        case forgetLearned
        case blockLearned
        case insertText
        case replaceSuffix(match: String, with: String)
        case clipboard(ClipboardCommand)
        case toggleBoundary
    }

    public let text: String
    public let role: Role
    public let action: StripAction?
    /// The top two readings were close. The chip draws a dotted underline.
    public let unsure: Bool
    /// Why this chip differs from the word that landed. Nil for the word itself.
    public let difference: AlternativeKind?

    public init(
        _ text: String,
        role: Role,
        action: StripAction? = nil,
        unsure: Bool = false,
        difference: AlternativeKind? = nil
    ) {
        self.text = text
        self.role = role
        self.action = action
        self.unsure = unsure
        self.difference = difference
    }
}

/// Copy, cut, paste, and select word. Paste reads the pasteboard only when the chip is tapped.
public enum ClipboardCommand: Hashable, Sendable {
    case copy
    case cut
    case paste
    case selectWord
}

/// What the suggestion strip shows: at most three candidates, one possibly emphasized as the
/// word a space would accept.
public struct CandidateState: Hashable, Sendable {
    public static let capacity = 3
    /// Visible chips. The ring itself holds twelve words; older ones scroll in.
    public static let historyLimit = 8

    public let candidates: [Candidate]
    public let highlightedIndex: Int?
    /// A swipe still in progress: the words are a preview, not yet in the document.
    public let isTentative: Bool
    /// The bar is listing words already in the document, not guesses for the word being typed.
    public let isHistory: Bool
    /// A back chevron and one word's alternatives. Their order stays put until this closes.
    public let isDrilled: Bool

    public init(
        _ candidates: [Candidate],
        highlightedIndex: Int? = nil,
        isTentative: Bool = false,
        isHistory: Bool = false,
        isDrilled: Bool = false
    ) {
        let limit = (isHistory || isDrilled) ? Self.historyLimit : Self.capacity
        let kept = Array(candidates.prefix(limit))
        self.candidates = kept
        self.highlightedIndex = highlightedIndex.flatMap { kept.indices.contains($0) ? $0 : nil }
        self.isTentative = !kept.isEmpty && isTentative
        self.isHistory = !kept.isEmpty && isHistory
        self.isDrilled = !kept.isEmpty && isDrilled
    }

    /// A history chip does not take a tap while the row is still a live preview.
    public var allowsHistoryTap: Bool { !isTentative }

    public static let empty = CandidateState([])

    public var isEmpty: Bool { candidates.isEmpty }
}
