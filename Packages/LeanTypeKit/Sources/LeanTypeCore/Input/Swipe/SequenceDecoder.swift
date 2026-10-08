import CoreGraphics

/// One letter a thumb reached: where, when, which key, and which way the finger was moving.
public struct StrokeObservation: Hashable, Sendable {
    public var time: Double
    public var point: CGPoint
    public var directionX: CGFloat
    public var directionY: CGFloat
    public var letter: String
    /// A thumb that tapped this letter rather than swiping through it.
    public var isTap: Bool

    public init(
        time: Double,
        point: CGPoint,
        directionX: CGFloat,
        directionY: CGFloat,
        letter: String,
        isTap: Bool = false
    ) {
        self.time = time
        self.point = point
        self.directionX = directionX
        self.directionY = directionY
        self.letter = letter
        self.isTap = isTap
    }

    var directionLength: CGFloat {
        hypot(directionX, directionY)
    }
}

extension Array where Element == StrokeObservation {
    /// Time order, so a letter tapped during the other thumb's stroke lands at that moment.
    func inReadingOrder() -> [StrokeObservation] {
        sorted { $0.time < $1.time }
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
    ///
    /// A word joins when it uses every letter the thumbs aimed at, in order. A doubled letter
    /// is allowed, which is how "pill" comes from P, I, L. Rewriting an earlier letter into a
    /// neighbor ("hello" plus x becoming "helix") does not join, and neither does skipping the
    /// new letter to keep the old word.
    static func choose(
        extended: SequenceOutcome,
        alone _: SequenceOutcome,
        fragmentContinues: Bool
    ) -> DecodeResult? {
        if fragmentContinues {
            // The keys actually hit are still the start of a longer word ("qui", "priva").
            // That beats letting the latest swipe become its own word. The raw trace is never
            // a reading: if no dictionary word covers those keys, the caller starts a new word.
            if let best = extended.result.readings.first,
               LexiconKey.make(best.word).count >= extended.traced.count {
                return extended.result
            }
            // The keys are a real prefix ("priva" toward "private") but no dictionary word
            // covers them yet. Keep those letters so the rest of the word can still arrive.
            guard !extended.traced.isEmpty else { return nil }
            return DecodeResult(readings: [.init(word: extended.traced, score: provisionalScore)])
        }
        if let aligned = alignedReading(in: extended) {
            return DecodeResult(readings: [aligned])
        }
        return nil
    }

    /// The best dictionary word whose letters are exactly the aimed keys, allowing one
    /// doubled letter per key.
    static func alignedReading(in outcome: SequenceOutcome) -> DecodeResult.Reading? {
        outcome.result.readings
            .filter { aligns($0.word, traced: outcome.traced) }
            .max { $0.score < $1.score }
    }

    /// `word` is `traced` in order, where any traced letter may also cover one extra copy of
    /// itself ("pill" from "pil", "hello" from "helo"). An apostrophe in the spelling is not
    /// a letter the thumb had to visit, so "that's" lines up with "thats".
    static func aligns(_ word: String, traced: String) -> Bool {
        let target = Array(word.lowercased().filter(\.isLetter))
        let source = Array(traced.lowercased())
        guard !source.isEmpty, !target.isEmpty else { return false }
        var reachable = Array(repeating: false, count: target.count + 1)
        reachable[0] = true
        for letter in source {
            var next = Array(repeating: false, count: target.count + 1)
            for index in 0..<target.count where reachable[index] && target[index] == letter {
                next[index + 1] = true
                if index + 1 < target.count, target[index + 1] == letter {
                    next[index + 2] = true
                }
            }
            reachable = next
        }
        return reachable[target.count]
    }

    /// Readings built from traced letters, before a dictionary word exists.
    static let provisionalScore = -20.0
}

/// Picks the word a beat of strokes and taps should commit.
///
/// One moving finger keeps the shape when that word is what the corners spell, or when the
/// corners spell nothing. When the corners spell a different dictionary word, that word leads.
/// A longer miss still commits a dictionary word the decoders found, and keeps the aimed
/// letters on the bar so a name can be tapped back. Two letters or fewer with no word stay
/// the letters themselves. A tap is part of the word only when the dictionary reading uses
/// that letter and still matches the keys the moving thumb aimed at.
enum BeatChooser {
    /// A miss this short is a deliberate literal, such as `qw`.
    static let literalLimit = 2

    enum Choice {
        /// The shape match, unchanged.
        case path(DecodeResult)
        /// A dictionary word that accounts for every aimed letter.
        case aligned(DecodeResult)
        /// A dictionary word for a long miss that is not an exact spelling. An open fragment
        /// can still absorb the beat; otherwise this word is what gets typed.
        case nearest(DecodeResult)
        /// The moving thumb's word, then taps that belong to the following word.
        case split(path: DecodeResult, taps: [StrokeObservation])
        /// No dictionary word. The caller types the aimed letters.
        case traced
    }

    static func choose(
        path: DecodeResult,
        sequence: SequenceOutcome,
        strokes: Int,
        observations: [StrokeObservation]
    ) -> Choice {
        let taps = observations.filter(\.isTap)
        let traced = sequence.traced
        if taps.isEmpty, strokes <= 1 {
            let shapeFits = path.readings.first.map { WordJoiner.aligns($0.word, traced: traced) } ?? false
            if !shapeFits, let aligned = WordJoiner.alignedReading(in: sequence) {
                return .aligned(preferring(aligned, over: path))
            }
            if !path.isEmpty {
                return .path(offering(path, literal: traced))
            }
            return miss(sequence: sequence, path: path, traced: traced)
        }
        if let aligned = WordJoiner.alignedReading(in: sequence) {
            return .aligned(preferring(aligned, over: path))
        }
        if strokes <= 1, !path.isEmpty {
            let sorted = observations.inReadingOrder()
            let tapsAreSuffix = sorted.last?.isTap == true && sorted.reversed().prefix(while: \.isTap).count == taps.count
            let strokeTraced = observations.filter { !$0.isTap }.map(\.letter).joined()
            if tapsAreSuffix, let word = path.readings.first?.word, WordJoiner.aligns(word, traced: strokeTraced) {
                return .split(path: path, taps: taps.sorted { $0.time < $1.time })
            }
        }
        return miss(sequence: sequence, path: path, traced: traced)
    }

    /// What the suggestion bar shows while the fingers are still down. An empty result leaves
    /// the previous preview up; a short literal still commits from the aimed letters.
    static func reading(
        path: DecodeResult,
        sequence: SequenceOutcome,
        strokes: Int,
        observations: [StrokeObservation]
    ) -> DecodeResult {
        switch choose(path: path, sequence: sequence, strokes: strokes, observations: observations) {
        case let .path(result), let .aligned(result), let .nearest(result), let .split(result, _):
            result
        case .traced:
            .empty
        }
    }

    /// Drops a letter that only bounces back to the one before it ("ghghgh" becomes "gh").
    static func collapse(_ letters: String) -> String {
        var output: [Character] = []
        for character in letters {
            if output.count >= 2 {
                let previous = output[output.count - 1]
                let before = output[output.count - 2]
                if character == before, previous != character {
                    output.removeLast()
                    continue
                }
            }
            output.append(character)
        }
        return String(output)
    }

    /// A long aim with no exact spelling still commits the nearest word the decoders found.
    /// The cleaned letters ride along at the end when they are not that word.
    private static func miss(sequence: SequenceOutcome, path: DecodeResult, traced: String) -> Choice {
        let letters = collapse(traced)
        let source = combined(sequence: sequence, path: path)
        guard letters.count > literalLimit, !source.isEmpty else { return .traced }
        return .nearest(offering(source, literal: letters))
    }

    private static func combined(sequence: SequenceOutcome, path: DecodeResult) -> DecodeResult {
        if sequence.result.isEmpty { return path }
        var readings = sequence.result.readings
        for reading in path.readings where !readings.contains(where: { $0.word.lowercased() == reading.word.lowercased() }) {
            readings.append(reading)
        }
        return DecodeResult(readings: readings)
    }

    /// Puts the aimed letters last, so a name that is not the chosen word can be tapped back.
    private static func offering(_ result: DecodeResult, literal: String) -> DecodeResult {
        let letters = collapse(literal)
        guard letters.count > literalLimit, let top = result.readings.first else { return result }
        if WordJoiner.aligns(top.word, traced: letters) { return result }
        if result.readings.contains(where: { $0.word.compare(letters, options: .caseInsensitive) == .orderedSame }) {
            return result
        }
        var readings = result.readings
        readings.append(DecodeResult.Reading(word: letters, score: top.score - DecodeResult.confidenceMargin - 1))
        return DecodeResult(readings: readings)
    }

    /// The aligned word leads, and the shape match's other readings stay available. The gap is
    /// wide enough that the bar can present the tapped word as the one to accept.
    private static func preferring(_ aligned: DecodeResult.Reading, over path: DecodeResult) -> DecodeResult {
        var readings = [aligned]
        readings.append(contentsOf: path.readings.filter { $0.word.lowercased() != aligned.word.lowercased() })
        if readings.count >= 2, readings[0].score - readings[1].score < DecodeResult.confidenceMargin {
            readings[0] = DecodeResult.Reading(
                word: readings[0].word,
                score: readings[1].score + DecodeResult.confidenceMargin + 0.01
            )
        }
        return DecodeResult(readings: readings)
    }
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
