/// Which flavor of the layout to show, derived from the host field's keyboard type.
public enum KeyboardVariant: Hashable, Sendable {
    case standard
    case email
    case url
    /// Fields that primarily want digits; the keyboard opens on the numbers page.
    case numeric
}

public enum AutocapitalizationMode: Hashable, Sendable {
    case none
    case words
    case sentences
    case allCharacters
}

public enum ReturnKeyKind: Hashable, Sendable {
    case `default`
    case go
    case join
    case next
    case route
    case search
    case send
    case done
    case emergencyCall
    case `continue`

    public var title: String {
        switch self {
        case .default: "return"
        case .go: "go"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .search: "search"
        case .send: "send"
        case .done: "done"
        case .emergencyCall: "SOS"
        case .continue: "continue"
        }
    }

    /// Action-style return keys get the theme accent; a plain newline stays neutral.
    public var isProminent: Bool {
        self != .default
    }
}

/// UIKit-free snapshot of the host text field's input traits.
public struct InputTraits: Hashable, Sendable {
    public var variant: KeyboardVariant
    public var autocapitalization: AutocapitalizationMode
    public var returnKey: ReturnKeyKind
    public var enablesReturnKeyAutomatically: Bool
    /// The host allows autocorrect (`autocorrectionType` is not `.no`).
    public var allowsAutocorrection: Bool
    /// Passwords, usernames, and one-time codes must be entered exactly.
    public var blocksLexicalEntry: Bool

    public init(
        variant: KeyboardVariant = .standard,
        autocapitalization: AutocapitalizationMode = .sentences,
        returnKey: ReturnKeyKind = .default,
        enablesReturnKeyAutomatically: Bool = false,
        allowsAutocorrection: Bool = true,
        blocksLexicalEntry: Bool = false
    ) {
        self.variant = variant
        self.autocapitalization = autocapitalization
        self.returnKey = returnKey
        self.enablesReturnKeyAutomatically = enablesReturnKeyAutomatically
        self.allowsAutocorrection = allowsAutocorrection
        self.blocksLexicalEntry = blocksLexicalEntry
    }

    public static let `default` = InputTraits()

    /// Whether autocorrect and suggestions suit this field.
    public var supportsLanguageFeatures: Bool {
        allowsAutocorrection && !blocksLexicalEntry && variant == .standard
    }

    /// Swipe is an input method. Search bars and URL fields turn autocorrect off and still have letter keys.
    public var supportsSwipe: Bool {
        variant != .numeric && !blocksLexicalEntry
    }
}
