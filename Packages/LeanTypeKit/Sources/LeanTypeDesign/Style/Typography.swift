import UIKit

/// SF Pro Rounded everywhere: friendly, legible, and free (no bundled font files).
public enum Typography {
    public enum KeyRole: Sendable {
        case letter
        case symbol
        case function
        case callout
        case calloutAlternate
        case status
    }

    public static func keyFont(_ role: KeyRole, compact: Bool) -> UIFont {
        switch role {
        case .letter: rounded(size: compact ? 20 : 23, weight: .regular)
        case .symbol: rounded(size: compact ? 18 : 21, weight: .regular)
        case .function: rounded(size: compact ? 14 : 15.5, weight: .semibold)
        case .callout: rounded(size: compact ? 28 : 32, weight: .regular)
        case .calloutAlternate: rounded(size: compact ? 21 : 24, weight: .regular)
        case .status: rounded(size: 13, weight: .semibold)
        }
    }

    public static func symbolConfiguration(compact: Bool) -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: compact ? 16 : 18, weight: .medium, scale: .medium)
    }

    public static func rounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}