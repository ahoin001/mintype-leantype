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
                PebbleSectionHeader(title: "Period")
                PebbleCard(padding: 8) {
                    NavigationLink {
                        ShortcutEditorView(letter: KeyShortcuts.period)
                    } label: {
                        letterRow(KeyShortcuts.period)
                    }
                    .buttonStyle(PebblePressStyle())
                }
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
            Text(letter == KeyShortcuts.period ? letter : letter.uppercased())
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
                    Text(emptyDetail)
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
                Text(footerDetail)
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
                    Button(letter == KeyShortcuts.period ? "Reset to ? ! $" : "Reset to the usual accents", role: .destructive, action: reset)
                        .listRowBackground(theme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .pebbleScreen()
        .navigationTitle(letter == KeyShortcuts.period ? "Period" : letter.uppercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
    }

    private var isPeriod: Bool { letter == KeyShortcuts.period }

    private var items: [String] {
        let row = KeyShortcuts.row(
            for: letter,
            builtIn: LayoutProvider.builtInAlternates(for: letter),
            overrides: model.settings.keyShortcuts
        )
        // The period stays pinned nearest the key, so the editor only lists the marks beside it.
        if isPeriod { return row.filter { $0 != KeyShortcuts.period } }
        return row
    }

    private var emptyDetail: String {
        if isPeriod { return "Holding period types a period, with nothing extra." }
        return "Holding \(letter.uppercased()) types the letter, with nothing extra."
    }

    private var footerDetail: String {
        if isPeriod { return "Period stays under your finger. These sit beside it. Hold, then slide." }
        return "The first one sits closest to the key. Hold \(letter.uppercased()), then slide."
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

    /// Saves the row, or drops the override when it matches the built-in row again.
    /// A period edit stores the full row, with the period pinned first.
    private func write(_ row: [String]) {
        let normalized = isPeriod ? KeyShortcuts.pinnedPeriod(row) : KeyShortcuts.normalized(row)
        if normalized == LayoutProvider.builtInAlternates(for: letter) {
            model.settings.keyShortcuts.removeValue(forKey: letter)
        } else {
            model.settings.keyShortcuts[letter] = normalized
        }
    }
}
