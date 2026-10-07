public enum BackspaceTapAction: String, Codable, Sendable, CaseIterable {
    /// Nintype-style: a single tap removes the previous word.
    case deleteWord
    /// Conventional: a single tap removes one character.
    case deleteCharacter
}

/// Every user-configurable keyboard option, shared between the companion app and the extension
/// as one versioned JSON blob.
public struct KeyboardSettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var theme: ThemeIdentifier
    public var backspaceTapAction: BackspaceTapAction
    public var hapticsEnabled: Bool
    public var keyClicksEnabled: Bool
    public var autoCapitalizationEnabled: Bool
    public var doubleSpacePeriodEnabled: Bool
    public var keyPreviewsEnabled: Bool

    public init(
        theme: ThemeIdentifier = .automatic,
        backspaceTapAction: BackspaceTapAction = .deleteWord,
        hapticsEnabled: Bool = true,
        keyClicksEnabled: Bool = true,
        autoCapitalizationEnabled: Bool = true,
        doubleSpacePeriodEnabled: Bool = true,
        keyPreviewsEnabled: Bool = true
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.theme = theme
        self.backspaceTapAction = backspaceTapAction
        self.hapticsEnabled = hapticsEnabled
        self.keyClicksEnabled = keyClicksEnabled
        self.autoCapitalizationEnabled = autoCapitalizationEnabled
        self.doubleSpacePeriodEnabled = doubleSpacePeriodEnabled
        self.keyPreviewsEnabled = keyPreviewsEnabled
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
    }

    /// Decodes leniently: missing or unreadable fields fall back to defaults, so older blobs
    /// gain new options and a single bad value never resets everything else.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = KeyboardSettings.default

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        schemaVersion = Self.currentSchemaVersion
        theme = value(.theme, defaults.theme)
        backspaceTapAction = value(.backspaceTapAction, defaults.backspaceTapAction)
        hapticsEnabled = value(.hapticsEnabled, defaults.hapticsEnabled)
        keyClicksEnabled = value(.keyClicksEnabled, defaults.keyClicksEnabled)
        autoCapitalizationEnabled = value(.autoCapitalizationEnabled, defaults.autoCapitalizationEnabled)
        doubleSpacePeriodEnabled = value(.doubleSpacePeriodEnabled, defaults.doubleSpacePeriodEnabled)
        keyPreviewsEnabled = value(.keyPreviewsEnabled, defaults.keyPreviewsEnabled)
    }
}
