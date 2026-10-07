import LeanTypeCore

public extension ThemeIdentifier {
    static let cloud: ThemeIdentifier = "cloud"
    static let dusk: ThemeIdentifier = "dusk"
    static let midnight: ThemeIdentifier = "midnight"
    static let peach: ThemeIdentifier = "peach"
    static let mint: ThemeIdentifier = "mint"
}

/// The built-in "Soft Pebble" palettes and the rules for resolving a user's choice.
public enum ThemeCatalog {
    public static let all: [Theme] = [cloud, dusk, midnight, peach, mint]

    /// Resolves a stored preference to a concrete theme. `automatic` (and any identifier this
    /// build doesn't recognize) follows the current light/dark appearance.
    public static func theme(for identifier: ThemeIdentifier, prefersDark: Bool) -> Theme {
        if let match = all.first(where: { $0.id == identifier }) {
            return match
        }
        return prefersDark ? dusk : cloud
    }

    // MARK: - Palettes

    public static let cloud = Theme(
        id: .cloud,
        name: "Cloud",
        tagline: "Warm white with a lilac glow",
        appearance: .light,
        backgroundTop: RGBA(hex: 0xF5F1FA),
        backgroundBottom: RGBA(hex: 0xECE6F5),
        letterKey: .init(
            fill: RGBA(hex: 0xFFFFFF),
            pressedFill: RGBA(hex: 0xEDE6F9),
            label: RGBA(hex: 0x372E4D),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.9)
        ),
        functionKey: .init(
            fill: RGBA(hex: 0xE3DAF1),
            pressedFill: RGBA(hex: 0xFFFFFF),
            label: RGBA(hex: 0x4A3F66),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.55)
        ),
        accentKey: .init(
            fill: RGBA(hex: 0x9C80E6),
            pressedFill: RGBA(hex: 0x876BD6),
            label: RGBA(hex: 0xFFFFFF),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.25)
        ),
        keyShadow: RGBA(hex: 0x5E4C86, alpha: 0.2),
        calloutFill: RGBA(hex: 0xFFFFFF),
        calloutLabel: RGBA(hex: 0x372E4D),
        selectionFill: RGBA(hex: 0x9C80E6),
        selectionLabel: RGBA(hex: 0xFFFFFF),
        secondaryLabel: RGBA(hex: 0x8A80A2),
        statusPillFill: RGBA(hex: 0xFFFFFF, alpha: 0.7)
    )

    public static let dusk = Theme(
        id: .dusk,
        name: "Dusk",
        tagline: "Soft plum for evenings",
        appearance: .dark,
        backgroundTop: RGBA(hex: 0x2B2539),
        backgroundBottom: RGBA(hex: 0x221D2E),
        letterKey: .init(
            fill: RGBA(hex: 0x3D3552),
            pressedFill: RGBA(hex: 0x4D4466),
            label: RGBA(hex: 0xF3EEFC),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.07)
        ),
        functionKey: .init(
            fill: RGBA(hex: 0x312A43),
            pressedFill: RGBA(hex: 0x4D4466),
            label: RGBA(hex: 0xD9D0EC),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.05)
        ),
        accentKey: .init(
            fill: RGBA(hex: 0xC2A8FF),
            pressedFill: RGBA(hex: 0xAE90F5),
            label: RGBA(hex: 0x241B38),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.2)
        ),
        keyShadow: RGBA(hex: 0x0E0A16, alpha: 0.45),
        calloutFill: RGBA(hex: 0x4D4466),
        calloutLabel: RGBA(hex: 0xF3EEFC),
        selectionFill: RGBA(hex: 0xC2A8FF),
        selectionLabel: RGBA(hex: 0x241B38),
        secondaryLabel: RGBA(hex: 0xA79EBD),
        statusPillFill: RGBA(hex: 0x3D3552, alpha: 0.85)
    )

    public static let midnight = Theme(
        id: .midnight,
        name: "Midnight",
        tagline: "True black, easy on OLED",
        appearance: .dark,
        backgroundTop: RGBA(hex: 0x000000),
        backgroundBottom: RGBA(hex: 0x000000),
        letterKey: .init(
            fill: RGBA(hex: 0x1B1A21),
            pressedFill: RGBA(hex: 0x2C2A35),
            label: RGBA(hex: 0xF4F3F8),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.06)
        ),
        functionKey: .init(
            fill: RGBA(hex: 0x111015),
            pressedFill: RGBA(hex: 0x2C2A35),
            label: RGBA(hex: 0xC9C6D6),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.05)
        ),
        accentKey: .init(
            fill: RGBA(hex: 0x8C7BFF),
            pressedFill: RGBA(hex: 0x7766EB),
            label: RGBA(hex: 0xFFFFFF),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.15)
        ),
        keyShadow: .clear,
        calloutFill: RGBA(hex: 0x2C2A35),
        calloutLabel: RGBA(hex: 0xF4F3F8),
        selectionFill: RGBA(hex: 0x8C7BFF),
        selectionLabel: RGBA(hex: 0xFFFFFF),
        secondaryLabel: RGBA(hex: 0x8E8A9E),
        statusPillFill: RGBA(hex: 0x1B1A21)
    )

    public static let peach = Theme(
        id: .peach,
        name: "Peach",
        tagline: "Sunlit apricot, gentle and warm",
        appearance: .light,
        backgroundTop: RGBA(hex: 0xFFF3EC),
        backgroundBottom: RGBA(hex: 0xFCE7DB),
        letterKey: .init(
            fill: RGBA(hex: 0xFFFFFF),
            pressedFill: RGBA(hex: 0xFFE4D6),
            label: RGBA(hex: 0x4A2E27),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.9)
        ),
        functionKey: .init(
            fill: RGBA(hex: 0xF9D9C8),
            pressedFill: RGBA(hex: 0xFFFFFF),
            label: RGBA(hex: 0x6B4237),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.55)
        ),
        accentKey: .init(
            fill: RGBA(hex: 0xF4896B),
            pressedFill: RGBA(hex: 0xE2765A),
            label: RGBA(hex: 0xFFFFFF),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.25)
        ),
        keyShadow: RGBA(hex: 0xB0634D, alpha: 0.2),
        calloutFill: RGBA(hex: 0xFFFFFF),
        calloutLabel: RGBA(hex: 0x4A2E27),
        selectionFill: RGBA(hex: 0xF4896B),
        selectionLabel: RGBA(hex: 0xFFFFFF),
        secondaryLabel: RGBA(hex: 0xA57D71),
        statusPillFill: RGBA(hex: 0xFFFFFF, alpha: 0.7)
    )

    public static let mint = Theme(
        id: .mint,
        name: "Mint",
        tagline: "Cool sea-glass calm",
        appearance: .light,
        backgroundTop: RGBA(hex: 0xEEF9F4),
        backgroundBottom: RGBA(hex: 0xE1F2EA),
        letterKey: .init(
            fill: RGBA(hex: 0xFFFFFF),
            pressedFill: RGBA(hex: 0xD8F1E5),
            label: RGBA(hex: 0x1F3F37),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.9)
        ),
        functionKey: .init(
            fill: RGBA(hex: 0xCFEBDE),
            pressedFill: RGBA(hex: 0xFFFFFF),
            label: RGBA(hex: 0x2F5A4F),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.55)
        ),
        accentKey: .init(
            fill: RGBA(hex: 0x3FB894),
            pressedFill: RGBA(hex: 0x33A381),
            label: RGBA(hex: 0xFFFFFF),
            rim: RGBA(hex: 0xFFFFFF, alpha: 0.25)
        ),
        keyShadow: RGBA(hex: 0x2E7A63, alpha: 0.18),
        calloutFill: RGBA(hex: 0xFFFFFF),
        calloutLabel: RGBA(hex: 0x1F3F37),
        selectionFill: RGBA(hex: 0x3FB894),
        selectionLabel: RGBA(hex: 0xFFFFFF),
        secondaryLabel: RGBA(hex: 0x6C9086),
        statusPillFill: RGBA(hex: 0xFFFFFF, alpha: 0.7)
    )
}
