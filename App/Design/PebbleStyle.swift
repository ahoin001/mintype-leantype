import LeanTypeDesign
import SwiftUI

extension RGBA {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension Font {
    /// Rounded system font that scales with Dynamic Type, matching the keyboard's SF Pro Rounded.
    static func pebble(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

extension Motion {
    /// Critically damped spring for occasional UI movement.
    static let gentleSpring = Animation.spring(response: 0.35, dampingFraction: 1)
    /// Slightly bouncy spring reserved for playful, rare moments (onboarding, selection).
    static let playfulSpring = Animation.spring(response: 0.4, dampingFraction: 0.78)
}
