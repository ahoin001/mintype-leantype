import LeanTypeCore
import LeanTypeDesign
import SwiftUI

struct ThemePickerView: View {
    @Environment(\.pebbleTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SettingsModel.self) private var settings
    @State private var preview = PreviewKeyboardModel(settings: .default, placeholder: "Looks lovely")

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                KeyboardPlayground(model: preview)

                LazyVGrid(columns: columns, spacing: 14) {
                    swatch(.automatic, title: "Automatic", subtitle: "Cloud by day, Dusk by night")
                    ForEach(ThemeCatalog.all) { option in
                        swatch(option.id, title: option.name, subtitle: option.tagline)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .pebbleScreen()
        .navigationTitle("Themes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { preview.update(settings: settings.settings) }
    }

    private func swatch(_ id: ThemeIdentifier, title: String, subtitle: String) -> some View {
        let isSelected = settings.settings.theme == id
        let swatchTheme = ThemeCatalog.theme(for: id, prefersDark: colorScheme == .dark)
        return Button {
            withAnimation(Motion.playfulSpring) { settings.settings.theme = id }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ThemeSwatch(theme: swatchTheme)
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(theme.onAccent, theme.accent)
                                .padding(8)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.pebble(.headline, weight: .bold))
                        .foregroundStyle(theme.ink)
                    Text(subtitle)
                        .font(.pebble(.caption, weight: .medium))
                        .foregroundStyle(theme.subtleInk)
                        .lineLimit(2, reservesSpace: true)
                }
                .padding(.horizontal, 4)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(theme.surface.opacity(isSelected ? 1 : 0.6))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent : theme.surfaceRim, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(PebblePressStyle())
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A miniature keyboard drawn in a theme's colors.
private struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        VStack(spacing: 5) {
            row(count: 7)
            row(count: 6)
            HStack(spacing: 4) {
                key(theme.functionKey.fill.color).frame(width: 18)
                key(theme.letterKey.fill.color)
                key(theme.accentKey.fill.color).frame(width: 26)
            }
        }
        .padding(10)
        .frame(height: 86)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(
                    colors: [theme.backgroundTop.color, theme.backgroundBottom.color],
                    startPoint: .top,
                    endPoint: .bottom
                ))
        }
        .accessibilityHidden(true)
    }

    private func row(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { _ in
                key(theme.letterKey.fill.color)
            }
        }
    }

    private func key(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fill)
            .shadow(color: theme.keyShadow.color, radius: 0.5, y: 1)
    }
}
