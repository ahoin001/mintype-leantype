import CoreGraphics

/// One letter a thumb reached: where, when, which key, and which way the finger was moving.
public struct StrokeObservation: Hashable, Sendable {
    public var time: Double
    public var point: CGPoint
    public var directionX: CGFloat
    public var directionY: CGFloat
    public var letter: String

    public init(time: Double, point: CGPoint, directionX: CGFloat, directionY: CGFloat, letter: String) {
        self.time = time
        self.point = point
        self.directionX = directionX
        self.directionY = directionY
        self.letter = letter
    }

    var directionLength: CGFloat {
        hypot(directionX, directionY)
    }
}

/// What a sequence of touches might spell. `result` is empty when no dictionary word fit;
/// `traced` is the letters the thumbs actually hit, in time order.
struct SequenceOutcome: Sendable {
    var result: DecodeResult
    var traced: String

    static let empty = SequenceOutcome(result: .empty, traced: "")
}

/// Decides whether a new tap or swipe still belongs to the open word.
enum WordJoiner {
    /// The reading to show if the batch extends the open word, or `nil` to start a new word.
    static func choose(
        openScore: Double,
        displayedWord: String?,
        existingWord: String?,
        batch: [StrokeObservation],
        extended: SequenceOutcome,
        alone: SequenceOutcome,
        fragmentContinues: Bool
    ) -> DecodeResult? {
        if fragmentContinues {
            // The keys actually hit are still the start of a longer word ("qui", "priva").
            // That beats letting the latest swipe become its own word.
            if let best = extended.result.readings.first,
               LexiconKey.make(best.word).count >= extended.traced.count {
                return extended.result
            }
            return DecodeResult(readings: [.init(word: extended.traced, score: provisionalScore)])
        }
        // A single letter joins when it improves the word or confirms it. A neighbor that
        // merely spells something else ("hello" plus x becoming "helix") does not.
        if batch.count <= 1 {
            if let best = extended.result.readings.first {
                let shown = displayedWord?.lowercased()
                let previous = existingWord?.lowercased()
                let candidate = best.word.lowercased()
                // The same word confirms a repeated last letter ("pill" plus L). Skipping the
                // new letter and keeping "hello" does not: the tap has to be part of the word.
                let confirms = (candidate == shown || candidate == previous) && candidate.last == batch.last?.letter.lowercased().last
                if (shown == nil && previous == nil) || confirms || best.score > openScore {
                    return extended.result
                }
            }
            return nil
        }
        if let best = extended.result.readings.first {
            let aloneScore = alone.result.readings.first?.score ?? 0
            if alone.result.isEmpty || best.score > openScore + aloneScore {
                return extended.result
            }
        }
        // Neither side is a word yet ("es" then "traged"). Keep the letters together so a
        // letter that lands in the middle can still finish the word.
        if extended.result.isEmpty, alone.result.isEmpty, !extended.traced.isEmpty {
            return DecodeResult(readings: [.init(word: extended.traced, score: provisionalScore)])
        }
        return nil
    }

    /// Readings built from traced letters, before a dictionary word exists.
    static let provisionalScore = -20.0
}

/// Letter-to-letter likelihoods learned from the dictionary, weighted toward common words.
struct LetterBigram: Sendable {
    private var logProbability: [[Double]]

    init(lexicon: MappedLexicon) {
        var mass = Array(repeating: Array(repeating: 1.0, count: 26), count: 26)
        let logMax = lexicon.logCountRange.upperBound
        let first = LexiconKey.firstLetter
        for index in 0..<lexicon.wordCount {
            let raw = lexicon.key(at: index)
            guard raw.count >= 2 else { continue }
            let weight = exp(lexicon.logCount(at: index) - logMax)
            var previous = raw[0]
            for offset in 1..<raw.count {
                let current = raw[offset]
                let from = Int(previous &- first)
                let to = Int(current &- first)
                if (0..<26).contains(from), (0..<26).contains(to) {
                    mass[from][to] += weight
                }
                previous = current
            }
        }
        logProbability = mass.map { row in
            let total = row.reduce(0, +)
            return row.map { log($0 / total) }
        }
    }

    func logProbability(from: UInt8, to: UInt8) -> Double {
        let first = LexiconKey.firstLetter
        let fromIndex = Int(from &- first)
        let toIndex = Int(to &- first)
        guard (0..<26).contains(fromIndex), (0..<26).contains(toIndex) else { return -4 }
        return logProbability[fromIndex][toIndex]
    }
}

/// Ranks dictionary words against a sequence of thumb touches.
///
/// One continuous swipe still uses `PathDecoder`. This is for a word built from several taps
/// and swipes. A short beam of letter prefixes advances one touch at a time. Each step tries
/// the keys near the finger, and a doubled letter when the dictionary has one, which is how
/// "pill" comes from P, I, L. Direction of travel is scored against the step from the previous
/// key, and a letter bigram favors likely spellings.
enum SequenceDecoder {
    static let beamWidth = 28
    static let neighborRadius: CGFloat = 1.5
    static let neighborLimit = 6
    static let spatialSigma: CGFloat = 0.48
    static let motionWeight = 0.45
    static let bigramWeight = 0.30
    static let skipPenalty = 3.2
    static let doublePenalty = 0.25
    static let maxSkips = 2
    static let frequencyWeight = 0.22

    private struct Hypothesis {
        var letters: [UInt8]
        var score: Double
        var skips: Int
        var lastX: CGFloat
        var lastY: CGFloat
        var placed: Bool
    }

    private struct Scored {
        enum Source {
            case dictionary(Int)
            case personal(Int)
        }

        var source: Source
        var score: Double
    }

    static func decode(
        _ observations: [StrokeObservation],
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram
    ) -> SequenceOutcome {
        let traced = observations.map(\.letter).joined()
        guard !observations.isEmpty else { return .empty }

        var beam = [Hypothesis(letters: [], score: 0, skips: 0, lastX: 0, lastY: 0, placed: false)]
        for observation in observations {
            var next: [Hypothesis] = []
            next.reserveCapacity(beam.count * (Self.neighborLimit + 2))
            let letters = candidates(for: observation, layout: layout)
            for hypothesis in beam {
                for letter in letters {
                    if let grown = extend(
                        hypothesis,
                        with: letter,
                        times: 1,
                        observation: observation,
                        layout: layout,
                        lexicon: lexicon,
                        personal: personal,
                        bigram: bigram
                    ) {
                        next.append(grown)
                    }
                    if let doubled = extend(
                        hypothesis,
                        with: letter,
                        times: 2,
                        observation: observation,
                        layout: layout,
                        lexicon: lexicon,
                        personal: personal,
                        bigram: bigram
                    ) {
                        next.append(doubled)
                    }
                }
                if hypothesis.placed, hypothesis.skips < Self.maxSkips {
                    var skipped = hypothesis
                    skipped.skips += 1
                    skipped.score -= Self.skipPenalty
                    next.append(skipped)
                }
            }
            beam = prune(next)
            if beam.isEmpty { break }
        }

        var scored: [Scored] = []
        for hypothesis in beam {
            consider(hypothesis, lexicon: lexicon, personal: personal, into: &scored)
        }
        scored.sort { $0.score > $1.score }

        var seen = Set<String>()
        var readings: [DecodeResult.Reading] = []
        for entry in scored {
            let word: String = switch entry.source {
            case let .dictionary(index): lexicon.display(at: index)
            case let .personal(offset): personal[offset].display
            }
            if seen.insert(word.lowercased()).inserted {
                readings.append(DecodeResult.Reading(word: word, score: entry.score))
            }
            if readings.count == 4 { break }
        }
        return SequenceOutcome(result: DecodeResult(readings: readings), traced: traced)
    }

    // MARK: - Beam

    private static func candidates(for observation: StrokeObservation, layout: LetterLayout) -> [UInt8] {
        var letters = layout.letters(near: observation.point, within: neighborRadius, limit: neighborLimit)
        if let traced = observation.letter.lowercased().utf8.first,
           (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(traced),
           !letters.contains(traced) {
            letters.append(traced)
        }
        return letters
    }

    private static func extend(
        _ hypothesis: Hypothesis,
        with letter: UInt8,
        times: Int,
        observation: StrokeObservation,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram
    ) -> Hypothesis? {
        var letters = hypothesis.letters
        letters.reserveCapacity(letters.count + times)
        for _ in 0..<times { letters.append(letter) }
        guard prefixExists(letters, lexicon: lexicon, personal: personal) else { return nil }

        let center = layout.center(of: letter)
        let distance = layout.normalizedDistance(observation.point, center)
        let sigma = spatialSigma
        var score = hypothesis.score - 0.5 * Double((distance * distance) / (sigma * sigma))
        if times == 2 { score -= doublePenalty }

        if hypothesis.placed {
            let previous = hypothesis.letters[hypothesis.letters.count - 1]
            score += bigramWeight * bigram.logProbability(from: previous, to: letter)
            if times == 2 {
                score += bigramWeight * bigram.logProbability(from: letter, to: letter)
            }
            if observation.directionLength > 0.5 {
                let stepX = center.x - hypothesis.lastX
                let stepY = center.y - hypothesis.lastY
                let length = hypot(stepX, stepY)
                if length > 1 {
                    let cosine = (stepX * observation.directionX + stepY * observation.directionY) / length
                    score += motionWeight * Double(cosine)
                }
            }
        }

        return Hypothesis(
            letters: letters,
            score: score,
            skips: hypothesis.skips,
            lastX: center.x,
            lastY: center.y,
            placed: true
        )
    }

    private static func prefixExists(
        _ letters: [UInt8],
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry]
    ) -> Bool {
        guard !letters.isEmpty else { return true }
        if !lexicon.indices(withPrefix: letters).isEmpty { return true }
        return personal.contains { entry in
            entry.key.count >= letters.count && entry.key.starts(with: letters)
        }
    }

    private static func prune(_ hypotheses: [Hypothesis]) -> [Hypothesis] {
        var best: [String: Hypothesis] = [:]
        best.reserveCapacity(hypotheses.count)
        for hypothesis in hypotheses {
            let key = String(decoding: hypothesis.letters, as: UTF8.self)
            if let existing = best[key], existing.score >= hypothesis.score { continue }
            best[key] = hypothesis
        }
        return best.values.sorted { $0.score > $1.score }.prefix(beamWidth).map { $0 }
    }

    private static func consider(
        _ hypothesis: Hypothesis,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        into scored: inout [Scored]
    ) {
        guard hypothesis.letters.count >= 2 else { return }
        let matches = lexicon.indices(ofKey: hypothesis.letters)
        if !matches.isEmpty {
            for index in matches {
                scored.append(Scored(
                    source: .dictionary(index),
                    score: hypothesis.score + frequencyWeight * lexicon.logCount(at: index)
                ))
            }
            return
        }
        for (offset, entry) in personal.enumerated() where entry.key == hypothesis.letters {
            scored.append(Scored(
                source: .personal(offset),
                score: hypothesis.score + frequencyWeight * entry.logCount
            ))
        }
    }
}
