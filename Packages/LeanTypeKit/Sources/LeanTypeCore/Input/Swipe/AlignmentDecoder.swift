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
        pathScore: inout PathScore
    ) -> DecodeResult {
        let raw = gesture.evidence.events.isEmpty
            ? SwipeEvidence.fromObservations(gesture.observations).events
            : gesture.evidence.events
        let events = raw.sorted { $0.time < $1.time }
        guard !events.isEmpty else { return .empty }

        var readings: [DecodeResult.Reading] = []
        for order in orders(of: events, costs: costs) {
            let penalty = orderPenalty(order, costs: costs)
            let ranked = beam(order, layout: layout, lexicon: lexicon, personal: personal, bigram: bigram, costs: costs)
                .map { DecodeResult.Reading(word: $0.word, score: $0.score - penalty) }
            readings = merge(readings, ranked)
        }
        readings = rescore(readings, gesture: gesture, layout: layout, costs: costs, pathScore: &pathScore)
        let aimed = gesture.evidence.aimedLetters.isEmpty ? gesture.tracedLetters : gesture.evidence.aimedLetters
        return ReadingPolicy.apply(DecodeResult(readings: readings), aimed: aimed, limit: costs.resultLimit)
    }

    // MARK: - Order

    /// Time order, plus a few adjacent swaps of different fingers that landed close together.
    private static func orders(of events: [SwipeEvent], costs: AlignmentCosts) -> [[SwipeEvent]] {
        guard events.count >= 2, events.count <= 18 else { return [events] }
        var indexes: [[Int]] = [Array(events.indices)]
        var seen: Set<String> = [key(indexes[0])]
        var cursor = 0
        while cursor < indexes.count, indexes.count < 6 {
            let order = indexes[cursor]
            cursor += 1
            for index in 0..<(order.count - 1) {
                let left = events[order[index]]
                let right = events[order[index + 1]]
                guard canSwap(left, right, costs: costs) else { continue }
                var swapped = order
                swapped.swapAt(index, index + 1)
                let name = key(swapped)
                guard seen.insert(name).inserted else { continue }
                indexes.append(swapped)
                if indexes.count == 6 { break }
            }
        }
        return indexes.map { order in order.map { events[$0] } }
    }

    /// What this order paid to read two different fingers out of time. Time order pays nothing.
    private static func orderPenalty(_ events: [SwipeEvent], costs: AlignmentCosts) -> Double {
        var penalty = 0.0
        for index in 1..<events.count {
            guard events[index].time < events[index - 1].time else { continue }
            penalty += costs.transpositionPenalty(gap: events[index - 1].time - events[index].time)
        }
        return penalty
    }

    private static func canSwap(_ left: SwipeEvent, _ right: SwipeEvent, costs: AlignmentCosts) -> Bool {
        left.strokeIndex != right.strokeIndex && abs(left.time - right.time) <= costs.swapWindow
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
        _ events: [SwipeEvent],
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        costs: AlignmentCosts
    ) -> [DecodeResult.Reading] {
        var beam = [Hypothesis(letters: [], score: 0, anchorSkips: 0, lastX: 0, lastY: 0, placed: false, lastStroke: nil)]
        for event in events {
            var next: [Hypothesis] = []
            next.reserveCapacity(beam.count * (costs.neighborLimit + 2))
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
                if let skipped = skip(hypothesis, event: event, layout: layout, costs: costs) {
                    next.append(skipped)
                }
            }
            beam = prune(next, width: costs.beamWidth)
            if beam.isEmpty { return [] }
        }

        var scored: [Scored] = []
        for hypothesis in beam {
            consider(hypothesis, lexicon: lexicon, personal: personal, costs: costs, into: &scored)
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
        costs: AlignmentCosts
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
            skipped.score -= costs.crossingSkipBase + costs.crossingSkipCentral * closeness
            return skipped
        }
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

    private static func prune(_ hypotheses: [Hypothesis], width: Int) -> [Hypothesis] {
        var best: [String: Hypothesis] = [:]
        best.reserveCapacity(hypotheses.count)
        for hypothesis in hypotheses {
            let key = String(decoding: hypothesis.letters, as: UTF8.self)
            if let existing = best[key], existing.score >= hypothesis.score { continue }
            best[key] = hypothesis
        }
        return best.values.sorted { $0.score > $1.score }.prefix(width).map { $0 }
    }

    private static func consider(
        _ hypothesis: Hypothesis,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        costs: AlignmentCosts,
        into scored: inout [Scored]
    ) {
        guard hypothesis.letters.count >= 2 else { return }
        let matches = lexicon.indices(ofKey: hypothesis.letters)
        if !matches.isEmpty {
            for index in matches {
                scored.append(Scored(
                    source: .dictionary(index),
                    score: hypothesis.score + costs.frequencyWeight * lexicon.logCount(at: index)
                ))
            }
            return
        }
        for (offset, entry) in personal.enumerated() where entry.key == hypothesis.letters {
            scored.append(Scored(
                source: .personal(offset),
                score: hypothesis.score + costs.frequencyWeight * entry.logCount
            ))
        }
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

/// Product rules that sit outside the beam: an exact spelling leads, and a long miss keeps
/// the aimed letters on the bar so a name can be tapped back. Scores are not rewritten.
enum ReadingPolicy {
    static let literalLimit = 2

    static func apply(_ result: DecodeResult, aimed: String, limit: Int = 4) -> DecodeResult {
        let letters = BeatChooser.collapse(aimed)
        var readings = result.readings
        if let aligned = readings.filter({ WordJoiner.aligns($0.word, traced: letters) }).max(by: { $0.score < $1.score }) {
            readings.removeAll { $0.word.lowercased() == aligned.word.lowercased() }
            readings.insert(aligned, at: 0)
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
        costs: AlignmentCosts
    ) -> DecodeResult {
        AlignmentSearch.decode(
            gesture,
            layout: layout,
            lexicon: lexicon,
            personal: personal,
            bigram: bigram,
            costs: costs,
            pathScore: &pathScore
        )
    }
}

private extension SwipeEvent {
    var directionLength: CGFloat { hypot(directionX, directionY) }
}
