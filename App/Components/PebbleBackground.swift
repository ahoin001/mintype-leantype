import SwiftUI

/// The calm backdrop behind every screen: the theme's soft gradient with two drifting-free,
/// static glows of accent color. Rendered once into a single layer.
struct PebbleBackground: View {
    @Environment(\.pebbleTheme) private var theme

    var body: some View {
        theme.backgroundGradient
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(theme.accent.opacity(theme.appearance == .dark ? 0.22 : 0.18))
                    .frame(width: 320, height: 320)
                    .blur(radius: 80)
                    .offset(x: 120, y: -140)
            }
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .fill(theme.accent.opacity(theme.appearance == .dark ? 0.12 : 0.1))
                    .frame(width: 280, height: 280)
                    .blur(radius: 90)
                    .offset(x: -120, y: 120)
            }
            .drawingGroup()
            .ignoresSafeArea()
    }
}

extension View {
    /// Places the view on the standard pebble backdrop.
    func pebbleScreen() -> some View {
        background { PebbleBackground() }
    }
}
