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

    public let text: String
    public let role: Role

    public init(_ text: String, role: Role) {
        self.text = text
        self.role = role
    }
}

/// What the suggestion strip shows: at most three candidates, one possibly emphasized as the
/// word a space would accept.
public struct CandidateState: Hashable, Sendable {
    public static let capacity = 3
    public static let historyLimit = 6

    public let candidates: [Candidate]
    public let highlightedIndex: Int?
    /// A swipe still in progress: the words are a preview, not yet in the document.
    public let isTentative: Bool
    /// The bar is listing words already in the document, not guesses for the word being typed.
    public let isHistory: Bool

    public init(_ candidates: [Candidate], highlightedIndex: Int? = nil, isTentative: Bool = false, isHistory: Bool = false) {
        let limit = isHistory ? Self.historyLimit : Self.capacity
        let kept = Array(candidates.prefix(limit))
        self.candidates = kept
        self.highlightedIndex = highlightedIndex.flatMap { kept.indices.contains($0) ? $0 : nil }
        self.isTentative = !kept.isEmpty && isTentative
        self.isHistory = !kept.isEmpty && isHistory
    }

    public static let empty = CandidateState([])

    public var isEmpty: Bool { candidates.isEmpty }
}
