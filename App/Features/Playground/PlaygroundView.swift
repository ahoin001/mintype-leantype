import SwiftUI

/// A real text field for trying LeanType as the system keyboard, with gesture reminders.
struct PlaygroundView: View {
    @Environment(\.pebbleTheme) private var theme
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
                Text("Switch to LeanType with the globe key, then try a few moves.")
                    .font(.pebble(.subheadline))
                    .foregroundStyle(theme.subtleInk)

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
