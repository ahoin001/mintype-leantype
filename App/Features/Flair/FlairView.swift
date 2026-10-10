import LeanTypeCore
import LeanTypeDesign
import SwiftUI

/// What the keyboard draws besides the keys, grouped by when it happens.
struct FlairView: View {
    @Environment(\.pebbleTheme) private var theme
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let effectsOn = model.settings.effects.intensity != .off

        ScrollView {
            VStack(spacing: 22) {
                section("Amount") {
                    PebbleOptionTiles(
                        title: "Amount",
                        selection: $model.settings.effects.intensity,
                        options: [
                            .init(label: "Off", systemImage: "moon", value: .off),
                            .init(label: "Subtle", systemImage: "sparkle", value: .subtle),
                            .init(label: "Lively", systemImage: "sparkles", value: .lively),
                            .init(label: "Party", systemImage: "party.popper", value: .party),
                        ]
                    )
                    note(intensityDetail)
                }

                section("While you type") {
                    effect(
                        "circle.circle",
                        title: "Ripples",
                        detail: "A ring opens from the key you touch. In a steady rhythm, each ring takes the next color."
                    )
                    PebbleDivider()
                    VStack(alignment: .leading, spacing: 14) {
                        effect(
                            "smallcircle.filled.circle",
                            title: "Swipe",
                            detail: "A ring sits around your finger, where the touch itself would hide a glow. The trail leaves from the bright point behind that ring, then folds into the bar when you lift. Each thumb keeps its own color."
                        )
                        PebbleOptionTiles(
                            title: "Swipe look",
                            selection: $model.settings.effects.trailStyle,
                            options: [
                                .init(label: "Lantern", systemImage: "circle.circle", value: .lantern),
                                .init(label: "Comet", systemImage: "sparkle", value: .comet),
                                .init(label: "Prism", systemImage: "rainbow", value: .prism),
                                .init(label: "Stars", systemImage: "sparkles", value: .constellation),
                                .init(label: "Ember", systemImage: "flame", value: .ember),
                                .init(label: "Silk", systemImage: "scribble.variable", value: .silk),
                            ],
                            columns: 3
                        )
                        .disabled(!effectsOn)
                        note(swipeLookDetail)
                    }
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "wand.and.stars",
                        title: "Spectacle",
                        detail: "Letters you collect lift into the stroke and land in the bar. A fast rhythm leaves a brighter trail. The keys do not move.",
                        isOn: $model.settings.effects.spectacle
                    )
                    .disabled(!effectsOn)
                    PebbleDivider()
                    effect(
                        "sun.max",
                        title: "Rhythm glow",
                        detail: "The space behind the keys warms as your typing finds a rhythm. The LeanType wordmark warms with it, and cools when you pause."
                    )
                }

                section("Bursts") {
                    effect(
                        "wind",
                        title: "Deleted words",
                        detail: "Removing a word blows its letters off the delete key. Swipe right on delete and they blow back."
                    )
                    PebbleDivider()
                    effect(
                        "cursorarrow.motionlines",
                        title: "Space bar",
                        detail: "While you slide on space to move the cursor, a comet rides along the bar with it."
                    )
                    PebbleDivider()
                    effect(
                        "sparkles",
                        title: "End of a sentence",
                        detail: "A double-space period throws a short burst of sparkles from where you tapped."
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "star.circle",
                        title: "Clean streaks",
                        detail: "Every 25 words without a delete, a bigger burst and the count in the bar above the keys.",
                        isOn: $model.settings.effects.celebrateMilestones
                    )
                    .disabled(!effectsOn)
                }

                section("What stays on") {
                    effect(
                        "capslock",
                        title: "Caps lock",
                        detail: "A ring settles around shift and stays until caps lock turns off."
                    )
                    note("Low Power Mode, Reduce Motion, or a warm phone keep the rhythm glow, the caps-lock ring, and the ring around a swiping finger. The swipe trail, ripples, bursts, and the space-bar comet pause.")
                    note("A very hot phone turns all of it off. After a memory warning, effects return the next time the keyboard opens.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .pebbleScreen()
        .navigationTitle("Flair")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var swipeLookDetail: String {
        switch model.settings.effects.trailStyle {
        case .lantern: "A quiet ring in this keyboard’s accent, with a short ribbon behind it."
        case .comet: "A bright bead on the ring, and a tail of soft beads."
        case .prism: "Three thin rings and a rainbow ribbon. The rings spread when you turn."
        case .constellation: "Glints spark off the bead behind your finger."
        case .ember: "A coal on the ring. Sparks drift up off the path."
        case .silk: "A pearl on the ring, and a ribbon that folds when you turn."
        }
    }

    private var intensityDetail: String {
        switch model.settings.effects.intensity {
        case .off: "Nothing extra. The keys stay still."
        case .subtle: "Every effect below, drawn smaller and quieter."
        case .lively: "The usual size."
        case .party: "Larger bursts and brighter trails."
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            PebbleSectionHeader(title: title)
            PebbleCard(padding: 16) {
                VStack(alignment: .leading, spacing: 14, content: content)
            }
        }
    }

    private func effect(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PebbleIcon(systemName: symbol, size: 34)
            PebbleRowText(title: title, detail: detail)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.pebble(.footnote))
            .foregroundStyle(theme.subtleInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}
