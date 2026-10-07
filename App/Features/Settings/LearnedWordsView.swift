import LeanTypeCore
import LeanTypeDesign
import SwiftUI

/// The words this phone has learned, newest first. Swipe one to forget it.
struct LearnedWordsView: View {
    @Environment(KeyboardDataModel.self) private var data
    @Environment(\.pebbleTheme) private var theme
    @State private var isConfirmingClear = false

    var body: some View {
        List {
            Section {
                if data.learnedWords.isEmpty {
                    Text("Nothing learned yet. Hold a suggestion on the keyboard and choose Remember.")
                        .font(.pebble(.subheadline))
                        .foregroundStyle(theme.subtleInk)
                        .listRowBackground(theme.surface)
                } else {
                    ForEach(data.learnedWords, id: \.word) { word in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.word)
                                .font(.pebble(.body, weight: .semibold))
                                .foregroundStyle(theme.ink)
                            Text(detail(for: word))
                                .font(.pebble(.footnote))
                                .foregroundStyle(theme.subtleInk)
                        }
                        .listRowBackground(theme.surface)
                    }
                    .onDelete(perform: delete)
                }
            } footer: {
                Text("A word shows up in suggestions after you’ve used it twice, or as soon as you choose Remember.")
            }

            if !data.learnedWords.isEmpty {
                Section {
                    Button("Clear learned words", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .listRowBackground(theme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .pebbleScreen()
        .navigationTitle("Learned words")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { data.refresh() }
        .confirmationDialog("Forget every word LeanType has learned?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear learned words", role: .destructive) { data.clearLearnedWords() }
        } message: {
            Text("Autocorrect may start fixing words you use often until it learns them again.")
        }
    }

    private func detail(for word: LearnedWord) -> String {
        let times = word.uses == 1 ? "Used once" : "Used \(word.uses) times"
        if word.uses >= PersonalLexicon.usesBeforeSuggesting {
            return "\(times). Suggested."
        }
        return "\(times). Not suggested yet."
    }

    private func delete(at offsets: IndexSet) {
        let words = offsets.map { data.learnedWords[$0].word }
        for word in words {
            data.forgetLearnedWord(word)
        }
    }
}
