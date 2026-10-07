import SwiftUI

/// A soft, raised surface with continuous corners, a light-catching rim, and a tinted shadow
/// that matches the keyboard's keys.
struct PebbleCard<Content: View>: View {
    @Environment(\.pebbleTheme) private var theme

    var padding: CGFloat = 18
    var cornerRadius: CGFloat = 26
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(theme.surface)
                    .shadow(color: theme.shadow.opacity(0.6), radius: 14, y: 6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.surfaceRim, lineWidth: 1)
            }
    }
}

/// A rounded square holding an SF Symbol in the accent color, used for list and tile icons.
struct PebbleIcon: View {
    @Environment(\.pebbleTheme) private var theme

    let systemName: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.accent)
            .frame(width: size, height: size)
            .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Small uppercase-free section title in the theme's subtle ink.
struct PebbleSectionHeader: View {
    @Environment(\.pebbleTheme) private var theme

    let title: String

    var body: some View {
        Text(title)
            .font(.pebble(.subheadline, weight: .semibold))
            .foregroundStyle(theme.subtleInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}
