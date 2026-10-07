import LeanTypeCore

/// A complete set of color tokens for the keyboard and the companion app.
///
/// Themes are value types made only of colors: switching themes recolors existing layers and
/// costs no additional memory.
public struct Theme: Hashable, Sendable, Identifiable {
    public enum Appearance: Hashable, Sendable {
        case light
        case dark
    }

    /// Colors for one family of keys (letters, function keys, or the accent key).
    public struct KeyColors: Hashable, Sendable {
        public let fill: RGBA
        public let pressedFill: RGBA
        public let label: RGBA
        /// Hairline rim that reads as light catching the top of a soft, puffy key.
        public let rim: RGBA

        public init(fill: RGBA, pressedFill: RGBA, label: RGBA, rim: RGBA) {
            self.fill = fill
            self.pressedFill = pressedFill
            self.label = label
            self.rim = rim
        }
    }

    public let id: ThemeIdentifier
    public let name: String
    public let tagline: String
    public let appearance: Appearance

    public let backgroundTop: RGBA
    public let backgroundBottom: RGBA

    public let letterKey: KeyColors
    public let functionKey: KeyColors
    public let accentKey: KeyColors

    /// Soft, tinted key shadow. Alpha is baked in so dark themes can nearly disable it.
    public let keyShadow: RGBA

    public let calloutFill: RGBA
    public let calloutLabel: RGBA
    public let selectionFill: RGBA
    public let selectionLabel: RGBA

    public let secondaryLabel: RGBA
    public let statusPillFill: RGBA

    public init(
        id: ThemeIdentifier,
        name: String,
        tagline: String,
        appearance: Appearance,
        backgroundTop: RGBA,
        backgroundBottom: RGBA,
        letterKey: KeyColors,
        functionKey: KeyColors,
        accentKey: KeyColors,
        keyShadow: RGBA,
        calloutFill: RGBA,
        calloutLabel: RGBA,
        selectionFill: RGBA,
        selectionLabel: RGBA,
        secondaryLabel: RGBA,
        statusPillFill: RGBA
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.appearance = appearance
        self.backgroundTop = backgroundTop
        self.backgroundBottom = backgroundBottom
        self.letterKey = letterKey
        self.functionKey = functionKey
        self.accentKey = accentKey
        self.keyShadow = keyShadow
        self.calloutFill = calloutFill
        self.calloutLabel = calloutLabel
        self.selectionFill = selectionFill
        self.selectionLabel = selectionLabel
        self.secondaryLabel = secondaryLabel
        self.statusPillFill = statusPillFill
    }
}
