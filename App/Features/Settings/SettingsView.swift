import LeanTypeCore
import LeanTypeDesign
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsModel.self) private var model
    @Environment(SetupStatusModel.self) private var setup
    @Environment(KeyboardDataModel.self) private var data
    @State private var isConfirmingClear = false

    private static let wordListURL = URL(string: "https://github.com/hermitdave/FrequencyWords")!

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(spacing: 22) {
                section("Typing") {
                    PebblePickerRow(
                        systemImage: "scribble.variable",
                        title: "Letters",
                        detail: model.settings.typingMode == .swipe
                            ? "Tap letters, or slide through them to type a whole word."
                            : "Every touch is a tap.",
                        selection: $model.settings.typingMode,
                        options: [("Tap and swipe", .swipe), ("Tap only", .tap)]
                    )
                    PebbleDivider()
                    PebblePickerRow(
                        systemImage: "delete.left",
                        title: "A tap on delete removes",
                        detail: "Swipe left on delete to erase letters, right to bring them back.",
                        selection: $model.settings.backspaceTapAction,
                        options: [("A whole word", .deleteWord), ("One letter", .deleteCharacter)]
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "arrow.down.to.line",
                        title: "Flick for numbers",
                        detail: "Flick down on a letter for the character in its corner.",
                        isOn: $model.settings.flickForSecondaryEnabled
                    )
                    if model.settings.flickForSecondaryEnabled {
                        PebbleDivider()
                        PebbleToggleRow(
                            systemImage: "textformat.superscript",
                            title: "Show corner hints",
                            detail: "The small characters on each key.",
                            isOn: $model.settings.secondaryHintsVisible
                        )
                    }
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
                        systemImage: "ellipsis.bubble",
                        title: "Smart punctuation",
                        detail: "Periods and commas tuck up against the word, with a space after.",
                        isOn: $model.settings.smartPunctuationEnabled
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "bubble.middle.top",
                        title: "Key previews",
                        detail: "Show a bubble above each key as you type.",
                        isOn: $model.settings.keyPreviewsEnabled
                    )
                }

                section("Words") {
                    PebbleToggleRow(
                        systemImage: "text.word.spacing",
                        title: "Suggestions",
                        detail: "Up to three words above the keys. Tap one to use it.",
                        isOn: $model.settings.suggestionsEnabled
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "wand.and.sparkles",
                        title: "Autocorrect",
                        detail: "Fixes obvious slips when you press space. Tap delete once to undo.",
                        isOn: $model.settings.autocorrectEnabled
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "brain",
                        title: "Learn my words",
                        detail: setup.hasSeenFullAccess
                            ? "Names and words you use are remembered on this phone, never shared."
                            : "Needs Full Access to remember words.",
                        isOn: $model.settings.learnWordsEnabled
                    )
                    if data.learnedWordCount > 0 {
                        PebbleDivider()
                        clearLearnedWordsRow
                    }
                }

                section("Flair") {
                    PebblePickerRow(
                        systemImage: "sparkles",
                        title: "Effects",
                        detail: "Ripples, trails, and a gust of wind for deleted words.",
                        selection: $model.settings.effects.intensity,
                        options: [("Off", .off), ("Subtle", .subtle), ("Lively", .lively), ("Party", .party)]
                    )
                    PebbleDivider()
                    NavigationLink(value: HomeDestination.flair) {
                        PebbleLinkRow(systemImage: "wand.and.rays", title: "Trails and streaks", detail: "Try every effect on a live keyboard.")
                    }
                    .buttonStyle(PebblePressStyle())
                }

                section("Size") {
                    PebblePickerRow(
                        systemImage: "arrow.up.and.down",
                        title: "Key height",
                        selection: $model.settings.height,
                        options: [("Compact", .compact), ("Regular", .regular), ("Tall", .tall)]
                    )
                    PebbleDivider()
                    PebblePickerRow(
                        systemImage: "hand.raised",
                        title: "One-handed",
                        detail: "Also on the keyboard: the hand button above the keys.",
                        selection: $model.settings.oneHandedMode,
                        options: [("Off", .off), ("Left", .left), ("Right", .right)]
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

                section("About") {
                    Link(destination: Self.wordListURL) {
                        PebbleLinkRow(
                            systemImage: "book.closed",
                            title: "Word list",
                            detail: "Adapted from FrequencyWords by Hermit Dave (OpenSubtitles 2018), CC BY-SA 4.0."
                        )
                    }
                    .buttonStyle(PebblePressStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .animation(Motion.gentleSpring, value: model.settings.flickForSecondaryEnabled)
        }
        .scrollIndicators(.hidden)
        .pebbleScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { data.refresh() }
    }

    private var clearLearnedWordsRow: some View {
        Button(role: .destructive) {
            isConfirmingClear = true
        } label: {
            HStack(spacing: 14) {
                PebbleIcon(systemName: "trash", size: 34)
                PebbleRowText(
                    title: "Clear learned words",
                    detail: data.learnedWordCount == 1 ? "1 word remembered." : "\(data.learnedWordCount) words remembered."
                )
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PebblePressStyle())
        .confirmationDialog("Forget every word LeanType has learned?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear learned words", role: .destructive) { data.clearLearnedWords() }
        } message: {
            Text("Autocorrect may start fixing words you use often until it learns them again.")
        }
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
