import LeanTypeCore
import LeanTypeDesign
import SwiftUI

/// How much the keyboard celebrates your typing, with the real keyboard right there to try
/// each setting on.
struct FlairView: View {
    @Environment(\.pebbleTheme) private var theme
    @Environment(SettingsModel.self) private var model
    @State private var preview = PreviewKeyboardModel()

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    PebbleSectionHeader(title: "Try it")
                    KeyboardPlayground(model: preview, prompt: "Swipe a word, then tap delete")
                }

                section("Intensity", detail: intensityDetail) {
                    PebbleOptionTiles(
                        title: "Intensity",
                        selection: $model.settings.effects.intensity,
                        options: [
                            .init(label: "Off", systemImage: "moon", value: .off),
                            .init(label: "Subtle", systemImage: "sparkle", value: .subtle),
                            .init(label: "Lively", systemImage: "sparkles", value: .lively),
                            .init(label: "Party", systemImage: "party.popper", value: .party),
                        ]
                    )
                }

                section("Swipe trail", detail: "The ribbon that follows your finger when you swipe a word.") {
                    PebbleOptionTiles(
                        title: "Swipe trail",
                        selection: $model.settings.effects.trailStyle,
                        options: [
                            .init(label: "Theme", systemImage: "paintbrush.pointed", value: .theme),
                            .init(label: "Prism", systemImage: "rainbow", value: .prism),
                        ]
                    )
                    .disabled(model.settings.effects.intensity == .off)
                }

                PebbleCard(padding: 16) {
                    PebbleToggleRow(
                        systemImage: "star.circle",
                        title: "Celebrate streaks",
                        detail: "A burst of sparkles every 25 words typed without a backspace.",
                        isOn: $model.settings.effects.celebrateMilestones
                    )
                }
                .disabled(model.settings.effects.intensity == .off)

                Label(
                    "Effects calm down by themselves in Low Power Mode, when your phone runs warm, and with Reduce Motion on.",
                    systemImage: "leaf"
                )
                .font(.pebble(.footnote))
                .foregroundStyle(theme.subtleInk)
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .pebbleScreen()
        .navigationTitle("Flair")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intensityDetail: String {
        switch model.settings.effects.intensity {
        case .off: "Just the keys. Nothing moves that you didn't move."
        case .subtle: "Every effect, softly: smaller ripples, lighter trails, quieter bursts."
        case .lively: "Ripples under your fingers, a gust of wind for deleted words, a comet on the space bar, and a glow as you find your rhythm."
        case .party: "Everything, turned up. Bigger bursts, brighter trails."
        }
    }

    private func section(_ title: String, detail: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            PebbleSectionHeader(title: title)
            PebbleCard(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                    Text(detail)
                        .font(.pebble(.footnote))
                        .foregroundStyle(theme.subtleInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .animation(Motion.gentleSpring, value: detail)
                }
            }
        }
    }
}
