import LeanTypeCore
import LeanTypeDesign
import SwiftUI

/// Every letter, with a preview of what a hold offers.
struct ShortcutsView: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.pebbleTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                PebbleSectionHeader(title: "Letters")
                PebbleCard(padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(Array(KeyShortcuts.letters.enumerated()), id: \.element) { index, letter in
                            if index > 0 {
                                PebbleDivider()
                            }
                            NavigationLink {
                                ShortcutEditorView(letter: letter)
                            } label: {
                                letterRow(letter)
                            }
                            .buttonStyle(PebblePressStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .pebbleScreen()
        .navigationTitle("Hold shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func letterRow(_ letter: String) -> some View {
        HStack(spacing: 14) {
            Text(letter.uppercased())
                .font(.pebble(.headline, weight: .bold))
                .foregroundStyle(theme.accent)
                .frame(width: 28)
            Text(preview(for: letter))
                .font(.pebble(.subheadline))
                .foregroundStyle(theme.subtleInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.subtleInk.opacity(0.7))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func preview(for letter: String) -> String {
        let row = KeyShortcuts.row(
            for: letter,
            builtIn: LayoutProvider.builtInAlternates(for: letter),
            overrides: model.settings.keyShortcuts
        )
        if row.isEmpty { return "Nothing extra" }
        return row.joined(separator: "  ")
    }
}

/// Add, remove, and reorder the hold row for one letter. The first item sits closest to the key.
struct ShortcutEditorView: View {
    let letter: String

    @Environment(SettingsModel.self) private var model
    @Environment(\.pebbleTheme) private var theme
    @State private var draft = ""

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    Text("Holding \(letter.uppercased()) types the letter, with nothing extra.")
                        .font(.pebble(.subheadline))
                        .foregroundStyle(theme.subtleInk)
                        .listRowBackground(theme.surface)
                } else {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.pebble(.body, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .listRowBackground(theme.surface)
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                }
            } footer: {
                Text("The first one sits closest to the key. Hold \(letter.uppercased()), then slide.")
            }

            Section {
                HStack(spacing: 12) {
                    TextField("Email, word, or phrase", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.pebble(.body))
                        .onSubmit(add)
                    Button("Add", action: add)
                        .font(.pebble(.body, weight: .semibold))
                        .disabled(!canAdd)
                }
                .listRowBackground(theme.surface)
            }

            if isCustom {
                Section {
                    Button("Reset to the usual accents", role: .destructive, action: reset)
                        .listRowBackground(theme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .pebbleScreen()
        .navigationTitle(letter.uppercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
    }

    private var items: [String] {
        KeyShortcuts.row(
            for: letter,
            builtIn: LayoutProvider.builtInAlternates(for: letter),
            overrides: model.settings.keyShortcuts
        )
    }

    private var isCustom: Bool {
        model.settings.keyShortcuts[letter] != nil
    }

    private var canAdd: Bool {
        KeyShortcuts.normalized(items + [draft]).count == items.count + 1
    }

    private func add() {
        guard canAdd else { return }
        write(items + [draft])
        draft = ""
    }

    private func delete(at offsets: IndexSet) {
        var next = items
        next.remove(atOffsets: offsets)
        write(next)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var next = items
        next.move(fromOffsets: source, toOffset: destination)
        write(next)
    }

    private func reset() {
        model.settings.keyShortcuts.removeValue(forKey: letter)
    }

    /// Saves the row, or drops the override when it matches the built-in accents again.
    private func write(_ row: [String]) {
        let normalized = KeyShortcuts.normalized(row)
        if normalized == LayoutProvider.builtInAlternates(for: letter) {
            model.settings.keyShortcuts.removeValue(forKey: letter)
        } else {
            model.settings.keyShortcuts[letter] = normalized
        }
    }
}
