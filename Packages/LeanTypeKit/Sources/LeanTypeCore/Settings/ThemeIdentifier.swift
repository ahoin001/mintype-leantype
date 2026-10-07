/// Stable, persistable identifier for a keyboard theme.
///
/// Kept as an open string wrapper (rather than an enum) so settings written by a newer app
/// version with themes this build doesn't know about still decode; unknown values resolve to
/// the automatic theme at render time.
public struct ThemeIdentifier: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Follows the system (and host field) light/dark appearance.
    public static let automatic: ThemeIdentifier = "automatic"
}
