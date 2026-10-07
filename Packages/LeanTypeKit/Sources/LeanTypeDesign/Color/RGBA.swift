import UIKit

/// Platform-neutral sRGB color token. Themes are defined purely in these values so switching
/// themes never allocates image assets and the same palette drives UIKit and SwiftUI.
public struct RGBA: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Creates a color from a 24-bit `0xRRGGBB` literal.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    public static let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
}

public extension RGBA {
    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor {
        uiColor.cgColor
    }
}
