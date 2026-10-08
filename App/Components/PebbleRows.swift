import LeanTypeDesign
import SwiftUI

/// A settings row with an icon, title, optional explanation, and a toggle.
struct PebbleToggleRow: View {
    @Environment(\.pebbleTheme) private var theme

    let systemImage: String
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .center, spacing: 14) {
                PebbleIcon(systemName: systemImage, size: 34)
                PebbleRowText(title: title, detail: detail)
            }
        }
        .tint(theme.accent)
        .padding(.vertical, 4)
    }
}

/// A row with an icon, title, and a segmented choice underneath.
struct PebblePickerRow<Value: Hashable>: View {
    let systemImage: String
    let title: String
    var detail: String?
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                PebbleIcon(systemName: systemImage, size: 34)
                PebbleRowText(title: title, detail: detail)
            }
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }
}

/// A choice shown as a row of icon tiles; the selected tile fills with the accent. For options
/// that deserve more presence than a segmented control.
struct PebbleOptionTiles<Value: Hashable>: View {
    struct Option {
        let label: String
        let systemImage: String
        let value: Value
    }

    @Environment(\.pebbleTheme) private var theme

    let title: String
    @Binding var selection: Value
    let options: [Option]
    /// When set, tiles wrap into this many columns. A single row is the default.
    var columns: Int? = nil

    var body: some View {
        Group {
            if let columns {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                    tiles
                }
            } else {
                HStack(spacing: 8) {
                    tiles
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var tiles: some View {
        ForEach(options, id: \.value) { option in
            tile(option, isSelected: option.value == selection)
        }
    }

    private func tile(_ option: Option, isSelected: Bool) -> some View {
        Button {
            withAnimation(Motion.gentleSpring) { selection = option.value }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .symbolEffect(.bounce, value: isSelected)
                Text(option.label)
                    .font(.pebble(.footnote, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? theme.onAccent : theme.chipInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? theme.accent : theme.chip)
                    .shadow(color: isSelected ? theme.accent.opacity(0.3) : .clear, radius: 8, y: 4)
            }
        }
        .buttonStyle(PebblePressStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A tappable navigation-style row with a trailing chevron.
struct PebbleLinkRow: View {
    @Environment(\.pebbleTheme) private var theme

    let systemImage: String
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 14) {
            PebbleIcon(systemName: systemImage, size: 34)
            PebbleRowText(title: title, detail: detail)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.subtleInk.opacity(0.7))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct PebbleRowText: View {
    @Environment(\.pebbleTheme) private var theme

    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.pebble(.body, weight: .semibold))
                .foregroundStyle(theme.ink)
            if let detail {
                Text(detail)
                    .font(.pebble(.footnote))
                    .foregroundStyle(theme.subtleInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Hairline divider tinted to the theme, inset past row icons.
struct PebbleDivider: View {
    @Environment(\.pebbleTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.subtleInk.opacity(0.15))
            .frame(height: 1)
            .padding(.leading, 48)
    }
}
