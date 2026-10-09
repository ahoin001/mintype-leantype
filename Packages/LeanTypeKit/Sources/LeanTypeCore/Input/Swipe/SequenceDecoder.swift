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
    /// Which moving stroke aimed at this letter. Taps use `-1`.
    public var strokeIndex: Int

    public init(
        time: Double,
        point: CGPoint,
        directionX: CGFloat,
        directionY: CGFloat,
        letter: String,
        isTap: Bool = false,
        strokeIndex: Int = -1
    ) {
        self.time = time
        self.point = point
        self.directionX = directionX
        self.directionY = directionY
        self.letter = letter
        self.isTap = isTap
        self.strokeIndex = strokeIndex
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
        alone: SequenceOutcome,
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
        guard let aligned = alignedReading(in: extended) else { return nil }
        // The new beat is already a word of its own, and folding it in is not clearly better.
        if let own = alone.result.readings.first,
           own.word.count > 1,
           aligns(own.word, traced: alone.traced),
           own.score + DecodeResult.confidenceMargin >= aligned.score {
            return nil
        }
        var readings = [aligned]
        if let own = alone.result.readings.first,
           own.word.count > 1,
           own.word.compare(aligned.word, options: .caseInsensitive) != .orderedSame,
           aligns(own.word, traced: alone.traced) {
            readings.append(own)
        }
        return DecodeResult(readings: readings)
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


/// Collapses a bounced pair ("ghghgh" becomes "gh"). The alignment search replaced the
/// path-versus-sequence table that used to live here.
enum BeatChooser {
    /// A miss this short is a deliberate literal, such as `qw`.
    static let literalLimit = 2

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
