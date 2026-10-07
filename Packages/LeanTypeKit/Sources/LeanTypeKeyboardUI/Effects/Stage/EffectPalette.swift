import LeanTypeDesign
import UIKit

/// Colors effects draw with, derived from the theme so every flourish belongs to it.
struct EffectPalette {
    let accent: UIColor
    let ink: UIColor
    let isDark: Bool
    private let accentHue: CGFloat
    private let accentSaturation: CGFloat
    private let accentBrightness: CGFloat

    init(theme: Theme) {
        accent = theme.accentKey.fill.uiColor
        ink = theme.letterKey.label.uiColor
        isDark = theme.appearance == .dark
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        accentHue = hue
        accentSaturation = max(saturation, 0.45)
        accentBrightness = max(brightness, isDark ? 0.75 : 0.65)
    }

    /// The accent rotated around the color wheel by `turns` (0...1), keeping its softness.
    func shifted(by turns: CGFloat) -> UIColor {
        let hue = (accentHue + turns).truncatingRemainder(dividingBy: 1)
        return UIColor(hue: hue < 0 ? hue + 1 : hue, saturation: accentSaturation, brightness: accentBrightness, alpha: 1)
    }

    /// A pastel rainbow starting at the accent, for prism trails and celebrations.
    func prism(count: Int, offset: CGFloat = 0) -> [CGColor] {
        (0..<count).map { shifted(by: offset + CGFloat($0) / CGFloat(count)).cgColor }
    }
}
