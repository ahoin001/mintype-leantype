import LeanTypeCore
import LeanTypeDesign
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsModel.self) private var model
    @Environment(SetupStatusModel.self) private var setup
    @Environment(KeyboardDataModel.self) private var data
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
                        detail: "Swipe left on delete or shift to erase letters, and back to the right to bring them back.",
                        selection: $model.settings.backspaceTapAction,
                        options: [("A whole word", .deleteWord), ("One letter", .deleteCharacter)]
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "arrow.up.to.line",
                        title: "Flick for numbers",
                        detail: "Flick up on the top row for the digit in the corner.",
                        isOn: $model.settings.flickForSecondaryEnabled
                    )
                    if model.settings.flickForSecondaryEnabled {
                        PebbleDivider()
                        PebbleToggleRow(
                            systemImage: "textformat.superscript",
                            title: "Show corner hints",
                            detail: "The small digits on the top row.",
                            isOn: $model.settings.secondaryHintsVisible
                        )
                    }
                    PebbleDivider()
                    NavigationLink {
                        ShortcutsView()
                    } label: {
                        PebbleLinkRow(
                            systemImage: "character.cursor.ibeam",
                            title: "Hold shortcuts",
                            detail: shortcutDetail
                        )
                    }
                    .buttonStyle(PebblePressStyle())
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
                        systemImage: "text.append",
                        title: "Finish a word you just typed",
                        detail: "A quick tap can still turn the into then. A full swipe is always the next word.",
                        isOn: $model.settings.extendFinishedWords
                    )
                    if model.settings.typingMode == .swipe {
                        PebbleDivider()
                        PebblePickerRow(
                            systemImage: "space",
                            title: "End a swipe",
                            detail: model.settings.swipeCommitMode == .lift
                                ? "The word lands when you lift. A short pause can still add a letter."
                                : "Several swipes stay one word until you press space.",
                            selection: $model.settings.swipeCommitMode,
                            options: [("On lift", .lift), ("On space", .explicitSpace)]
                        )
                        PebbleDivider()
                        leashRow
                    }
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
                            ? "Names you keep are remembered on this phone. Hold a suggestion to remember or forget one."
                            : "Needs Full Access to remember words.",
                        isOn: $model.settings.learnWordsEnabled
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "speedometer",
                        title: "Words per minute",
                        detail: "Shows a rolling pace on the space bar. Nothing is saved as a weekly stat.",
                        isOn: $model.settings.showsWordsPerMinute
                    )
                    PebbleDivider()
                    PebbleToggleRow(
                        systemImage: "scribble",
                        title: "Save gesture traces",
                        detail: "Keeps a decode trace on this phone after each word. Nothing is uploaded.",
                        isOn: $model.settings.recordsGestureTraces
                    )
                    if data.learnedWordCount > 0 || data.blockedWordCount > 0 {
                        PebbleDivider()
                        NavigationLink {
                            LearnedWordsView()
                        } label: {
                            PebbleLinkRow(
                                systemImage: "text.book.closed",
                                title: "Learned words",
                                detail: learnedWordsDetail
                            )
                        }
                        .buttonStyle(PebblePressStyle())
                    }
                }

                section("Flair") {
                    NavigationLink(value: HomeDestination.flair) {
                        PebbleLinkRow(systemImage: "sparkles", title: "Effects", detail: flairDetail)
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

    private var leashRow: some View {
        let recommended = SharedContainer.recommendedLeash()
        let suggested = String(format: "Suggested %.2f s from your typing.", recommended)
        return VStack(alignment: .leading, spacing: 8) {
            PebbleToggleRow(
                systemImage: "timer",
                title: "Join window",
                detail: model.settings.leashDuration == nil
                    ? "Follows your pace. \(suggested)"
                    : suggested,
                isOn: Binding(
                    get: { model.settings.leashDuration == nil },
                    set: { follow in
                        model.settings.leashDuration = follow ? nil : recommended
                    }
                )
            )
            if model.settings.leashDuration != nil {
                Slider(
                    value: Binding(
                        get: { model.settings.leashDuration ?? recommended },
                        set: { model.settings.leashDuration = min(0.55, max(0.16, $0)) }
                    ),
                    in: 0.16...0.55
                )
                .padding(.leading, 48)
            }
        }
    }

    private var learnedWordsDetail: String {
        if data.learnedWordCount == 0, data.blockedWordCount > 0 {
            let count = data.blockedWordCount
            return count == 1 ? "1 spelling hidden." : "\(count) spellings hidden."
        }
        return data.learnedWordCount == 1
            ? "1 word."
            : "\(data.learnedWordCount) words. Search, or jump by letter."
    }

    private var shortcutDetail: String {
        let count = model.settings.keyShortcuts.count
        if count == 0 {
            return "Hold a letter for accents, or period for ? ! $."
        }
        return count == 1 ? "1 key customized." : "\(count) keys customized."
    }

    private var flairDetail: String {
        switch model.settings.effects.intensity {
        case .off: "Off. The keys stay still."
        case .subtle: "Subtle. Smaller ripples, trails, and bursts."
        case .lively: "Lively. Ripples, trails, and bursts at the usual size."
        case .party: "Party. Larger bursts and brighter trails."
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
