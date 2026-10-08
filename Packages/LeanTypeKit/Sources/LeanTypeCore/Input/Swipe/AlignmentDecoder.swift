import CoreGraphics

/// Every hand-set number the alignment search uses, in one place.
struct AlignmentCosts: Sendable {
    var sigmaX: CGFloat = 0.55
    var sigmaY: CGFloat = 0.40
    var anchorSkip: Double = 3.2
    var maxAnchorSkips: Int = 2
    var crossingSkipBase: Double = 0.05
    var crossingSkipCentral: Double = 1.15
    var passThroughPenalty: Double = 0.35
    var doublePenalty: Double = 0.25
    var frequencyWeight: Double = 0.22
    var bigramWeight: Double = 0.30
    var motionWeight: Double = 0.45
    var swapWindow: Double = 0.07
    var swapPenalty: Double = 1.1
    var lengthWeight: Double = 1.4
    var seamBias: Double = 0.35
    var beamWidth: Int = 28
    var neighborRadius: CGFloat = 1.5
    var neighborLimit: Int = 6
    var resultLimit: Int = 4
    /// A preview below this is withdrawn once the path has grown past it.
    static let previewFloor = -15.0

    static let standard = AlignmentCosts()

    /// Adjacent events from different fingers inside this window may be read in either order.
    /// The penalty shrinks as the gap shrinks.
    func transpositionPenalty(gap: Double) -> Double {
        guard swapWindow > 0 else { return swapPenalty }
        return swapPenalty * min(1, max(0, gap / swapWindow))
    }
}

/// One search over taps, anchors, and crossings. Replaces the path-versus-sequence table:
/// a word letter is a tap, an aimed point, or a key the stroke passed through.
enum AlignmentSearch {
    static func decode(
        _ gesture: SwipeGesture,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        costs: AlignmentCosts,
        expected: [String] = [],
        habits: [String: Double] = [:],
        pathScore: inout PathScore
    ) -> DecodeResult {
        let raw = gesture.evidence.events.isEmpty
            ? SwipeEvidence.fromObservations(gesture.observations).events
            : gesture.evidence.events
        let events = raw.sorted { $0.time < $1.time }
        guard !events.isEmpty else { return .empty }
        let steps = StrokeChannel.steps(from: events, keyWidth: layout.keyWidth, keyHeight: layout.keyHeight)
        let crossingScale = crossingScale(of: events)

        var readings: [DecodeResult.Reading] = []
        for order in orders(of: steps, costs: costs) {
            let penalty = orderPenalty(order, costs: costs)
            let ranked = beam(
                order,
                layout: layout,
                lexicon: lexicon,
                personal: personal,
                bigram: bigram,
                costs: costs,
                habits: habits,
                crossingScale: crossingScale
            )
                .map { DecodeResult.Reading(word: $0.word, score: $0.score - penalty) }
            readings = merge(readings, ranked)
        }
        readings = rescore(readings, gesture: gesture, layout: layout, costs: costs, pathScore: &pathScore)
        readings = addingExpected(
            readings,
            words: expected,
            gesture: gesture,
            layout: layout,
            lexicon: lexicon,
            personal: personal,
            costs: costs,
            habits: habits,
            pathScore: &pathScore
        )
        readings = addingShape(
            readings,
            gesture: gesture,
            layout: layout,
            lexicon: lexicon,
            personal: personal,
            costs: costs,
            habits: habits,
            pathScore: &pathScore
        )
        let aimed = gesture.evidence.aimedLetters.isEmpty ? gesture.tracedLetters : gesture.evidence.aimedLetters
        return ReadingPolicy.apply(DecodeResult(readings: readings), aimed: aimed, limit: costs.resultLimit)
    }

    // MARK: - Order

    /// Time order, plus a few adjacent swaps of different fingers that landed close together.
    private static func orders(of steps: [StrokeChannel.Step], costs: AlignmentCosts) -> [[StrokeChannel.Step]] {
        guard steps.count >= 2, steps.count <= 18 else { return [steps] }
        var indexes: [[Int]] = [Array(steps.indices)]
        var seen: Set<String> = [key(indexes[0])]
        var cursor = 0
        while cursor < indexes.count, indexes.count < 6 {
            let order = indexes[cursor]
            cursor += 1
            for index in 0..<(order.count - 1) {
                let left = steps[order[index]]
                let right = steps[order[index + 1]]
                guard canSwap(left, right, costs: costs) else { continue }
                var swapped = order
                swapped.swapAt(index, index + 1)
                let name = key(swapped)
                guard seen.insert(name).inserted else { continue }
                indexes.append(swapped)
                if indexes.count == 6 { break }
            }
        }
        return indexes.map { order in order.map { steps[$0] } }
    }

    /// What this order paid to read two different fingers out of time. Time order pays nothing.
    private static func orderPenalty(_ steps: [StrokeChannel.Step], costs: AlignmentCosts) -> Double {
        var penalty = 0.0
        for index in 1..<steps.count {
            guard steps[index].time < steps[index - 1].time else { continue }
            penalty += costs.transpositionPenalty(gap: steps[index - 1].time - steps[index].time)
        }
        return penalty
    }

    private static func canSwap(_ left: StrokeChannel.Step, _ right: StrokeChannel.Step, costs: AlignmentCosts) -> Bool {
        guard left.strokeIndex != right.strokeIndex, abs(left.time - right.time) <= costs.swapWindow else { return false }
        // A letter already down stays before keys that land after it. Two thumbs can still
        // interleave, and a tap can still move earlier into a key that landed first.
        if left.event?.role == .tap, left.time < right.time { return false }
        if right.event?.role == .tap, right.time < left.time { return false }
        return true
    }

    private static func key(_ order: [Int]) -> String {
        order.map(String.init).joined(separator: ",")
    }

    // MARK: - Beam

    private struct Hypothesis {
        var letters: [UInt8]
        var score: Double
        var anchorSkips: Int
        var lastX: CGFloat
        var lastY: CGFloat
        var placed: Bool
        var lastStroke: Int?
    }

    private struct Scored {
        enum Source {
            case dictionary(Int)
            case personal(Int)
        }

        var source: Source
        var score: Double
    }

    private static func beam(
        _ steps: [StrokeChannel.Step],
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        costs: AlignmentCosts,
        habits: [String: Double],
        crossingScale: Double
    ) -> [DecodeResult.Reading] {
        let habitBuckets = habitBuckets(from: habits)
        var beam = [Hypothesis(letters: [], score: 0, anchorSkips: 0, lastX: 0, lastY: 0, placed: false, lastStroke: nil)]
        for step in steps {
            var next: [Hypothesis] = []
            next.reserveCapacity(beam.count * (costs.neighborLimit + 2))
            if let event = step.event {
                let letters = candidates(for: event, layout: layout, costs: costs)
                for hypothesis in beam {
                    for letter in letters {
                        if let grown = extend(hypothesis, with: letter, times: 1, event: event, layout: layout, lexicon: lexicon, personal: personal, bigram: bigram, costs: costs) {
                            next.append(grown)
                        }
                        if let doubled = extend(hypothesis, with: letter, times: 2, event: event, layout: layout, lexicon: lexicon, personal: personal, bigram: bigram, costs: costs) {
                            next.append(doubled)
                        }
                    }
                    if let skipped = skip(hypothesis, event: event, layout: layout, costs: costs, crossingScale: crossingScale) {
                        next.append(skipped)
                    }
                }
            } else {
                for hypothesis in beam {
                    next.append(skipChannel(hypothesis, costs: costs, crossingScale: crossingScale))
                    var seen = Set<UInt8>()
                    for event in step.channel {
                        guard let letter = event.letter.lowercased().utf8.first,
                              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(letter),
                              seen.insert(letter).inserted else { continue }
                        if let grown = extend(hypothesis, with: letter, times: 1, event: event, layout: layout, lexicon: lexicon, personal: personal, bigram: bigram, costs: costs) {
                            next.append(grown)
                        }
                    }
                }
            }
            beam = prune(next, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
            if beam.isEmpty { return [] }
        }

        var scored: [Scored] = []
        for hypothesis in beam {
            consider(hypothesis, lexicon: lexicon, personal: personal, costs: costs, habits: habits, into: &scored)
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
            if readings.count == costs.resultLimit * 2 { break }
        }
        return readings
    }

    private static func candidates(for event: SwipeEvent, layout: LetterLayout, costs: AlignmentCosts) -> [UInt8] {
        var letters = layout.letters(near: event.point, within: costs.neighborRadius, limit: costs.neighborLimit)
        if let traced = event.letter.lowercased().utf8.first,
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
        event: SwipeEvent,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        costs: AlignmentCosts
    ) -> Hypothesis? {
        var letters = hypothesis.letters
        letters.reserveCapacity(letters.count + times)
        for _ in 0..<times { letters.append(letter) }
        guard prefixExists(letters, lexicon: lexicon, personal: personal) else { return nil }

        let center = layout.center(of: letter)
        var score = hypothesis.score - spatialCost(event.point, letter: letter, layout: layout, costs: costs)
        if times == 2 { score -= costs.doublePenalty }
        if event.role == .crossing {
            let keys = Double(event.distanceToCenter / max(layout.keyWidth, 1))
            score -= costs.passThroughPenalty * min(keys, 1.5)
        }
        score -= seamPenalty(letter: letter, touchX: event.point.x, layout: layout, bias: costs.seamBias)

        if hypothesis.placed {
            let previous = hypothesis.letters[hypothesis.letters.count - 1]
            score += costs.bigramWeight * bigram.logProbability(from: previous, to: letter)
            if times == 2 {
                score += costs.bigramWeight * bigram.logProbability(from: letter, to: letter)
            }
            let sameStroke = hypothesis.lastStroke == event.strokeIndex && event.strokeIndex >= 0
            if sameStroke, event.directionLength > 0.5 {
                let stepX = center.x - hypothesis.lastX
                let stepY = center.y - hypothesis.lastY
                let length = hypot(stepX, stepY)
                if length > 1 {
                    let cosine = (stepX * event.directionX + stepY * event.directionY) / length
                    score += costs.motionWeight * Double(cosine)
                }
            }
        }

        return Hypothesis(
            letters: letters,
            score: score,
            anchorSkips: hypothesis.anchorSkips,
            lastX: center.x,
            lastY: center.y,
            placed: true,
            lastStroke: event.strokeIndex
        )
    }

    private static func skip(
        _ hypothesis: Hypothesis,
        event: SwipeEvent,
        layout: LetterLayout,
        costs: AlignmentCosts,
        crossingScale: Double
    ) -> Hypothesis? {
        switch event.role {
        case .anchor, .tap:
            guard hypothesis.placed, hypothesis.anchorSkips < costs.maxAnchorSkips else { return nil }
            var skipped = hypothesis
            skipped.anchorSkips += 1
            skipped.score -= costs.anchorSkip
            return skipped
        case .crossing:
            let closeness = max(0, 1 - Double(event.distanceToCenter / max(layout.keyWidth, 1)))
            var skipped = hypothesis
            skipped.score -= (costs.crossingSkipBase + costs.crossingSkipCentral * closeness) * crossingScale
            return skipped
        }
    }

    /// A straight run between corners costs almost nothing to ignore. The letters stay
    /// available as a single insertion, so a word can still take one of them.
    private static func skipChannel(_ hypothesis: Hypothesis, costs: AlignmentCosts, crossingScale: Double) -> Hypothesis {
        var skipped = hypothesis
        skipped.score -= costs.crossingSkipBase * crossingScale
        return skipped
    }

    /// A fast flick makes a grazed key cheaper to skip. A slow trace makes it dearer.
    /// Missing speeds stay at 1, so fixtures that never recorded a speed are unchanged.
    private static func crossingScale(of events: [SwipeEvent]) -> Double {
        let speeds = events.map(\.speed).filter { $0 > 0 }.sorted()
        guard !speeds.isEmpty else { return 1 }
        let median = speeds[speeds.count / 2]
        let slow = 180.0
        let fast = 700.0
        if median <= slow { return 1.25 }
        if median >= fast { return 0.75 }
        let t = (median - slow) / (fast - slow)
        return 1.25 + (0.75 - 1.25) * t
    }

    private static func spatialCost(_ point: CGPoint, letter: UInt8, layout: LetterLayout, costs: AlignmentCosts) -> Double {
        let center = layout.center(of: letter)
        let dx = (point.x - center.x) / layout.keyWidth
        let dy = (point.y - center.y) / layout.keyHeight
        let sigmaX = Double(costs.sigmaX)
        let sigmaY = Double(costs.sigmaY)
        return 0.5 * (Double(dx * dx) / (sigmaX * sigmaX) + Double(dy * dy) / (sigmaY * sigmaY))
    }

    /// A touch on the left of the keyboard is weak evidence for Y, H, or N, and the reverse.
    static func seamPenalty(letter: UInt8, touchX: CGFloat, layout: LetterLayout, bias: Double) -> Double {
        guard bias > 0 else { return 0 }
        let mid = (layout.center(of: UInt8(ascii: "g")).x + layout.center(of: UInt8(ascii: "h")).x) / 2
        let onRight = touchX >= mid
        let pairs: [(UInt8, UInt8)] = [
            (UInt8(ascii: "t"), UInt8(ascii: "y")),
            (UInt8(ascii: "g"), UInt8(ascii: "h")),
            (UInt8(ascii: "b"), UInt8(ascii: "n")),
        ]
        for (left, right) in pairs {
            if letter == left && onRight { return bias }
            if letter == right && !onRight { return bias }
        }
        return 0
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

    /// Keeps the best spatial score for each prefix, then the widest beam.
    /// The two-letter frequency prior only decides who survives. It is not stored on the
    /// hypothesis, so the final word frequency is added once, in `consider`.
    private static func prune(
        _ hypotheses: [Hypothesis],
        lexicon: MappedLexicon,
        costs: AlignmentCosts,
        habitBuckets: [[HabitKey]]
    ) -> [Hypothesis] {
        var best: [String: Hypothesis] = [:]
        best.reserveCapacity(hypotheses.count)
        for hypothesis in hypotheses {
            let key = String(decoding: hypothesis.letters, as: UTF8.self)
            if let existing = best[key], existing.score >= hypothesis.score { continue }
            best[key] = hypothesis
        }
        return best.values.sorted { lhs, rhs in
            survival(lhs, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
                > survival(rhs, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
        }.prefix(costs.beamWidth).map { $0 }
    }

    private static func survival(
        _ hypothesis: Hypothesis,
        lexicon: MappedLexicon,
        costs: AlignmentCosts,
        habitBuckets: [[HabitKey]]
    ) -> Double {
        var score = hypothesis.score
        if let prior = lexicon.prefixLogCount(hypothesis.letters) {
            let lower = lexicon.logCountRange.lowerBound
            let span = lexicon.logCountRange.upperBound - lower
            if span > 0 {
                // The table stores a raw log count. Using it whole outweighs the path, so a common
                // stem such as "ve" can crowd out the letters the finger actually drew. The byte's
                // place in the frequency range keeps the nudge inside one frequency weight.
                let fraction = min(1, max(0, (prior - lower) / span))
                score += costs.frequencyWeight * fraction
            }
        }
        score += habitPrefixBonus(hypothesis.letters, buckets: habitBuckets)
        return score
    }

    /// A committed word helps its own prefix stay in the beam. The fraction is how much of
    /// that word is written so far. The full bonus is added once, later, when the word is scored.
    private struct HabitKey {
        var key: [UInt8]
        var bonus: Double
    }

    private static func habitBuckets(from habits: [String: Double]) -> [[HabitKey]] {
        var buckets = Array(repeating: [HabitKey](), count: LexiconKey.letterCount * LexiconKey.letterCount)
        guard !habits.isEmpty else { return buckets }
        for (word, bonus) in habits where bonus > 0 {
            let key = LexiconKey.make(word)
            guard key.count >= 2 else { continue }
            let first = LexiconKey.index(of: key[0])
            let second = LexiconKey.index(of: key[1])
            guard (0..<LexiconKey.letterCount).contains(first), (0..<LexiconKey.letterCount).contains(second) else { continue }
            buckets[first * LexiconKey.letterCount + second].append(HabitKey(key: key, bonus: bonus))
        }
        return buckets
    }

    private static func habitPrefixBonus(_ letters: [UInt8], buckets: [[HabitKey]]) -> Double {
        guard letters.count >= 2 else { return 0 }
        let first = LexiconKey.index(of: letters[0])
        let second = LexiconKey.index(of: letters[1])
        guard (0..<LexiconKey.letterCount).contains(first), (0..<LexiconKey.letterCount).contains(second) else { return 0 }
        var best = 0.0
        for habit in buckets[first * LexiconKey.letterCount + second] where habit.key.count >= letters.count && habit.key.starts(with: letters) {
            let scaled = habit.bonus * Double(letters.count) / Double(habit.key.count)
            if scaled > best { best = scaled }
        }
        return best
    }

    private static func consider(
        _ hypothesis: Hypothesis,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        costs: AlignmentCosts,
        habits: [String: Double],
        into scored: inout [Scored]
    ) {
        guard hypothesis.letters.count >= 2 else { return }
        let matches = lexicon.indices(ofKey: hypothesis.letters)
        if !matches.isEmpty {
            for index in matches {
                let display = lexicon.display(at: index)
                scored.append(Scored(
                    source: .dictionary(index),
                    score: hypothesis.score + costs.frequencyWeight * lexicon.logCount(at: index) + habitBonus(display, habits: habits)
                ))
            }
            return
        }
        for (offset, entry) in personal.enumerated() where entry.key == hypothesis.letters {
            scored.append(Scored(
                source: .personal(offset),
                score: hypothesis.score + costs.frequencyWeight * entry.logCount + habitBonus(entry.display, habits: habits)
            ))
        }
    }

    /// A small bump for a word this user actually commits. Zero until the second use, and
    /// never larger than one close call, so a bad shape still loses.
    private static func habitBonus(_ word: String, habits: [String: Double]) -> Double {
        guard !habits.isEmpty else { return 0 }
        return habits[word.lowercased()] ?? 0
    }

    // MARK: - Shape

    /// Adds the polyline match and a length cost. A frequent near-miss no longer hides a word
    /// the beam already found, and a wild stroke pays for the length it did not explain.
    private static func rescore(
        _ readings: [DecodeResult.Reading],
        gesture: SwipeGesture,
        layout: LetterLayout,
        costs: AlignmentCosts,
        pathScore: inout PathScore
    ) -> [DecodeResult.Reading] {
        let paths = gesture.strokePaths.isEmpty ? (gesture.path.count >= 2 ? [gesture.path] : []) : gesture.strokePaths
        guard !paths.isEmpty else {
            return Array(readings.sorted { $0.score > $1.score }.prefix(costs.resultLimit))
        }
        let totalLength = paths.reduce(CGFloat(0)) { $0 + StrokeAnalyzer.length(of: $1) } / layout.keyWidth
        var adjusted: [DecodeResult.Reading] = []
        adjusted.reserveCapacity(readings.count)
        let tapped = gesture.evidence.events.contains { $0.role == .tap }
        for reading in readings {
            let key = LexiconKey.make(reading.word)
            var score = reading.score
            if paths.count == 1 {
                // A tap is not on the polyline. Score the stroke against the letters that
                // stroke aimed at, and let the beam explain the tap.
                let shaped = tapped ? anchorLetters(in: gesture, stroke: paths.indices.first ?? 0) : key
                score += pathFit(shaped, path: paths[0], layout: layout, pathScore: &pathScore)
            } else {
                score += wordOnStrokes(key, gesture: gesture, layout: layout, pathScore: &pathScore)
            }
            score -= PathScore.lengthCost(gestureLength: totalLength, key: key, layout: layout, weight: costs.lengthWeight)
            adjusted.append(DecodeResult.Reading(word: reading.word, score: score))
        }
        adjusted.sort { $0.score > $1.score }
        return adjusted
    }

    /// A word that skips a moving thumb pays for it. Each thumb's polyline is scored against
    /// the slice of the word that thumb explains, not against the word's first and last letter.
    private static func wordOnStrokes(
        _ word: [UInt8],
        gesture: SwipeGesture,
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double {
        let thumbs = thumbs(in: gesture)
        guard thumbs.count > 1 else {
            guard let path = gesture.strokePaths.first else { return 0 }
            return pathFit(word, path: path, layout: layout, pathScore: &pathScore)
        }
        guard let slices = slices(of: word, thumbs: thumbs) else { return -8 }
        var total = 0.0
        var counted = 0
        for (thumb, slice) in zip(thumbs, slices) {
            let fit = pathFit(slice, path: thumb.path, layout: layout, pathScore: &pathScore)
            if fit != 0 || slice.count >= 2 {
                total += fit
                counted += 1
            }
        }
        guard counted > 0 else { return 0 }
        return total / Double(counted)
    }

    private struct ThumbSlice {
        var letters: [UInt8]
        var path: [CGPoint]
    }

    private static func thumbs(in gesture: SwipeGesture) -> [ThumbSlice] {
        var order: [Int] = []
        var letters: [Int: [UInt8]] = [:]
        for event in gesture.evidence.events where event.role == .anchor && event.strokeIndex >= 0 {
            guard let letter = event.letter.lowercased().utf8.first else { continue }
            if letters[event.strokeIndex] == nil {
                order.append(event.strokeIndex)
                letters[event.strokeIndex] = []
            }
            if letters[event.strokeIndex]?.last != letter {
                letters[event.strokeIndex]?.append(letter)
            }
        }
        return order.compactMap { index in
            guard gesture.strokePaths.indices.contains(index), gesture.strokePaths[index].count >= 2,
                  let aimed = letters[index], !aimed.isEmpty else { return nil }
            return ThumbSlice(letters: aimed, path: gesture.strokePaths[index])
        }
    }

    /// One slice per thumb, in stroke order. The last thumb keeps the rest of the word.
    private static func slices(of word: [UInt8], thumbs: [ThumbSlice]) -> [[UInt8]]? {
        var cursor = 0
        var result: [[UInt8]] = []
        for (index, thumb) in thumbs.enumerated() {
            if index == thumbs.count - 1 {
                guard cursor < word.count else { return nil }
                let rest = Array(word[cursor...])
                guard matchEnd(thumb.letters, in: rest, from: 0) != nil else { return nil }
                result.append(rest)
            } else {
                guard let end = matchEnd(thumb.letters, in: word, from: cursor) else { return nil }
                result.append(Array(word[cursor...end]))
                cursor = end + 1
            }
        }
        return result
    }

    private static func matchEnd(_ letters: [UInt8], in word: [UInt8], from start: Int) -> Int? {
        guard start <= word.count else { return nil }
        var cursor = start
        var last = start - 1
        for letter in letters {
            guard cursor < word.count, let found = word[cursor...].firstIndex(of: letter) else { return nil }
            last = found
            cursor = found + 1
        }
        guard last >= start else { return nil }
        return last
    }

    private static func anchorLetters(in gesture: SwipeGesture, stroke index: Int) -> [UInt8] {
        gesture.evidence.events.compactMap { event in
            guard event.role == .anchor, event.strokeIndex == index else { return nil }
            return event.letter.lowercased().utf8.first
        }
    }

    /// Log-likelihood of `letters` on `path`. A path too far to score pays more than a
    /// borderline fit, so missing the cutoff cannot outrank a word the path actually follows.
    private static func pathFit(
        _ letters: [UInt8],
        path: [CGPoint],
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double {
        guard letters.count >= 2, pathScore.prepare(path, layout: layout) else { return 0 }
        if let fit = pathScore.measure(letters, mustExceed: -.infinity, gateLength: false, layout: layout).score {
            return fit
        }
        return -8
    }

    /// How far `word` sits from `path`, in key widths. Nil when the word is too short to measure.
    private static func location(
        of word: String,
        path: [CGPoint],
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> CGFloat? {
        let key = LexiconKey.make(word)
        guard key.count >= 2, pathScore.prepare(path, layout: layout) else { return nil }
        return pathScore.measure(key, mustExceed: -.infinity, gateLength: false, layout: layout).location
    }

    // MARK: - Expected words

    /// Scores the few words the previous word suggests. A word already on the list keeps its
    /// beam score. A new word is inserted only when this stroke actually fits it, at that fit,
    /// so a later close-call can promote it and a miss stays out.
    private static func addingExpected(
        _ readings: [DecodeResult.Reading],
        words: [String],
        gesture: SwipeGesture,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        costs: AlignmentCosts,
        habits: [String: Double],
        pathScore: inout PathScore
    ) -> [DecodeResult.Reading] {
        guard !words.isEmpty else { return readings }
        var best: [String: DecodeResult.Reading] = [:]
        for reading in readings {
            best[reading.word.lowercased()] = reading
        }
        for word in words.prefix(3) {
            let key = word.lowercased()
            if best[key] != nil { continue }
            guard let known = knownWord(word, lexicon: lexicon, personal: personal) else { continue }
            let letters = LexiconKey.make(known.display)
            let fit = gestureFit(letters, gesture: gesture, layout: layout, pathScore: &pathScore)
            guard fit < 0, fit > -8 else { continue }
            let score = fit + costs.frequencyWeight * known.logCount + habitBonus(known.display, habits: habits)
            best[key] = DecodeResult.Reading(word: known.display, score: score)
        }
        return best.values.sorted { $0.score > $1.score }
    }

    /// The same path term `rescore` adds: one stroke against the whole word, two strokes
    /// against the slices those thumbs explain.
    private static func gestureFit(
        _ letters: [UInt8],
        gesture: SwipeGesture,
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double {
        let paths = gesture.strokePaths.isEmpty ? (gesture.path.count >= 2 ? [gesture.path] : []) : gesture.strokePaths
        guard !paths.isEmpty else { return 0 }
        if paths.count == 1 {
            return pathFit(letters, path: paths[0], layout: layout, pathScore: &pathScore)
        }
        return wordOnStrokes(letters, gesture: gesture, layout: layout, pathScore: &pathScore)
    }

    // MARK: - Shape nominations

    /// How many curve matches from each thumb may be joined into a two-stroke word.
    private static let shapePieceLimit = 3

    /// Words the curve found that the beam did not. A word already on the list keeps the
    /// beam's score. A new word is inserted with its path fit and the frequency prior.
    /// A one-stroke curve stays just outside the tie margin, unless the finger is clearly
    /// closer to that word than to the beam's leader and no tap is holding a letter down.
    private static func addingShape(
        _ readings: [DecodeResult.Reading],
        gesture: SwipeGesture,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        costs: AlignmentCosts,
        habits: [String: Double],
        pathScore: inout PathScore
    ) -> [DecodeResult.Reading] {
        let paths = gesture.strokePaths.isEmpty ? (gesture.path.count >= 2 ? [gesture.path] : []) : gesture.strokePaths
        let extra: [DecodeResult.Reading]
        if paths.count == 2 {
            let joined = joinedNominations(paths, gesture: gesture, layout: layout, lexicon: lexicon, personal: personal, costs: costs, pathScore: &pathScore)
            let merged = mergedNominations(
                readings,
                gesture: gesture,
                layout: layout,
                lexicon: lexicon,
                personal: personal,
                costs: costs,
                pathScore: &pathScore
            )
            extra = joined + merged
        } else {
            extra = singleStrokeNominations(paths, layout: layout, lexicon: lexicon, personal: personal, pathScore: &pathScore)
        }
        guard !extra.isEmpty else { return readings }
        let tapped = gesture.evidence.events.contains { $0.role == .tap }
        let cap = paths.count == 1 ? readings.map(\.score).max().map { $0 - DecodeResult.confidenceMargin - 0.01 } : nil
        let leaderLocation: CGFloat? = {
            guard paths.count == 1, !tapped, let path = paths.first,
                  let leader = readings.max(by: { $0.score < $1.score }) else { return nil }
            return location(of: leader.word, path: path, layout: layout, pathScore: &pathScore)
        }()
        var best: [String: DecodeResult.Reading] = [:]
        for reading in readings {
            best[reading.word.lowercased()] = reading
        }
        for reading in extra {
            let key = reading.word.lowercased()
            // The beam already explained this word. Its score stands. The two scores are not added.
            if best[key] != nil { continue }
            var score = reading.score + habitBonus(reading.word, habits: habits)
            if let cap {
                let clearlyCloser = !tapped && paths.count == 1 && paths.first.map { path in
                    isClearlyCloser(reading.word, than: leaderLocation, path: path, layout: layout, pathScore: &pathScore)
                } == true
                if !clearlyCloser { score = min(score, cap) }
            }
            best[key] = DecodeResult.Reading(word: reading.word, score: score)
        }
        return best.values.sorted { $0.score > $1.score }
    }

    /// The shape word leads only when its path sits at least 0.35 key widths closer than the beam leader.
    private static func isClearlyCloser(
        _ word: String,
        than leader: CGFloat?,
        path: [CGPoint],
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Bool {
        guard let leader, let shape = location(of: word, path: path, layout: layout, pathScore: &pathScore) else { return false }
        return leader - shape >= 0.35
    }

    private static func singleStrokeNominations(
        _ paths: [[CGPoint]],
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        pathScore: inout PathScore
    ) -> [DecodeResult.Reading] {
        guard paths.count == 1, let path = paths.first, path.count >= 2 else { return [] }
        return PathDecoder.nominate(
            path: path,
            gateLength: true,
            layout: layout,
            lexicon: lexicon,
            personal: personal,
            pathScore: &pathScore
        ).result.readings
    }

    private static func joinedNominations(
        _ paths: [[CGPoint]],
        gesture: SwipeGesture,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        costs: AlignmentCosts,
        pathScore: inout PathScore
    ) -> [DecodeResult.Reading] {
        guard paths.count == 2 else { return [] }
        let halves = paths.enumerated().map { index, path in
            strokePieces(on: path, stroke: index, gesture: gesture, layout: layout, lexicon: lexicon, personal: personal, pathScore: &pathScore)
        }
        var seen = Set<String>()
        var readings: [DecodeResult.Reading] = []
        for left in halves[0] {
            for right in halves[1] {
                considerJoin(left + right, gesture: gesture, layout: layout, lexicon: lexicon, personal: personal, costs: costs, pathScore: &pathScore, seen: &seen, into: &readings)
                considerJoin(right + left, gesture: gesture, layout: layout, lexicon: lexicon, personal: personal, costs: costs, pathScore: &pathScore, seen: &seen, into: &readings)
            }
        }
        return readings
    }

    private static func strokePieces(
        on path: [CGPoint],
        stroke index: Int,
        gesture: SwipeGesture,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        pathScore: inout PathScore
    ) -> [String] {
        var piece: [String] = []
        if path.count >= 2 {
            let nominated = PathDecoder.nominate(
                path: path,
                gateLength: true,
                layout: layout,
                lexicon: lexicon,
                personal: personal,
                pathScore: &pathScore
            )
            piece.append(contentsOf: nominated.result.words.prefix(shapePieceLimit))
        }
        let aimed = aimedPiece(stroke: index, gesture: gesture)
        if aimed.count >= 2, !piece.contains(where: { $0.compare(aimed, options: .caseInsensitive) == .orderedSame }) {
            piece.append(aimed)
        }
        return piece
    }

    /// Anchors one thumb aimed at, in order. Used as a piece even when those letters are not
    /// themselves a dictionary word, so "li" plus "ve" can become "live".
    private static func aimedPiece(stroke index: Int, gesture: SwipeGesture) -> String {
        let letters = gesture.evidence.events.compactMap { event -> String? in
            guard event.strokeIndex == index, event.role == .anchor else { return nil }
            return event.letter
        }
        return BeatChooser.collapse(letters.joined())
    }

    private static func considerJoin(
        _ text: String,
        gesture: SwipeGesture,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        costs: AlignmentCosts,
        pathScore: inout PathScore,
        seen: inout Set<String>,
        into readings: inout [DecodeResult.Reading]
    ) {
        guard let known = knownWord(text, lexicon: lexicon, personal: personal) else { return }
        let key = known.display.lowercased()
        guard seen.insert(key).inserted else { return }
        let fit = wordOnStrokes(LexiconKey.make(known.display), gesture: gesture, layout: layout, pathScore: &pathScore)
        guard fit < 0, fit > -8 else { return }
        readings.append(DecodeResult.Reading(
            word: known.display,
            score: fit + costs.frequencyWeight * known.logCount
        ))
    }

    private static func knownWord(
        _ text: String,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry]
    ) -> (display: String, logCount: Double)? {
        let key = LexiconKey.make(text)
        guard key.count >= 2 else { return nil }
        let matches = lexicon.indices(ofKey: key)
        if let index = matches.max(by: { lexicon.logCount(at: $0) < lexicon.logCount(at: $1) }) {
            return (lexicon.display(at: index), lexicon.logCount(at: index))
        }
        if let entry = personal.first(where: { $0.key == key }) {
            return (entry.display, entry.logCount)
        }
        return nil
    }

    /// Words both thumbs' anchors sit inside, including an interleaving the left-plus-right
    /// join never spells. Each thumb is scored on its own path. `wordOnStrokes` would require
    /// the thumbs to own sequential slices, so "l v" plus "i e" could not be "live".
    private static func mergedNominations(
        _ readings: [DecodeResult.Reading],
        gesture: SwipeGesture,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        costs: AlignmentCosts,
        pathScore: inout PathScore
    ) -> [DecodeResult.Reading] {
        let thumbs = thumbs(in: gesture)
        guard thumbs.count == 2 else { return [] }
        let left = thumbs[0].letters
        let right = thumbs[1].letters
        guard let leftFirst = left.first, let leftLast = left.last,
              let rightFirst = right.first, let rightLast = right.last else { return [] }
        let maxLength = left.count + right.count + 2
        let fit = thumbFit(thumbs, layout: layout, pathScore: &pathScore)
        guard fit < 0, fit > -8 else { return [] }
        let beamCoversBoth = readings.contains { reading in
            let key = LexiconKey.make(reading.word)
            return key.withUnsafeBytes { raw in
                isSubsequence(left, of: raw) && isSubsequence(right, of: raw)
            }
        }
        let ceiling = beamCoversBoth ? readings.map(\.score).max() : nil

        var pairs: [(UInt8, UInt8)] = []
        for first in [leftFirst, rightFirst] {
            for last in [leftLast, rightLast] where !pairs.contains(where: { $0.0 == first && $0.1 == last }) {
                pairs.append((first, last))
            }
        }
        var best: [(word: String, score: Double, logCount: Double, spare: Int)] = []
        func keep(_ display: String, logCount: Double, key: UnsafeRawBufferPointer) {
            guard key.count >= 2, key.count <= maxLength else { return }
            guard isSubsequence(left, of: key), isSubsequence(right, of: key) else { return }
            let spare = max(0, key.count - left.count - right.count)
            guard spare <= 2 else { return }
            var score = fit + costs.frequencyWeight * logCount - costs.lengthWeight * Double(spare)
            if let ceiling { score = min(score, ceiling - 0.01) }
            if best.contains(where: { $0.word.compare(display, options: .caseInsensitive) == .orderedSame }) { return }
            let position = best.firstIndex { $0.score < score } ?? best.count
            best.insert((display, score, logCount, spare), at: position)
            if best.count > 8 { best.removeLast() }
        }
        for (first, last) in pairs {
            let bucket = lexicon.bucket(first: first, last: last)
            let limit = min(PathDecoder.bucketScanLimit, bucket.count)
            for offset in 0..<limit {
                let index = Int(bucket[offset])
                keep(lexicon.display(at: index), logCount: lexicon.logCount(at: index), key: lexicon.key(at: index))
            }
        }
        for entry in personal {
            guard let first = entry.key.first, let last = entry.key.last,
                  pairs.contains(where: { $0.0 == first && $0.1 == last }) else { continue }
            entry.key.withUnsafeBytes { raw in
                keep(entry.display, logCount: entry.logCount, key: raw)
            }
        }
        for index in best.indices {
            let shaped = wordOnStrokes(LexiconKey.make(best[index].word), gesture: gesture, layout: layout, pathScore: &pathScore)
            guard shaped < 0, shaped > -8 else { continue }
            var score = shaped + costs.frequencyWeight * best[index].logCount - costs.lengthWeight * Double(best[index].spare)
            if let ceiling { score = min(score, ceiling - 0.01) }
            best[index].score = score
        }
        best.sort { $0.score > $1.score }
        return best.map { DecodeResult.Reading(word: $0.word, score: $0.score) }
    }

    /// Both thumbs followed their own letters. One unscored thumb rejects the merge.
    private static func thumbFit(
        _ thumbs: [ThumbSlice],
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double {
        var total = 0.0
        for thumb in thumbs {
            let fit = pathFit(thumb.letters, path: thumb.path, layout: layout, pathScore: &pathScore)
            guard fit < 0, fit > -8 else { return -8 }
            total += fit
        }
        return total / Double(thumbs.count)
    }

    private static func isSubsequence(_ needle: [UInt8], of word: UnsafeRawBufferPointer) -> Bool {
        var index = 0
        for byte in word where index < needle.count && byte == needle[index] {
            index += 1
        }
        return index == needle.count
    }

    private static func merge(_ primary: [DecodeResult.Reading], _ extra: [DecodeResult.Reading]) -> [DecodeResult.Reading] {
        var best: [String: DecodeResult.Reading] = [:]
        for reading in primary + extra {
            let key = reading.word.lowercased()
            if let existing = best[key], existing.score >= reading.score { continue }
            best[key] = reading
        }
        return best.values.sorted { $0.score > $1.score }
    }
}

/// Product rules that sit outside the beam: an exact spelling leads when it is close, and a
/// long miss keeps the aimed letters on the bar so a name can be tapped back. Scores are not rewritten.
enum ReadingPolicy {
    static let literalLimit = 2
    /// An exact spelling may sit this far behind the leader and still move first. "pill" from
    /// the keys p-i-l beats a slightly better "pull". A doubled single key, many points worse,
    /// stays where its score put it.
    static let exactLead = 1.0

    static func apply(_ result: DecodeResult, aimed: String, limit: Int = 4) -> DecodeResult {
        let letters = BeatChooser.collapse(aimed)
        var readings = result.readings
        let aligned = readings.filter { WordJoiner.aligns($0.word, traced: letters) }
        if let bestAligned = aligned.map(\.score).max(),
           let overall = readings.map(\.score).max(),
           let chosen = aligned
            .filter({ $0.score + exactLead >= bestAligned && $0.score + exactLead >= overall })
            .max(by: { lhs, rhs in
                let left = lhs.word.filter(\.isLetter).count
                let right = rhs.word.filter(\.isLetter).count
                if left != right { return left < right }
                return lhs.score < rhs.score
            }) {
            readings.removeAll { $0.word.lowercased() == chosen.word.lowercased() }
            readings.insert(chosen, at: 0)
        }
        if readings.count > limit {
            readings = Array(readings.prefix(limit))
        }
        if letters.count > literalLimit,
           let top = readings.first,
           !WordJoiner.aligns(top.word, traced: letters),
           !readings.contains(where: { $0.word.compare(letters, options: .caseInsensitive) == .orderedSame }) {
            readings.append(DecodeResult.Reading(word: letters, score: top.score - DecodeResult.confidenceMargin - 1))
        }
        return result.replacingReadings(readings)
    }
}

/// Holds the scratch path buffers and runs the search off the main thread.
actor AlignmentDecoder {
    private var pathScore = PathScore()

    func decode(
        _ gesture: SwipeGesture,
        layout: LetterLayout,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        lexicon: MappedLexicon,
        costs: AlignmentCosts,
        expected: [String] = [],
        habits: [String: Double] = [:]
    ) -> DecodeResult {
        AlignmentSearch.decode(
            gesture,
            layout: layout,
            lexicon: lexicon,
            personal: personal,
            bigram: bigram,
            costs: costs,
            expected: expected,
            habits: habits,
            pathScore: &pathScore
        )
    }
}

private extension SwipeEvent {
    var directionLength: CGFloat { hypot(directionX, directionY) }
}
