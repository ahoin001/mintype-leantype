import CoreGraphics

/// What the keyboard thinks of the word being typed.
public struct WordAnalysis: Hashable, Sendable {
    /// The typed word is a dictionary or personal word.
    public let isKnown: Bool
    /// What a space would turn the word into, if anything. Conservative by design.
    public let correction: String?
    /// Likely completions, best first, excluding the typed word and the correction.
    public let completions: [String]

    public static let empty = WordAnalysis(isKnown: true, correction: nil, completions: [])
}

/// Conservative autocorrect for tapped words.
///
/// It never touches the user's personal words or ordinary dictionary words, only strings the
/// dictionary doesn't know (or barely knows, like "helo"), and only toward a word a single edit
/// away (one wrong, missing, extra, or swapped letter). Substitutions are judged by where the fingers actually landed: a touch on the edge
/// between "o" and "p" makes either plausible, a touch dead-center on "o" does not.
/// Apostrophes and capitalization are restored for free ("dont" → "don't", "i" → "I").
struct TapCorrector {
    /// Spread of touches around the intended key, in key widths.
    static let touchSigma: CGFloat = 0.42
    /// Log-likelihood cost of a missing, extra, or swapped letter.
    static let editCost = 3.0
    static let doubledLetterCost = 1.5
    /// How much more likely the correction must be than leaving the word alone.
    static let margin = 2.5
    /// A string that isn't in the dictionary at all is rarer than its rarest word.
    static let unknownWordPenalty = 2.5
    /// Dictionary words rarer than this (natural log of their count) may still be a typo of a
    /// common neighbor. An absolute cutoff, so a longer word list doesn't make "helo" look established.
    static let rareWordLogCount = 8.0
    static let rareWordMargin = 4.0
    /// Typed words shorter than this are never corrected (except casing and apostrophes).
    static let minimumLength = 3
    /// Substitutions only consider keys this close to the touch, in key widths.
    static let neighborRadius: CGFloat = 1.6

    let lexicon: MappedLexicon
    let personal: [PersonalLexicon.Entry]
    let isPersonal: (String) -> Bool

    func analyze(_ typed: String, touches: [CGPoint]?, layout: LetterLayout?, completionLimit: Int) -> WordAnalysis {
        guard typed.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return .empty }
        let key = LexiconKey.make(typed)
        guard !key.isEmpty, key.count == typed.filter(\.isLetter).count else { return .empty }

        let personalWord = isPersonal(typed)
        let match = personalWord ? nil : exactMatch(typed, key: key)
        let correction: String? = switch (personalWord, match) {
        case (true, _):
            nil
        case let (false, index?):
            Self.isCorrectable(logCount: lexicon.logCount(at: index))
                ? correction(for: typed, key: key, touches: touches, layout: layout,
                             against: lexicon.logCount(at: index), margin: Self.rareWordMargin)
                : nil
        case (false, nil):
            sameLettersCorrection(typed, key: key)
                ?? correction(for: typed, key: key, touches: touches, layout: layout,
                              against: lexicon.logCountRange.lowerBound - Self.unknownWordPenalty, margin: Self.margin)
        }
        let known = personalWord || match != nil
        let completions = completions(for: key, excluding: [typed, correction].compactMap { $0 }, limit: completionLimit)
            .map { matchCase($0, to: typed) }
        return WordAnalysis(isKnown: known, correction: correction, completions: completions)
    }

    // MARK: - Correction

    /// Whether a dictionary word this rare may still be corrected (and so is worth learning
    /// when the user keeps it).
    static func isCorrectable(logCount: Double) -> Bool {
        logCount < rareWordLogCount
    }

    /// Same letters, different spelling: apostrophes, accents, or casing.
    private func sameLettersCorrection(_ typed: String, key: [UInt8]) -> String? {
        lexicon.indices(ofKey: key).first.map { matchCase(lexicon.display(at: $0), to: typed) }
    }

    /// The best single edit of `key`, if it beats leaving the word alone (`typedLogCount`) by
    /// `margin`.
    private func correction(
        for typed: String,
        key: [UInt8],
        touches: [CGPoint]?,
        layout: LetterLayout?,
        against typedLogCount: Double,
        margin: Double
    ) -> String? {
        guard key.count >= Self.minimumLength, let layout else { return nil }

        // Without trustworthy touches, assume each letter was hit dead center.
        let points = touches.flatMap { $0.count == key.count ? $0 : nil } ?? key.map(layout.center(of:))
        var best: (word: String, score: Double)?
        let baseline = typedLogCount + spatialScore(key, points: points, layout: layout)

        func consider(_ candidate: [UInt8], penalty: Double) {
            guard let index = lexicon.indices(ofKey: candidate).first else { return }
            let score = lexicon.logCount(at: index) - penalty
            if score > (best?.score ?? -.infinity) {
                best = (lexicon.display(at: index), score)
            }
        }

        var candidate = key
        // Substitutions, scored by where each finger landed.
        for position in key.indices {
            for letter in layout.letters(near: points[position], within: Self.neighborRadius, limit: 8) where letter != key[position] {
                candidate[position] = letter
                let spatial = spatialScore(candidate, points: points, layout: layout)
                consider(candidate, penalty: -spatial)
            }
            candidate[position] = key[position]
        }
        // Extra letter.
        for position in key.indices {
            var shorter = key
            shorter.remove(at: position)
            consider(shorter, penalty: Self.editCost)
        }
        // Missing letter. A skipped double letter ("helo", "tomorow") is the most common kind.
        for position in 0...key.count {
            for offset in 0..<UInt8(LexiconKey.letterCount) {
                let letter = LexiconKey.firstLetter + offset
                var longer = key
                longer.insert(letter, at: position)
                let doubles = (position > 0 && key[position - 1] == letter) || (position < key.count && key[position] == letter)
                consider(longer, penalty: doubles ? Self.doubledLetterCost : Self.editCost + 0.5)
            }
        }
        // Swapped neighbors.
        for position in key.indices.dropLast() where key[position] != key[position + 1] {
            var swapped = key
            swapped.swapAt(position, position + 1)
            consider(swapped, penalty: Self.editCost - 0.5)
        }

        guard let best, best.score > baseline + margin else { return nil }
        return matchCase(best.word, to: typed)
    }

    /// Log-likelihood of the touches given intended letters.
    private func spatialScore(_ letters: [UInt8], points: [CGPoint], layout: LetterLayout) -> Double {
        var score = 0.0
        for (letter, point) in zip(letters, points) {
            let distance = layout.normalizedDistance(point, layout.center(of: letter))
            score -= Double(distance * distance / (2 * Self.touchSigma * Self.touchSigma))
        }
        return score
    }

    /// The dictionary entry spelled exactly as typed, if any.
    private func exactMatch(_ typed: String, key: [UInt8]) -> Int? {
        lexicon.indices(ofKey: key).first { index in
            let display = lexicon.display(at: index)
            // Capitalized at the start of a sentence, or shouting: still the same word.
            return display == typed || (display.lowercased() == typed.lowercased() && typed.first?.isUppercase == true)
        }
    }

    // MARK: - Completions

    private func completions(for key: [UInt8], excluding: [String], limit: Int) -> [String] {
        let excluded = Set(excluding.map { $0.lowercased() })
        var scored: [(word: String, logCount: Double)] = []
        for index in lexicon.completions(prefix: key, limit: limit + excluded.count + 1) {
            scored.append((lexicon.display(at: index), lexicon.logCount(at: index)))
        }
        for entry in personal where entry.key.starts(with: key) {
            scored.append((entry.display, entry.logCount))
        }
        scored.sort { $0.logCount > $1.logCount }

        var seen = excluded
        var result: [String] = []
        for candidate in scored where seen.insert(candidate.word.lowercased()).inserted {
            result.append(candidate.word)
            if result.count == limit { break }
        }
        return result
    }

    /// Carries the typed word's capitalization onto a suggestion: "Teh" → "The", "TEH" → "THE".
    private func matchCase(_ word: String, to typed: String) -> String {
        let letters = typed.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) {
            return word.uppercased()
        }
        if typed.first?.isUppercase == true, let first = word.first, first.isLowercase {
            return first.uppercased() + word.dropFirst()
        }
        return word
    }
}
