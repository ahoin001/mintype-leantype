/// Pure text rules: word and sentence boundaries, auto-capitalization, and punctuation
/// spacing. All counts are in grapheme clusters (Swift `Character`s), so emoji and combined
/// accents are never split.
public enum TextBoundary {
    enum CharacterClass: Equatable {
        case word
        case punctuation
        case other
    }

    /// Punctuation that "hops" over a space the keyboard just added: "word ." becomes "word. ".
    public static let hoppingPunctuation: Set<Character> = [".", ",", "!", "?"]

    /// How many characters a "delete word" removes from the end of `before`.
    ///
    /// Mirrors option-delete: trailing spaces go together with the word before them, a newline
    /// is removed on its own, runs of punctuation go together, and each emoji is its own word.
    /// Returns 1 when there's no context, so the host still gets a single backspace (which
    /// also clears any selection).
    public static func wordDeletionLength(before: String?) -> Int {
        guard let before, !before.isEmpty else { return 1 }
        return max(wordRunLength(before.reversed()), 1)
    }

    /// Characters to move left to reach the start of the previous word (option-left).
    public static func wordMovementLength(before: String?) -> Int {
        guard let before, !before.isEmpty else { return 0 }
        return wordRunLength(before.reversed())
    }

    /// Characters to move right to reach the end of the next word (option-right).
    public static func wordMovementLength(after: String?) -> Int {
        guard let after, !after.isEmpty else { return 0 }
        return wordRunLength(after)
    }

    /// How many characters a "delete sentence" removes from the end of `before`: back to the
    /// end of the previous sentence (keeping its terminator and the space after it) or the
    /// start of the line.
    public static func sentenceDeletionLength(before: String?) -> Int {
        guard let before, !before.isEmpty else { return 1 }
        var iterator = before.reversed().makeIterator()
        var count = 0
        var next = iterator.next()

        while let character = next, character.isInlineWhitespace {
            count += 1
            next = iterator.next()
        }
        // The current sentence's own closing punctuation belongs to it.
        while let character = next, sentenceTerminators.contains(character) || closingCharacters.contains(character) {
            count += 1
            next = iterator.next()
        }
        while let character = next {
            if character.isNewline { break }
            if sentenceTerminators.contains(character) { break }
            count += 1
            next = iterator.next()
        }
        // Keep the whitespace that followed the previous sentence.
        if next != nil {
            let kept = before.suffix(count).prefix { $0.isInlineWhitespace }.count
            count -= kept
        }
        return max(count, 1)
    }

    /// How many characters to lift so the word touching the cursor comes off the page.
    /// `prefix` is taken from the end of the text before the cursor, `suffix` from the start
    /// of the text after it. In the space between words, that is the word just finished,
    /// including the space the cursor is sitting in.
    public static func pickupRange(before: String?, after: String?) -> (prefix: Int, suffix: Int) {
        let before = before ?? ""
        let after = after ?? ""
        if before.last.map({ characterClass(of: $0) == .word }) == true {
            let prefix = currentWord(before: before).count
            let suffix = after.prefix { characterClass(of: $0) == .word }.count
            return (prefix, suffix)
        }
        let gap = before.reversed().prefix { $0.isWhitespace }.count
        let earlier = String(before.dropLast(gap))
        let previous = currentWord(before: earlier)
        if !previous.isEmpty {
            return (previous.count + gap, 0)
        }
        let suffix = after.prefix { characterClass(of: $0) == .word }.count
        return (0, suffix)
    }

    /// The word being typed: the run of letters (and apostrophes) right before the cursor.
    public static func currentWord(before: String?) -> Substring {
        guard let before else { return "" }
        let start = before.reversed().prefix { characterClass(of: $0) == .word }.count
        return before.suffix(start)
    }

    /// Up to `limit` words ending at the caret, oldest first. The caret may sit in the space
    /// after the last word. Each word records how many UTF-16 units lie between the caret and
    /// the end of that word, so a replacement can walk back and return.
    public struct EarlierWord: Hashable, Sendable {
        public var text: String
        public var characters: Int
        public var utf16After: Int
    }

    public static func earlierWords(before: String?, limit: Int = 6) -> [EarlierWord] {
        guard let before, !before.isEmpty, limit > 0 else { return [] }
        var words: [EarlierWord] = []
        var index = before.endIndex
        var utf16After = 0
        while words.count < limit, index > before.startIndex {
            while index > before.startIndex {
                let previous = before.index(before: index)
                if characterClass(of: before[previous]) == .word { break }
                utf16After += before[previous].utf16.count
                index = previous
            }
            guard index > before.startIndex else { break }
            let end = index
            let gap = utf16After
            var characters = 0
            while index > before.startIndex {
                let previous = before.index(before: index)
                guard characterClass(of: before[previous]) == .word else { break }
                characters += 1
                utf16After += before[previous].utf16.count
                index = previous
            }
            guard characters > 0 else { break }
            words.append(EarlierWord(text: String(before[index..<end]), characters: characters, utf16After: gap))
        }
        return words.reversed()
    }

    /// Whether the text after the cursor carries on the current word (the cursor is mid-word).
    public static func continuesWord(after: String?) -> Bool {
        guard let first = after?.first else { return false }
        return characterClass(of: first) == .word
    }

    /// `.`, `!`, `?`, and `…` end a sentence. A comma does not.
    public static func endsSentence(_ character: Character) -> Bool {
        sentenceTerminators.contains(character)
    }

    /// Whether the next typed letter should be capitalized automatically.
    public static func shouldAutoCapitalize(before: String?, mode: AutocapitalizationMode) -> Bool {
        switch mode {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard let last = before?.last else { return true }
            return last.isWhitespace
        case .sentences:
            guard let before, !before.isEmpty else { return true }
            guard let last = before.last else { return true }
            if last.isNewline { return true }
            guard last.isInlineWhitespace else { return false }

            var remainder = before.reversed().drop { $0.isInlineWhitespace }
            if remainder.isEmpty { return true }
            if remainder.first?.isNewline == true { return true }
            remainder = remainder.drop { closingCharacters.contains($0) }
            guard let terminator = remainder.first else { return false }
            return sentenceTerminators.contains(terminator)
        }
    }

    /// Whether the text ends in a word followed by exactly one space: the shape a double-space
    /// period and hopping punctuation both rewrite.
    public static func endsWithWordAndSingleSpace(_ before: String?) -> Bool {
        guard let before else { return false }
        var reversed = before.reversed().makeIterator()
        guard reversed.next() == " ", let previous = reversed.next() else { return false }
        return characterClass(of: previous) == .word || closingCharacters.contains(previous)
    }

    /// Whether a double-tapped space should become ". ".
    public static func canApplyDoubleSpacePeriod(before: String?) -> Bool {
        endsWithWordAndSingleSpace(before)
    }

    /// Whether the text ends mid-word, so a swiped word needs a space in front of it.
    public static func needsSpaceBeforeWord(_ before: String?) -> Bool {
        guard let last = before?.last else { return false }
        return characterClass(of: last) == .word || sentenceTerminators.contains(last) || last == ","
    }

    static func characterClass(of character: Character) -> CharacterClass {
        if character.isLetter || character.isNumber || wordJoiners.contains(character) {
            return .word
        }
        if character.isPunctuation || character.isMathSymbol || character.isCurrencySymbol {
            return .punctuation
        }
        return .other
    }

    // MARK: - Private

    /// Length of the option-arrow run at the start of `characters`: leading inline whitespace,
    /// then one newline, or one run of word or punctuation characters, or one emoji.
    private static func wordRunLength(_ characters: some Sequence<Character>) -> Int {
        var iterator = characters.makeIterator()
        var count = 0
        var next = iterator.next()

        while let character = next, character.isInlineWhitespace {
            count += 1
            next = iterator.next()
        }
        guard let boundary = next else { return count }
        if boundary.isNewline {
            return count == 0 ? 1 : count
        }
        let targetClass = characterClass(of: boundary)
        if targetClass == .other {
            return count + 1
        }
        while let character = next, !character.isWhitespace, characterClass(of: character) == targetClass {
            count += 1
            next = iterator.next()
        }
        return count
    }

    private static let wordJoiners: Set<Character> = ["'", "’", "_"]
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    private static let closingCharacters: Set<Character> = [")", "]", "\"", "”", "’", "'"]
}

extension Character {
    var isInlineWhitespace: Bool {
        isWhitespace && !isNewline
    }
}
