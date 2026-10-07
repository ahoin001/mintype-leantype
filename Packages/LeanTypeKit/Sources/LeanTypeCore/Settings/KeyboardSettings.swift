public enum BackspaceTapAction: String, Codable, Sendable, CaseIterable {
    /// Nintype-style: a single tap removes the previous word.
    case deleteWord
    /// Conventional: a single tap removes one character.
    case deleteCharacter
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

    public enum TrailStyle: String, Codable, Sendable, CaseIterable {
        /// The theme's accent color.
        case theme
        /// A shifting rainbow.
        case prism
    }

    public var intensity: Intensity
    public var trailStyle: TrailStyle
    public var celebrateMilestones: Bool

    public init(intensity: Intensity = .lively, trailStyle: TrailStyle = .theme, celebrateMilestones: Bool = true) {
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
    /// Remember words the dictionary doesn't know. Only takes effect with Full Access.
    public var learnWordsEnabled: Bool
    public var height: KeyboardHeight
    public var oneHandedMode: OneHandedMode
    public var effects: EffectsSettings

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
        learnWordsEnabled: Bool = true,
        height: KeyboardHeight = .regular,
        oneHandedMode: OneHandedMode = .off,
        effects: EffectsSettings = .default
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
        self.learnWordsEnabled = learnWordsEnabled
        self.height = height
        self.oneHandedMode = oneHandedMode
        self.effects = effects
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
        case learnWordsEnabled
        case height
        case oneHandedMode
        case effects
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
        learnWordsEnabled = lenient.value(.learnWordsEnabled, defaults.learnWordsEnabled)
        height = lenient.value(.height, defaults.height)
        oneHandedMode = lenient.value(.oneHandedMode, defaults.oneHandedMode)
        effects = lenient.value(.effects, defaults.effects)
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
