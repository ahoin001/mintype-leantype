import SwiftUI

/// Pill buttons that squish slightly under the finger and spring back.
struct PebbleButtonStyle: ButtonStyle {
    enum Prominence {
        case primary
        case secondary
    }

    @Environment(\.pebbleTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var prominence: Prominence = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pebble(.headline, weight: .semibold))
            .foregroundStyle(prominence == .primary ? theme.onAccent : theme.chipInk)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background {
                Capsule(style: .continuous)
                    .fill(prominence == .primary ? theme.accent : theme.chip)
                    .shadow(color: prominence == .primary ? theme.accent.opacity(0.35) : .clear, radius: 12, y: 6)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PebbleButtonStyle {
    static var pebble: PebbleButtonStyle { PebbleButtonStyle() }
    static var pebbleSecondary: PebbleButtonStyle { PebbleButtonStyle(prominence: .secondary) }
}

/// Feedback for tappable cards and tiles: a gentle squish, no color flash.
struct PebblePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
