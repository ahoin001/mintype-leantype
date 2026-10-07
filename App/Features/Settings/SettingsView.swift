import LeanTypeCore
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsModel.self) private var model
    @Environment(SetupStatusModel.self) private var setup

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(spacing: 22) {
                section("Typing") {
                    PebblePickerRow(
                        systemImage: "delete.left",
                        title: "A tap on delete removes",
                        detail: "Swipe left on delete to erase letters, right to bring them back.",
                        selection: $model.settings.backspaceTapAction,
                        options: [("A whole word", .deleteWord), ("One letter", .deleteCharacter)]
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "textformat",
                        title: "Auto-capitalize",
                        detail: "Start sentences with a capital letter.",
                        isOn: $model.settings.autoCapitalizationEnabled
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "circle.fill",
                        title: "Double-space period",
                        detail: "Tap space twice to end a sentence.",
                        isOn: $model.settings.doubleSpacePeriodEnabled
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "bubble.middle.top",
                        title: "Key previews",
                        detail: "Show a bubble above each key as you type.",
                        isOn: $model.settings.keyPreviewsEnabled
                    )
                }

                section("Feel") {
                    PebbleToggleRow(
                        systemImage: "hand.tap",
                        title: "Haptics",
                        detail: setup.hasSeenFullAccess ? "A soft tap under every key." : "Needs Full Access to work.",
                        isOn: $model.settings.hapticsEnabled
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "speaker.wave.2",
                        title: "Key clicks",
                        detail: "Follows Keyboard Feedback in iOS Settings.",
                        isOn: $model.settings.keyClicksEnabled
                    )
                }

                if !setup.hasSeenFullAccess {
                    SetupCard()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .pebbleScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            PebbleSectionHeader(title: title)
            PebbleCard(padding: 16) {
                VStack(spacing: 12, content: content)
            }
        }
    }
}
