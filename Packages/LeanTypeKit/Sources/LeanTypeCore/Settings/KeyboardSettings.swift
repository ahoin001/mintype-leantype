public enum BackspaceTapAction: String, Codable, Sendable, CaseIterable {
    /// Nintype-style: a single tap removes the previous word.
    case deleteWord
    /// Conventional: a single tap removes one character.
    case deleteCharacter
}

/// When a swipe becomes a finished word.
public enum SwipeCommitMode: String, Codable, Sendable, CaseIterable {
    /// The word lands on lift. A short leash can still absorb the next letter.
    case lift
    /// Beats stay one word until space, return, or an edit from outside the keyboard.
    case explicitSpace
}

/// How letter keys interpret touches.
public enum TypingModeSetting: String, Codable, Sendable, CaseIterable {
    /// Every touch is a tap.
    case tap
    /// Taps still type letters; sliding across letters (with one finger or two thumbs) types a word.
    case swipe
}

public enum KeyboardHeight: String, Codable, Sendable, CaseIterable {
    case compact
    case regular
    case tall

    /// Multiplier applied to key height and row spacing.
    public var scale: Double {
        switch self {
        case .compact: 0.9
        case .regular: 1
        case .tall: 1.1
        }
    }
}

public enum OneHandedMode: String, Codable, Sendable, CaseIterable {
    case off
    case left
    case right
}

/// How much visual flair the keyboard shows.
public struct EffectsSettings: Codable, Sendable, Equatable {
    public enum Intensity: String, Codable, Sendable, CaseIterable {
        case off
        case subtle
        case lively
        case party

        /// Scale applied to effect size, opacity, and particle counts.
        public var scale: Double {
            switch self {
            case .off: 0
            case .subtle: 0.6
            case .lively: 1
            case .party: 1.35
            }
        }
    }

    /// A ring around the finger and the trail that leaves from the bead behind it.
    public enum TrailStyle: String, Codable, Sendable, CaseIterable {
        /// A breathing ring and a short accent ribbon.
        case lantern
        /// Three thin rings and a rainbow ribbon.
        case prism
        /// A bright bead on the rim and a tail of soft beads.
        case comet
        /// Glints sparking off the trailing bead.
        case constellation
        /// A coal on the rim and sparks that drift upward.
        case ember
        /// A pearl on the rim and a ribbon whose edges lag apart.
        case silk

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            switch raw {
            case "theme", "lantern": self = .lantern
            case "brush", "silk": self = .silk
            case "prism": self = .prism
            case "comet": self = .comet
            case "constellation": self = .constellation
            case "ember": self = .ember
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown swipe look \(raw)"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var intensity: Intensity
    public var trailStyle: TrailStyle
    public var celebrateMilestones: Bool

    public init(intensity: Intensity = .lively, trailStyle: TrailStyle = .lantern, celebrateMilestones: Bool = true) {
        self.intensity = intensity
        self.trailStyle = trailStyle
        self.celebrateMilestones = celebrateMilestones
    }

    public static let `default` = EffectsSettings()

    private enum CodingKeys: String, CodingKey {
        case intensity
        case trailStyle
        case celebrateMilestones
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = LenientDecoder(container)
        let defaults = Self.default
        intensity = lenient.value(.intensity, defaults.intensity)
        trailStyle = lenient.value(.trailStyle, defaults.trailStyle)
        celebrateMilestones = lenient.value(.celebrateMilestones, defaults.celebrateMilestones)
    }
}

/// Every user-configurable keyboard option, shared between the companion app and the extension
/// as one versioned JSON blob.
public struct KeyboardSettings: Codable, Sendable, Equatable {
    /// 2: effects, typing mode, suggestions, smart punctuation, flicks, size, one-handed.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var theme: ThemeIdentifier
    public var backspaceTapAction: BackspaceTapAction
    public var hapticsEnabled: Bool
    public var keyClicksEnabled: Bool
    public var autoCapitalizationEnabled: Bool
    public var doubleSpacePeriodEnabled: Bool
    public var keyPreviewsEnabled: Bool
    public var smartPunctuationEnabled: Bool
    public var flickForSecondaryEnabled: Bool
    public var secondaryHintsVisible: Bool
    public var typingMode: TypingModeSetting
    public var suggestionsEnabled: Bool
    public var autocorrectEnabled: Bool
    /// A quick tap can still lengthen a word that just landed, when the letters spell a longer word.
    /// A swipe that is already its own word always starts the next word.
    public var extendFinishedWords: Bool
    /// Lift commits the word and starts a leash. Explicit space keeps one word open until space.
    public var swipeCommitMode: SwipeCommitMode
    /// Nil follows the typing rhythm. A number is the leash, in seconds, clamped when used.
    public var leashDuration: Double?
    /// Remember words the dictionary doesn't know. Only takes effect with Full Access.
    public var learnWordsEnabled: Bool
    public var height: KeyboardHeight
    public var oneHandedMode: OneHandedMode
    public var effects: EffectsSettings
    /// Hold-and-slide rows the user has edited, keyed by a lowercase letter. A missing key
    /// keeps the built-in accents. An empty row means holding that letter types nothing extra.
    public var keyShortcuts: [String: [String]]

    public init(
        theme: ThemeIdentifier = .automatic,
        backspaceTapAction: BackspaceTapAction = .deleteWord,
        hapticsEnabled: Bool = true,
        keyClicksEnabled: Bool = true,
        autoCapitalizationEnabled: Bool = true,
        doubleSpacePeriodEnabled: Bool = true,
        keyPreviewsEnabled: Bool = true,
        smartPunctuationEnabled: Bool = true,
        flickForSecondaryEnabled: Bool = true,
        secondaryHintsVisible: Bool = true,
        typingMode: TypingModeSetting = .swipe,
        suggestionsEnabled: Bool = true,
        autocorrectEnabled: Bool = true,
        extendFinishedWords: Bool = true,
        swipeCommitMode: SwipeCommitMode = .lift,
        leashDuration: Double? = nil,
        learnWordsEnabled: Bool = true,
        height: KeyboardHeight = .regular,
        oneHandedMode: OneHandedMode = .off,
        effects: EffectsSettings = .default,
        keyShortcuts: [String: [String]] = [:]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.theme = theme
        self.backspaceTapAction = backspaceTapAction
        self.hapticsEnabled = hapticsEnabled
        self.keyClicksEnabled = keyClicksEnabled
        self.autoCapitalizationEnabled = autoCapitalizationEnabled
        self.doubleSpacePeriodEnabled = doubleSpacePeriodEnabled
        self.keyPreviewsEnabled = keyPreviewsEnabled
        self.smartPunctuationEnabled = smartPunctuationEnabled
        self.flickForSecondaryEnabled = flickForSecondaryEnabled
        self.secondaryHintsVisible = secondaryHintsVisible
        self.typingMode = typingMode
        self.suggestionsEnabled = suggestionsEnabled
        self.autocorrectEnabled = autocorrectEnabled
        self.extendFinishedWords = extendFinishedWords
        self.swipeCommitMode = swipeCommitMode
        self.leashDuration = leashDuration
        self.learnWordsEnabled = learnWordsEnabled
        self.height = height
        self.oneHandedMode = oneHandedMode
        self.effects = effects
        self.keyShortcuts = keyShortcuts
    }

    public static let `default` = KeyboardSettings()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case theme
        case backspaceTapAction
        case hapticsEnabled
        case keyClicksEnabled
        case autoCapitalizationEnabled
        case doubleSpacePeriodEnabled
        case keyPreviewsEnabled
        case smartPunctuationEnabled
        case flickForSecondaryEnabled
        case secondaryHintsVisible
        case typingMode
        case suggestionsEnabled
        case autocorrectEnabled
        case extendFinishedWords
        case swipeCommitMode
        case leashDuration
        case learnWordsEnabled
        case height
        case oneHandedMode
        case effects
        case keyShortcuts
    }

    /// Decodes leniently: missing or unreadable fields fall back to defaults, so older blobs
    /// gain new options and a single bad value never resets everything else.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = LenientDecoder(container)
        let defaults = KeyboardSettings.default

        schemaVersion = Self.currentSchemaVersion
        theme = lenient.value(.theme, defaults.theme)
        backspaceTapAction = lenient.value(.backspaceTapAction, defaults.backspaceTapAction)
        hapticsEnabled = lenient.value(.hapticsEnabled, defaults.hapticsEnabled)
        keyClicksEnabled = lenient.value(.keyClicksEnabled, defaults.keyClicksEnabled)
        autoCapitalizationEnabled = lenient.value(.autoCapitalizationEnabled, defaults.autoCapitalizationEnabled)
        doubleSpacePeriodEnabled = lenient.value(.doubleSpacePeriodEnabled, defaults.doubleSpacePeriodEnabled)
        keyPreviewsEnabled = lenient.value(.keyPreviewsEnabled, defaults.keyPreviewsEnabled)
        smartPunctuationEnabled = lenient.value(.smartPunctuationEnabled, defaults.smartPunctuationEnabled)
        flickForSecondaryEnabled = lenient.value(.flickForSecondaryEnabled, defaults.flickForSecondaryEnabled)
        secondaryHintsVisible = lenient.value(.secondaryHintsVisible, defaults.secondaryHintsVisible)
        typingMode = lenient.value(.typingMode, defaults.typingMode)
        suggestionsEnabled = lenient.value(.suggestionsEnabled, defaults.suggestionsEnabled)
        autocorrectEnabled = lenient.value(.autocorrectEnabled, defaults.autocorrectEnabled)
        extendFinishedWords = lenient.value(.extendFinishedWords, defaults.extendFinishedWords)
        swipeCommitMode = lenient.value(.swipeCommitMode, defaults.swipeCommitMode)
        leashDuration = lenient.value(.leashDuration, defaults.leashDuration)
        learnWordsEnabled = lenient.value(.learnWordsEnabled, defaults.learnWordsEnabled)
        height = lenient.value(.height, defaults.height)
        oneHandedMode = lenient.value(.oneHandedMode, defaults.oneHandedMode)
        effects = lenient.value(.effects, defaults.effects)
        keyShortcuts = lenient.value(.keyShortcuts, defaults.keyShortcuts)
    }
}

/// Reads optional values from a keyed container, substituting a fallback for anything
/// missing or malformed.
struct LenientDecoder<Key: CodingKey> {
    private let container: KeyedDecodingContainer<Key>

    init(_ container: KeyedDecodingContainer<Key>) {
        self.container = container
    }

    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
