import SwiftUI

/// The one place to try the keyboard: the in-app engine, then a real text field for LeanType
/// as the system keyboard.
struct PlaygroundView: View {
    @Environment(\.pebbleTheme) private var theme
    @State private var preview = PreviewKeyboardModel()
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private let reminders = [
        ("scribble.variable", "Swipe through a word"),
        ("cursorarrow.motionlines", "Slide on space"),
        ("delete.left", "Tap delete for a word"),
        ("arrow.uturn.backward", "Swipe right on delete to undo"),
        ("shift", "Slide from shift"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("This is LeanType, on this screen. Swipe a word, slide on space, or tap delete.")
                    .font(.pebble(.subheadline))
                    .foregroundStyle(theme.subtleInk)

                KeyboardPlayground(model: preview, prompt: "Swipe a word, slide on space")

                Text("In any app, switch to LeanType with the globe key.")
                    .font(.pebble(.subheadline))
                    .foregroundStyle(theme.subtleInk)
                    .padding(.top, 8)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(reminders, id: \.1) { icon, label in
                            Label(label, systemImage: icon)
                                .font(.pebble(.footnote, weight: .semibold))
                                .foregroundStyle(theme.chipInk)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(theme.chip, in: Capsule(style: .continuous))
                        }
                    }
                }
                .scrollIndicators(.hidden)

                PebbleCard(padding: 6) {
                    TextEditor(text: $text)
                        .focused($isFocused)
                        .font(.pebble(.title3))
                        .foregroundStyle(theme.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 200)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Type something nice…")
                                    .font(.pebble(.title3))
                                    .foregroundStyle(theme.subtleInk.opacity(0.6))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .pebbleScreen()
        .navigationTitle("Playground")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isFocused = true }
    }
}
