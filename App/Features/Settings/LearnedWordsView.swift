import LeanTypeCore
import LeanTypeDesign
import SwiftUI

/// How the learned list is ordered. Hidden spellings have no use count, so "Most used" only applies to learned words.
private enum LearnedWordsSort: String, CaseIterable, Identifiable {
    case recent
    case alphabetical
    case frequent

    var id: Self { self }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .alphabetical: "A–Z"
        case .frequent: "Most used"
        }
    }

    static func options(for scope: LearnedWordsScope) -> [LearnedWordsSort] {
        switch scope {
        case .learned: allCases
        case .hidden: [.recent, .alphabetical]
        }
    }
}

private enum LearnedWordsScope: Hashable {
    case learned
    case hidden
}

private struct LearnedWordBucket: Identifiable {
    let id: String
    let words: [LearnedWord]
}

private struct BlockedWordBucket: Identifiable {
    let id: String
    let words: [BlockedSpelling]
}

/// The words this phone has learned. Search, sort, and jump by letter once the list gets long.
struct LearnedWordsView: View {
    @Environment(KeyboardDataModel.self) private var data
    @Environment(\.pebbleTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var scope: LearnedWordsScope = .learned
    @State private var sort: LearnedWordsSort = .recent
    @State private var isConfirmingClear = false

    var body: some View {
        ScrollViewReader { proxy in
            wordList
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if showsLetterRail {
                        LearnedWordsLetterRail(letters: letterRailLetters) { letter in
                            if reduceMotion {
                                proxy.scrollTo(letter, anchor: .top)
                            } else {
                                withAnimation(Motion.gentleSpring) {
                                    proxy.scrollTo(letter, anchor: .top)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            LearnedWordsControls(
                sort: $sort,
                options: LearnedWordsSort.options(for: scope),
                summary: summary,
                hint: trimmedQuery.isEmpty ? scopeHint : nil
            )
        }
        .scrollContentBackground(.hidden)
        .pebbleScreen()
        .navigationTitle("Learned words")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a word")
        .searchScopes($scope) {
            Text("Learned").tag(LearnedWordsScope.learned)
            Text("Hidden").tag(LearnedWordsScope.hidden)
        }
        .toolbar {
            if scope == .learned, !data.learnedWords.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear", role: .destructive) {
                        isConfirmingClear = true
                    }
                }
            }
        }
        .onAppear { data.refresh() }
        .onChange(of: scope) { _, newScope in
            if newScope == .hidden, sort == .frequent {
                sort = .recent
            }
        }
        .confirmationDialog(
            "Forget every word LeanType has learned?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear learned words", role: .destructive) { data.clearLearnedWords() }
        } message: {
            Text("Autocorrect may start fixing words you use often until it learns them again.")
        }
    }

    @ViewBuilder
    private var wordList: some View {
        switch scope {
        case .learned:
            learnedList
        case .hidden:
            hiddenList
        }
    }

    private var learnedList: some View {
        List {
            if filteredLearned.isEmpty {
                LearnedWordsEmptyRow(message: learnedEmptyMessage)
            } else if showsLetterSections {
                ForEach(learnedBuckets) { bucket in
                    Section {
                        Color.clear
                            .frame(height: 0)
                            .id(bucket.id)
                            .accessibilityHidden(true)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        ForEach(bucket.words, id: \.word) { word in
                            LearnedWordRow(word: word.word, detail: detail(for: word))
                        }
                        .onDelete { offsets in
                            forget(bucket.words, at: offsets)
                        }
                    } header: {
                        LearnedWordsSectionHeader(title: bucket.id)
                    }
                }
            } else {
                Section {
                    ForEach(filteredLearned, id: \.word) { word in
                        LearnedWordRow(word: word.word, detail: detail(for: word))
                    }
                    .onDelete { offsets in
                        forget(filteredLearned, at: offsets)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var hiddenList: some View {
        List {
            if filteredBlocked.isEmpty {
                LearnedWordsEmptyRow(message: hiddenEmptyMessage)
            } else if showsLetterSections {
                ForEach(blockedBuckets) { bucket in
                    Section {
                        Color.clear
                            .frame(height: 0)
                            .id(bucket.id)
                            .accessibilityHidden(true)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        ForEach(bucket.words, id: \.word) { entry in
                            LearnedWordRow(word: entry.word, detail: "Hidden")
                        }
                        .onDelete { offsets in
                            restore(bucket.words, at: offsets)
                        }
                    } header: {
                        LearnedWordsSectionHeader(title: bucket.id)
                    }
                }
            } else {
                Section {
                    ForEach(filteredBlocked, id: \.word) { entry in
                        LearnedWordRow(word: entry.word, detail: "Hidden")
                    }
                    .onDelete { offsets in
                        restore(filteredBlocked, at: offsets)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var showsLetterSections: Bool {
        activeSort == .alphabetical && trimmedQuery.isEmpty
    }

    private var showsLetterRail: Bool {
        letterRailLetters.count >= 6
    }

    private var letterRailLetters: [String] {
        guard showsLetterSections else { return [] }
        switch scope {
        case .learned: return learnedBuckets.map(\.id)
        case .hidden: return blockedBuckets.map(\.id)
        }
    }

    private var activeSort: LearnedWordsSort {
        if scope == .hidden, sort == .frequent { return .recent }
        return sort
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredLearned: [LearnedWord] {
        let query = trimmedQuery.lowercased()
        let matched = data.learnedWords.filter { word in
            query.isEmpty || word.word.lowercased().contains(query)
        }
        switch activeSort {
        case .recent:
            return matched
        case .alphabetical:
            return matched.sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
        case .frequent:
            return matched.sorted { lhs, rhs in
                if lhs.uses != rhs.uses { return lhs.uses > rhs.uses }
                return lhs.word.localizedStandardCompare(rhs.word) == .orderedAscending
            }
        }
    }

    private var filteredBlocked: [BlockedSpelling] {
        let query = trimmedQuery.lowercased()
        let matched = data.blockedWords.filter { entry in
            query.isEmpty || entry.word.lowercased().contains(query)
        }
        switch activeSort {
        case .recent, .frequent:
            return matched
        case .alphabetical:
            return matched.sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
        }
    }

    private var learnedBuckets: [LearnedWordBucket] {
        buckets(from: filteredLearned, word: \.word).map { letter, words in
            LearnedWordBucket(id: letter, words: words)
        }
    }

    private var blockedBuckets: [BlockedWordBucket] {
        buckets(from: filteredBlocked, word: \.word).map { letter, words in
            BlockedWordBucket(id: letter, words: words)
        }
    }

    private func buckets<Item>(from items: [Item], word: KeyPath<Item, String>) -> [(String, [Item])] {
        let groups = Dictionary(grouping: items) { item in
            Self.letter(for: item[keyPath: word])
        }
        return groups.keys.sorted(by: Self.lettersInOrder).map { letter in
            (letter, groups[letter] ?? [])
        }
    }

    private var scopeHint: String {
        scope == .learned
            ? "Swipe a word to forget it."
            : "Swipe a spelling to suggest it again."
    }

    private var summary: String {
        switch scope {
        case .learned:
            if !trimmedQuery.isEmpty {
                let count = filteredLearned.count
                return count == 1 ? "1 match" : "\(count) matches"
            }
            let total = data.learnedWords.count
            if total == 0 { return "Nothing learned yet" }
            let suggested = data.learnedWords.filter { $0.uses >= PersonalLexicon.usesBeforeSuggesting }.count
            return "\(total) learned · \(suggested) suggested"
        case .hidden:
            if !trimmedQuery.isEmpty {
                let count = filteredBlocked.count
                return count == 1 ? "1 match" : "\(count) matches"
            }
            let total = data.blockedWords.count
            if total == 0 { return "Nothing hidden" }
            return total == 1 ? "1 hidden spelling" : "\(total) hidden spellings"
        }
    }

    private var learnedEmptyMessage: String {
        if !trimmedQuery.isEmpty { return "No words match “\(trimmedQuery)”." }
        return "Nothing learned yet. Hold a suggestion on the keyboard and choose Remember."
    }

    private var hiddenEmptyMessage: String {
        if !trimmedQuery.isEmpty { return "No spellings match “\(trimmedQuery)”." }
        return "Nothing hidden. Hold a suggestion on the keyboard and choose Never suggest."
    }

    private func detail(for word: LearnedWord) -> String {
        let times = word.uses == 1 ? "Used once" : "Used \(word.uses) times"
        if word.uses >= PersonalLexicon.usesBeforeSuggesting {
            return "\(times) · Suggested"
        }
        return "\(times) · Not suggested yet"
    }

    private func forget(_ words: [LearnedWord], at offsets: IndexSet) {
        for word in offsets.map({ words[$0].word }) {
            data.forgetLearnedWord(word)
        }
    }

    private func restore(_ words: [BlockedSpelling], at offsets: IndexSet) {
        for word in offsets.map({ words[$0].word }) {
            data.restoreBlockedWord(word)
        }
    }

    private static func letter(for word: String) -> String {
        guard let character = word.first, character.isLetter else { return "#" }
        return String(character).localizedUppercase
    }

    private static func lettersInOrder(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "#" { return false }
        if rhs == "#" { return true }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

/// Recent, alphabetical, or most-used, plus a one-line count that stays put while the list scrolls.
private struct LearnedWordsControls: View {
    @Environment(\.pebbleTheme) private var theme
    @Binding var sort: LearnedWordsSort
    let options: [LearnedWordsSort]
    let summary: String
    let hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(options) { option in
                    Button {
                        sort = option
                    } label: {
                        Text(option.title)
                            .font(.pebble(.subheadline, weight: sort == option ? .semibold : .regular))
                            .foregroundStyle(sort == option ? theme.ink : theme.chipInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background {
                                if sort == option {
                                    Capsule()
                                        .fill(theme.surface)
                                        .shadow(color: theme.shadow.opacity(0.28), radius: 6, y: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(sort == option ? .isSelected : [])
                }
            }
            .padding(4)
            .background(theme.chip.opacity(0.55), in: Capsule())
            .animation(Motion.gentleSpring, value: sort)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                if let hint {
                    Text(hint)
                }
            }
            .font(.pebble(.footnote))
            .foregroundStyle(theme.subtleInk)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(theme.backgroundTop.color.opacity(0.94))
    }
}

private struct LearnedWordsSectionHeader: View {
    @Environment(\.pebbleTheme) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(.pebble(.footnote, weight: .bold))
            .foregroundStyle(theme.accent)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background(theme.backgroundTop.color.opacity(0.94))
    }
}

private struct LearnedWordRow: View {
    @Environment(\.pebbleTheme) private var theme
    let word: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(word)
                .font(.pebble(.body, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text(detail)
                .font(.pebble(.footnote))
                .foregroundStyle(theme.subtleInk)
        }
        .listRowBackground(theme.surface.opacity(0.88))
        .listRowSeparatorTint(theme.surfaceRim.opacity(0.45))
    }
}

private struct LearnedWordsEmptyRow: View {
    @Environment(\.pebbleTheme) private var theme
    let message: String

    var body: some View {
        Text(message)
            .font(.pebble(.subheadline))
            .foregroundStyle(theme.subtleInk)
            .listRowBackground(Color.clear)
    }
}

/// A contacts-style rail. Drag or flick along it to jump to a letter.
private struct LearnedWordsLetterRail: View {
    @Environment(\.pebbleTheme) private var theme
    let letters: [String]
    let onSelect: (String) -> Void

    @State private var active: String?
    @State private var scrubTick = 0

    private let rowHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            letterStack
            Spacer(minLength: 0)
        }
        .frame(width: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Letter index")
        .accessibilityValue(active ?? letters.first ?? "")
        .accessibilityAdjustableAction { direction in
            guard let current = letters.firstIndex(of: active ?? letters[0]) else { return }
            let next = direction == .increment
                ? min(current + 1, letters.count - 1)
                : max(current - 1, 0)
            choose(letters[next])
        }
    }

    private var letterStack: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: letter == active ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(letter == active ? theme.accent : theme.subtleInk)
                    .frame(width: 28, height: rowHeight)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = min(max(Int(value.location.y / rowHeight), 0), letters.count - 1)
                    choose(letters[index])
                }
                .onEnded { _ in
                    active = nil
                }
        )
        .sensoryFeedback(.selection, trigger: scrubTick)
    }

    private func choose(_ letter: String) {
        guard letter != active else { return }
        active = letter
        scrubTick += 1
        onSelect(letter)
    }
}
