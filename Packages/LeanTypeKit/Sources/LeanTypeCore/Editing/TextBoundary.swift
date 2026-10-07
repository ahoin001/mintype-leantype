/// Pure text rules: word boundaries for deletion and when to auto-capitalize. All counts are in
/// grapheme clusters (Swift `Character`s), so emoji and combined accents are never split.
public enum TextBoundary {
    enum CharacterClass: Equatable {
        case word
        case punctuation
        case other
    }

    /// How many characters a "delete word" removes from the end of `before`.
    ///
    /// Mirrors option-delete: trailing spaces go together with the word before them, a newline
    /// is removed on its own, runs of punctuation go together, and each emoji is its own word.
    /// Returns 1 when there's no context, so the host still gets a single backspace (which
    /// also clears any selection).
    public static func wordDeletionLength(before: String?) -> Int {
        guard let before, !before.isEmpty else { return 1 }

        var iterator = before.reversed().makeIterator()
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

    /// Whether a double-tapped space should become ". ": the text must end in a word followed
    /// by exactly one space.
    public static func canApplyDoubleSpacePeriod(before: String?) -> Bool {
        guard let before else { return false }
        var reversed = before.reversed().makeIterator()
        guard reversed.next() == " ", let previous = reversed.next() else { return false }
        return characterClass(of: previous) == .word || closingCharacters.contains(previous)
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

    private static let wordJoiners: Set<Character> = ["'", "’", "_"]
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    private static let closingCharacters: Set<Character> = [")", "]", "\"", "”", "’", "'"]
}

extension Character {
    var isInlineWhitespace: Bool {
        isWhitespace && !isNewline
    }
}
