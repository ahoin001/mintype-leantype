import CoreGraphics
import Foundation

/// Every hand-set number the alignment search uses, in one place.
struct AlignmentCosts: Sendable {
    var sigmaX: CGFloat = 0.55
    var sigmaY: CGFloat = 0.40
    var anchorSkip: Double = 3.2
    /// A long rest beside another stroke. It does not spend the anchor-skip budget.
    var restSkip: Double = 0.8
    /// A second hit on the same key inside 60 ms.
    var slipSkip: Double = 0.05
    var maxAnchorSkips: Int = 2
    var crossingSkipBase: Double = 0.05
    var crossingSkipCentral: Double = 1.15
    var passThroughPenalty: Double = 0.35
    var doublePenalty: Double = 0.25
    var frequencyWeight: Double = 0.22
    var bigramWeight: Double = 0.30
    var motionWeight: Double = 0.45
    var lengthWeight: Double = 1.4
    var seamBias: Double = 0.35
    var beamWidth: Int = 28
    var neighborRadius: CGFloat = 1.5
    /// A pinned hold only considers keys this close, in key widths.
    var pinNeighborRadius: CGFloat = 0.3
    var neighborLimit: Int = 6
    var resultLimit: Int = 4
    /// Cost per second of reading a later chain before an earlier one. It saturates.
    var inversionRate: Double = 2.4
    var inversionCap: Double = 1.6
    /// An inversion costs this much of the full gap when the other thumb was down across it.
    var heldOrderDiscount: Double = 0.5
    /// One letter the finger never touched. Above `ReadingPolicy.exactLead`.
    var omissionCost: Double = 1.15
    /// Two adjacent letters inside one chain, swapped. Above `ReadingPolicy.exactLead`.
    var transposeCost: Double = 1.15
    /// Set on the recovery pass. The first pass never inserts or transposes.
    var allowsEdits: Bool = false
    /// Set on the recovery pass so a poor shape is a penalty instead of a drop.
    var keepWeakFits: Bool = false
    /// A preview below this is withdrawn once the path has grown past it.
    static let previewFloor = -15.0
    /// A first result at or below this is weak enough to run the recovery pass.
    static let weakScore = -6.0

    static let standard = AlignmentCosts()

    /// The same search, looking farther, and allowed one omission and one transposition.
    static var recovery: AlignmentCosts {
        var costs = AlignmentCosts()
        costs.neighborLimit = 10
        costs.neighborRadius = 2.5
        costs.beamWidth = 48
        costs.allowsEdits = true
        costs.keepWeakFits = true
        return costs
    }

}

/// Wall clock for one decode. The search reads it every few expansions and returns
/// the best reading it already has once `deadline` has passed.
final class SearchClock: @unchecked Sendable {
    /// How long one decode may run before it returns what it has. Recovery does not start after this.
    static let responseBudget = 0.012

    let deadline: Double
    let now: () -> Double
    private var steps = 0

    init(now: @escaping () -> Double, deadline: Double) {
        self.now = now
        self.deadline = deadline
    }

    static func budgeted(now: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate }) -> SearchClock {
        SearchClock(now: now, deadline: now() + responseBudget)
    }

    /// No deadline. Used when the caller did not ask for one, including debug runs where
    /// coverage makes a 12 ms wall clock expire before a word is finished.
    static let unlimited = SearchClock(now: { 0 }, deadline: .greatestFiniteMagnitude)

    /// The clock a shipping decode should use. Debug builds leave it open so a coverage
    /// run can finish a word; the 12 ms cutoff is what release ships, and tests inject a clock.
    static func responseClock() -> SearchClock? {
        #if DEBUG
        return nil
        #else
        return budgeted()
        #endif
    }

    /// True once the deadline has passed. Checked once per expansion step, not per hypothesis.
    func shouldStop() -> Bool {
        steps += 1
        guard steps.isMultiple(of: 4) else { return false }
        return now() >= deadline
    }

    var isPastDeadline: Bool { now() >= deadline }
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
        trace: DecodeTraceSink? = nil,
        clock: SearchClock? = nil,
        pathScore: inout PathScore
    ) -> DecodeResult {
        let budget = clock ?? SearchClock.unlimited
        let raw = gesture.evidence.events.isEmpty
            ? SwipeEvidence.fromObservations(gesture.observations).events
            : gesture.evidence.events
        let events = raw.sorted { $0.time < $1.time }
        guard !events.isEmpty else { return .empty }
        let steps = StrokeChannel.steps(from: events, keyWidth: layout.keyWidth, keyHeight: layout.keyHeight)
        let crossingScale = crossingScale(of: events)
        let chains = ThumbChains.make(steps)
        let aimed = gesture.evidence.aimedLetters.isEmpty ? gesture.tracedLetters : gesture.evidence.aimedLetters
        trace?.trace.aimedLetters = aimed

        var readings: [DecodeResult.Reading] = []
        if costs.allowsEdits {
            readings = beam(
                chains,
                layout: layout,
                lexicon: lexicon,
                personal: personal,
                bigram: bigram,
                costs: costs,
                habits: habits,
                expected: expected,
                crossingScale: crossingScale,
                clock: budget
            )
        } else {
            let ranked = ladder(
                steps,
                layout: layout,
                lexicon: lexicon,
                personal: personal,
                bigram: bigram,
                costs: costs,
                habits: habits,
                crossingScale: crossingScale,
                clock: budget,
                gesture: gesture
            )
            readings = ranked
            if thumbsOverlap(steps), !budget.isPastDeadline {
                let chained = beam(
                    chains,
                    layout: layout,
                    lexicon: lexicon,
                    personal: personal,
                    bigram: bigram,
                    costs: costs,
                    habits: habits,
                    expected: expected,
                    crossingScale: crossingScale,
                    clock: budget
                )
                readings = merge(readings, chained)
            }
        }
        trace?.trace.beamWords = readings.map(\.word)
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
        readings = FollowerPrior.applying(readings, expected: expected)
        let result = ReadingPolicy.apply(
            DecodeResult(readings: readings),
            aimed: aimed,
            habits: habits,
            limit: costs.resultLimit
        )
        trace?.trace.readings = result.readings.map(\.word)
        guard !costs.allowsEdits, isWeak(result, aimed: aimed), !budget.isPastDeadline else { return result }
        trace?.trace.recovered = true
        let wide = AlignmentCosts.recovery
        let recovered = decode(
            gesture,
            layout: layout,
            lexicon: lexicon,
            personal: personal,
            bigram: bigram,
            costs: wide,
            expected: expected,
            habits: habits,
            trace: trace,
            clock: budget,
            pathScore: &pathScore
        )
        let combined = ReadingPolicy.apply(
            DecodeResult(readings: merge(result.readings, recovered.readings)),
            aimed: aimed,
            habits: habits,
            limit: costs.resultLimit
        )
        trace?.trace.readings = combined.readings.map(\.word)
        return combined
    }

    /// A poor score, or a tie whose leader is not the aimed spelling.
    /// A solid aimed hit, even a close one, does not come back through here.
    private static func isWeak(_ result: DecodeResult, aimed: String) -> Bool {
        guard let top = result.readings.first else { return true }
        if top.score <= AlignmentCosts.weakScore { return true }
        return result.isUnsure && !WordJoiner.aligns(top.word, traced: aimed)
    }

    /// Four bits per slot. Moving strokes use slots 0...3. Taps, whose stroke indexes are
    /// −2 and below, use slots 4...7. Each thumb can spend its own skip budget.
    private struct SkipCounts: Sendable {
        private var bits: UInt32 = 0

        func allows(_ stroke: Int, limit: Int) -> Bool {
            Int(count(of: stroke)) < limit
        }

        func adding(_ stroke: Int) -> SkipCounts {
            var copy = self
            let shift = slot(of: stroke) * 4
            let mask: UInt32 = 0xF << shift
            let next = min((bits >> shift) & 0xF, 14) + 1
            copy.bits = (bits & ~mask) | (next << shift)
            return copy
        }

        private func count(of stroke: Int) -> UInt32 {
            (bits >> (slot(of: stroke) * 4)) & 0xF
        }

        private func slot(of stroke: Int) -> Int {
            if stroke >= 0 { return min(stroke, 3) }
            return min(4 + max(0, -stroke - 2), 7)
        }
    }

    // MARK: - Beam

    private struct Hypothesis {
        var letters: [UInt8]
        var score: Double
        var skips: SkipCounts
        var lastX: CGFloat
        var lastY: CGFloat
        var placed: Bool
        var lastStroke: Int?
        var cursors: [UInt8]
        var omitted: Bool
        /// The chain whose skipped step must be read next, after a within-chain swap.
        var debtChain: Int?
        var debtIndex: UInt8?
        /// This step ignored an anchor. Kept in the beam even when matching it scores higher.
        var justSkipped: Bool = false
    }

    private struct Scored {
        enum Source {
            case dictionary(Int)
            case personal(Int)
        }

        var source: Source
        var score: Double
    }

    /// True when both thumbs' events overlap in time, so a block reading is worth a second search.
    private static func thumbsOverlap(_ steps: [StrokeChannel.Step]) -> Bool {
        var spans: [Int: (start: Double, end: Double)] = [:]
        for step in steps where step.strokeIndex >= 0 {
            if var span = spans[step.strokeIndex] {
                span.start = min(span.start, step.time)
                span.end = max(span.end, step.time)
                spans[step.strokeIndex] = span
            } else {
                spans[step.strokeIndex] = (step.time, step.time)
            }
        }
        let ranges = Array(spans.values)
        guard ranges.count >= 2 else { return false }
        for index in ranges.indices {
            for other in ranges.indices where other > index {
                if ranges[index].start <= ranges[other].end, ranges[other].start <= ranges[index].end {
                    return true
                }
            }
        }
        return false
    }

    /// Every anchor on every chain has been taken or skipped.
    private static func finished(_ hypothesis: Hypothesis, chains: ThumbChains) -> Bool {
        guard hypothesis.debtChain == nil else { return false }
        for index in chains.chains.indices {
            if Int(hypothesis.cursors[index]) < chains.chains[index].count { return false }
        }
        return true
    }

    /// Width 4, then 12, then the full beam. A stage that dies keeps the last reading that consumed every anchor.
    private static func ladder(
        _ steps: [StrokeChannel.Step],
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        costs: AlignmentCosts,
        habits: [String: Double],
        crossingScale: Double,
        clock: SearchClock,
        gesture: SwipeGesture
    ) -> [DecodeResult.Reading] {
        let widths = [4, 12, costs.beamWidth]
        var best: [DecodeResult.Reading] = []
        for width in widths {
            if clock.isPastDeadline {
                ClockExpiryLog.note(gesture)
                break
            }
            var stage = costs
            stage.beamWidth = min(width, costs.beamWidth)
            let ranked = linearBeam(
                steps,
                layout: layout,
                lexicon: lexicon,
                personal: personal,
                bigram: bigram,
                costs: stage,
                habits: habits,
                crossingScale: crossingScale,
                clock: clock
            )
            if !ranked.isEmpty { best = ranked }
            if clock.isPastDeadline {
                if ranked.isEmpty { ClockExpiryLog.note(gesture) }
                break
            }
            if width == costs.beamWidth { break }
        }
        return best
    }

    /// One order, walked from first step to last. Skips stay in the beam because nothing else is competing for it.
    private static func linearBeam(
        _ steps: [StrokeChannel.Step],
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        costs: AlignmentCosts,
        habits: [String: Double],
        crossingScale: Double,
        clock: SearchClock
    ) -> [DecodeResult.Reading] {
        let habitBuckets = habitBuckets(from: habits)
        var walked = [Hypothesis(
            letters: [],
            score: 0,
            skips: SkipCounts(),
            lastX: 0,
            lastY: 0,
            placed: false,
            lastStroke: nil,
            cursors: [],
            omitted: false,
            debtChain: nil,
            debtIndex: nil,
            justSkipped: false
        )]
        var consumedAll = true
        for (offset, step) in steps.enumerated() {
            if clock.shouldStop() {
                consumedAll = false
                break
            }
            var next: [Hypothesis] = []
            if let event = step.event {
                let letters = candidates(for: event, layout: layout, costs: costs)
                for hypothesis in walked {
                    for letter in letters {
                        if let grown = extend(hypothesis, with: letter, times: 1, event: event, layout: layout, lexicon: lexicon, personal: personal, bigram: bigram, costs: costs) {
                            next.append(grown)
                        }
                        if event.dwell < GestureComposer.dwellDuration,
                           let doubled = extend(hypothesis, with: letter, times: 2, event: event, layout: layout, lexicon: lexicon, personal: personal, bigram: bigram, costs: costs) {
                            next.append(doubled)
                        }
                    }
                    if let skipped = skip(hypothesis, event: event, layout: layout, costs: costs, crossingScale: crossingScale) {
                        next.append(skipped)
                    }
                }
            } else {
                for hypothesis in walked {
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
            let width = offset == steps.count - 1 ? costs.beamWidth * 3 : costs.beamWidth
            walked = prune(next, width: width, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
            if walked.isEmpty { return [] }
        }
        guard consumedAll else { return [] }
        var scored: [Scored] = []
        for hypothesis in walked {
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

    private static func beam(
        _ chains: ThumbChains,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        costs: AlignmentCosts,
        habits: [String: Double],
        expected: [String],
        crossingScale: Double,
        clock: SearchClock
    ) -> [DecodeResult.Reading] {
        let habitBuckets = habitBuckets(from: habits)
        guard !chains.chains.isEmpty else { return [] }
        let start = Hypothesis(
            letters: [],
            score: 0,
            skips: SkipCounts(),
            lastX: 0,
            lastY: 0,
            placed: false,
            lastStroke: nil,
            cursors: Array(repeating: 0, count: chains.chains.count),
            omitted: false,
            debtChain: nil,
            debtIndex: nil,
            justSkipped: false
        )
        // The on-time beam is one chain walked in order, so a skip stays in the budget.
        // A chain read early lives in the other beam and does not crowd that walk out.
        var timely = [start]
        var late: [Hypothesis] = []
        var consumedAll = true
        for _ in 0..<chains.eventCount {
            if clock.shouldStop() {
                consumedAll = false
                break
            }
            var nextTimely: [Hypothesis] = []
            var nextLate: [Hypothesis] = []
            let parents = timely.map { ($0, true) } + late.map { ($0, false) }
            for (hypothesis, parentIsTimely) in parents {
                func keep(_ items: [Hypothesis], onTime: Bool) {
                    if parentIsTimely && onTime {
                        nextTimely.append(contentsOf: items)
                    } else {
                        nextLate.append(contentsOf: items)
                    }
                }
                if let debtChain = hypothesis.debtChain, let debtIndex = hypothesis.debtIndex,
                   chains.chains.indices.contains(debtChain),
                   Int(debtIndex) < chains.chains[debtChain].count {
                    let step = chains.chains[debtChain][Int(debtIndex)]
                    var cleared = hypothesis
                    cleared.debtChain = nil
                    cleared.debtIndex = nil
                    keep(expansions(
                        of: cleared,
                        step: step,
                        layout: layout,
                        lexicon: lexicon,
                        personal: personal,
                        bigram: bigram,
                        costs: costs,
                        crossingScale: crossingScale,
                        inversion: 0
                    ), onTime: true)
                    continue
                }
                if costs.allowsEdits, !hypothesis.omitted {
                    keep(omissions(
                        from: hypothesis,
                        chains: chains,
                        layout: layout,
                        lexicon: lexicon,
                        personal: personal,
                        bigram: bigram,
                        costs: costs
                    ), onTime: true)
                }
                let earliest = earliestTime(hypothesis, chains: chains)
                let tapFence = pendingTapTime(hypothesis, chains: chains)
                for index in chains.chains.indices {
                    let cursor = Int(hypothesis.cursors[index])
                    guard cursor < chains.chains[index].count else { continue }
                    let step = chains.chains[index][cursor]
                    // A tap already down is a letter the user placed. A later stroke
                    // does not jump ahead of it.
                    if step.event?.isTap != true, let tapFence, step.time > tapFence + 0.000_1 {
                        continue
                    }
                    var advanced = hypothesis
                    advanced.cursors[index] &+= 1
                    let inversion = inversionCost(
                        of: step.time,
                        after: earliest,
                        costs: costs,
                        held: otherThumbCovers(step.time, besides: index, chains: chains)
                    )
                    let onTime = step.time <= earliest + 0.000_1
                    keep(expansions(
                        of: advanced,
                        step: step,
                        layout: layout,
                        lexicon: lexicon,
                        personal: personal,
                        bigram: bigram,
                        costs: costs,
                        crossingScale: crossingScale,
                        inversion: inversion,
                        neighbors: onTime
                    ), onTime: onTime)
                    let following = cursor + 1
                    if costs.allowsEdits, hypothesis.debtChain == nil, following < chains.chains[index].count,
                       chains.chains[index][cursor].event != nil, chains.chains[index][following].event != nil {
                        let taken = chains.chains[index][following]
                        var swapped = hypothesis
                        swapped.cursors[index] = UInt8(min(following + 1, Int(UInt8.max)))
                        swapped.debtChain = index
                        swapped.debtIndex = UInt8(cursor)
                        swapped.score -= costs.transposeCost
                        keep(expansions(
                            of: swapped,
                            step: taken,
                            layout: layout,
                            lexicon: lexicon,
                            personal: personal,
                            bigram: bigram,
                            costs: costs,
                            crossingScale: crossingScale,
                            inversion: inversionCost(
                                of: taken.time,
                                after: earliest,
                                costs: costs,
                                held: otherThumbCovers(taken.time, besides: index, chains: chains)
                            )
                        ), onTime: false)
                    }
                }
            }
            timely = keepingSkips(in: nextTimely, pruned: prune(nextTimely, width: costs.beamWidth, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets), lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
            late = keepingSkips(in: nextLate, pruned: prune(nextLate, width: costs.beamWidth, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets), lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
            if timely.isEmpty && late.isEmpty { return [] }
        }
        if !consumedAll {
            timely = timely.filter { finished($0, chains: chains) }
            late = late.filter { finished($0, chains: chains) }
        }

        var scored: [Scored] = []
        for hypothesis in timely + late {
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

    /// The letter a later chain actually hit. Neighbors stay on the chain that is on time,
    /// so a reorder does not crowd the skips out of the beam.
    private static func aimedLetter(of event: SwipeEvent) -> [UInt8] {
        guard let traced = event.letter.lowercased().utf8.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(traced) else { return [] }
        return [traced]
    }

    private static func candidates(for event: SwipeEvent, layout: LetterLayout, costs: AlignmentCosts) -> [UInt8] {
        let radius = event.role == .pin ? costs.pinNeighborRadius : costs.neighborRadius
        var letters = layout.letters(near: event.point, within: radius, limit: costs.neighborLimit)
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
        var score = hypothesis.score - spatialCost(event, letter: letter, layout: layout, costs: costs)
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
            skips: hypothesis.skips,
            lastX: center.x,
            lastY: center.y,
            placed: true,
            lastStroke: event.strokeIndex,
            cursors: hypothesis.cursors,
            omitted: hypothesis.omitted,
            debtChain: hypothesis.debtChain,
            debtIndex: hypothesis.debtIndex,
            justSkipped: false
        )
    }

    /// Match or skip one step. `inversion` is what this chain paid to be read out of time.
    private static func expansions(
        of hypothesis: Hypothesis,
        step: StrokeChannel.Step,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        costs: AlignmentCosts,
        crossingScale: Double,
        inversion: Double,
        neighbors: Bool = true
    ) -> [Hypothesis] {
        var results: [Hypothesis] = []
        if let event = step.event {
            let letters = neighbors
                ? candidates(for: event, layout: layout, costs: costs)
                : aimedLetter(of: event)
            for letter in letters {
                if let grown = extend(hypothesis, with: letter, times: 1, event: event, layout: layout, lexicon: lexicon, personal: personal, bigram: bigram, costs: costs) {
                    var grown = grown
                    grown.score -= inversion
                    results.append(grown)
                }
                if event.dwell < GestureComposer.dwellDuration,
                   let doubled = extend(hypothesis, with: letter, times: 2, event: event, layout: layout, lexicon: lexicon, personal: personal, bigram: bigram, costs: costs) {
                    var doubled = doubled
                    doubled.score -= inversion
                    results.append(doubled)
                }
            }
            if let skipped = skip(hypothesis, event: event, layout: layout, costs: costs, crossingScale: crossingScale) {
                var skipped = skipped
                skipped.score -= inversion
                results.append(skipped)
            }
        } else {
            var skipped = skipChannel(hypothesis, costs: costs, crossingScale: crossingScale)
            skipped.score -= inversion
            results.append(skipped)
            var seen = Set<UInt8>()
            for event in step.channel {
                guard let letter = event.letter.lowercased().utf8.first,
                      (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(letter),
                      seen.insert(letter).inserted else { continue }
                if let grown = extend(hypothesis, with: letter, times: 1, event: event, layout: layout, lexicon: lexicon, personal: personal, bigram: bigram, costs: costs) {
                    var grown = grown
                    grown.score -= inversion
                    results.append(grown)
                }
            }
        }
        return results
    }

    /// One letter near the next key, charged as a miss rather than a touch.
    private static func omissions(
        from hypothesis: Hypothesis,
        chains: ThumbChains,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        bigram: LetterBigram,
        costs: AlignmentCosts
    ) -> [Hypothesis] {
        var seeds: [UInt8] = []
        for index in chains.chains.indices {
            let cursor = Int(hypothesis.cursors[index])
            guard cursor < chains.chains[index].count, let event = chains.chains[index][cursor].event else { continue }
            for letter in candidates(for: event, layout: layout, costs: costs) where !seeds.contains(letter) {
                seeds.append(letter)
                if seeds.count == 4 { break }
            }
            if seeds.count == 4 { break }
        }
        let pending = pendingLetters(hypothesis, chains: chains)
        return seeds.compactMap { letter in
            guard !pending.contains(letter) else { return nil }
            var letters = hypothesis.letters
            letters.append(letter)
            guard prefixExists(letters, lexicon: lexicon, personal: personal) else { return nil }
            var score = hypothesis.score - omissionCost(of: letter, costs: costs)
            if hypothesis.placed, let previous = hypothesis.letters.last {
                score += costs.bigramWeight * bigram.logProbability(from: previous, to: letter)
            }
            return Hypothesis(
                letters: letters,
                score: score,
                skips: hypothesis.skips,
                lastX: hypothesis.lastX,
                lastY: hypothesis.lastY,
                placed: true,
                lastStroke: hypothesis.lastStroke,
                cursors: hypothesis.cursors,
                omitted: true,
                debtChain: hypothesis.debtChain,
                debtIndex: hypothesis.debtIndex,
                justSkipped: false
            )
        }
    }

    /// A vowel is the cheaper omission. Both stay above the exact-lead window.
    private static func omissionCost(of letter: UInt8, costs: AlignmentCosts) -> Double {
        switch letter {
        case UInt8(ascii: "a"), UInt8(ascii: "e"), UInt8(ascii: "i"), UInt8(ascii: "o"), UInt8(ascii: "u"):
            return costs.omissionCost
        default:
            return costs.omissionCost + 0.25
        }
    }

    /// The earliest tap that this hypothesis has not consumed yet.
    private static func pendingTapTime(_ hypothesis: Hypothesis, chains: ThumbChains) -> Double? {
        var earliest: Double?
        for index in chains.chains.indices {
            let cursor = Int(hypothesis.cursors[index])
            guard cursor < chains.chains[index].count, chains.chains[index][cursor].event?.isTap == true else { continue }
            let time = chains.chains[index][cursor].time
            if earliest == nil || time < earliest! { earliest = time }
        }
        return earliest
    }

    /// Letters a still-pending event is already going to type. An omission is a letter
    /// the finger missed, so it cannot be one of these.
    private static func pendingLetters(_ hypothesis: Hypothesis, chains: ThumbChains) -> Set<UInt8> {
        var pending = Set<UInt8>()
        for index in chains.chains.indices {
            let cursor = Int(hypothesis.cursors[index])
            guard cursor < chains.chains[index].count else { continue }
            for step in chains.chains[index][cursor...] {
                guard let letter = step.event?.letter.lowercased().utf8.first,
                      (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(letter) else { continue }
                pending.insert(letter)
            }
        }
        return pending
    }

    private static func earliestTime(_ hypothesis: Hypothesis, chains: ThumbChains) -> Double {
        var earliest = Double.greatestFiniteMagnitude
        for index in chains.chains.indices {
            let cursor = Int(hypothesis.cursors[index])
            guard cursor < chains.chains[index].count else { continue }
            earliest = min(earliest, chains.chains[index][cursor].time)
        }
        return earliest == .greatestFiniteMagnitude ? 0 : earliest
    }

    private static func inversionCost(
        of time: Double,
        after earliest: Double,
        costs: AlignmentCosts,
        held: Bool
    ) -> Double {
        let gap = time - earliest
        guard gap > 0.000_1 else { return 0 }
        let cost = min(costs.inversionCap, costs.inversionRate * gap)
        return held ? cost * costs.heldOrderDiscount : cost
    }

    /// The other thumb's events bracket `time`, so that finger was down while this one landed.
    private static func otherThumbCovers(_ time: Double, besides index: Int, chains: ThumbChains) -> Bool {
        for other in chains.chains.indices where other != index {
            let times = chains.chains[other].map(\.time)
            guard let first = times.min(), let last = times.max() else { continue }
            if first <= time + 0.000_1, last >= time - 0.000_1, last - first > 0.000_1 {
                return true
            }
        }
        return false
    }

    private static func accepts(fit: Double, costs: AlignmentCosts) -> Bool {
        guard fit < 0 else { return false }
        if costs.keepWeakFits { return true }
        return fit > StrokeFit.miss
    }

    private static func skip(
        _ hypothesis: Hypothesis,
        event: SwipeEvent,
        layout: LetterLayout,
        costs: AlignmentCosts,
        crossingScale: Double
    ) -> Hypothesis? {
        switch event.role {
        case .anchor, .tap, .pin:
            if event.role == .pin, !costs.allowsEdits { return nil }
            guard hypothesis.placed, hypothesis.skips.allows(event.strokeIndex, limit: costs.maxAnchorSkips) else { return nil }
            var skipped = hypothesis
            skipped.skips = hypothesis.skips.adding(event.strokeIndex)
            skipped.score -= costs.anchorSkip
            skipped.justSkipped = true
            return skipped
        case .rest:
            var skipped = hypothesis
            skipped.score -= costs.restSkip
            skipped.justSkipped = true
            return skipped
        case .slip:
            var skipped = hypothesis
            skipped.score -= costs.slipSkip
            skipped.justSkipped = true
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

    /// Distance from the finger to the key, in key widths. A moving finger is forgiven
    /// along its travel and held to the key across it. A fixture with no speed stays round.
    private static func spatialCost(_ event: SwipeEvent, letter: UInt8, layout: LetterLayout, costs: AlignmentCosts) -> Double {
        let center = layout.center(of: letter)
        let dx = (event.point.x - center.x) / layout.keyWidth
        let dy = (event.point.y - center.y) / layout.keyHeight
        let dirX = event.directionX / layout.keyWidth
        let dirY = event.directionY / layout.keyHeight
        let dirLength = hypot(dirX, dirY)
        // A fast flick is sloppy along its travel. A normal trace stays round, so a close
        // spelling is not reshuffled by a modest change in speed.
        let stretch = event.speed >= 750 ? 1 + min((event.speed - 750) / 900, 0.8) : 1
        guard stretch > 1.01, dirLength > 0.01 else {
            let sigmaX = Double(costs.sigmaX)
            let sigmaY = Double(costs.sigmaY)
            return 0.5 * (Double(dx * dx) / (sigmaX * sigmaX) + Double(dy * dy) / (sigmaY * sigmaY))
        }
        let ux = dirX / dirLength
        let uy = dirY / dirLength
        let along = Double(dx) * Double(ux) + Double(dy) * Double(uy)
        let across = Double(dx) * Double(-uy) + Double(dy) * Double(ux)
        let sigmaAlong = Double(costs.sigmaX) * Double(stretch)
        let sigmaAcross = Double(costs.sigmaY)
        return 0.5 * (along * along / (sigmaAlong * sigmaAlong) + across * across / (sigmaAcross * sigmaAcross))
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

    /// A skip is several points worse than taking the key, so a full beam drops it.
    /// The few best skips stay anyway. That is how "cat" survives the keys around it.
    private static func keepingSkips(
        in produced: [Hypothesis],
        pruned: [Hypothesis],
        lexicon: MappedLexicon,
        costs: AlignmentCosts,
        habitBuckets: [[HabitKey]]
    ) -> [Hypothesis] {
        var kept = pruned
        let rescued = produced.filter(\.justSkipped).sorted { lhs, rhs in
            survival(lhs, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
                > survival(rhs, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
        }.prefix(6)
        for item in rescued {
            let already = kept.contains { $0.letters == item.letters && $0.cursors == item.cursors && $0.debtIndex == item.debtIndex }
            if !already { kept.append(item) }
        }
        return kept
    }

    /// Keeps the best spatial score for each prefix, then the widest beam.
    /// The two-letter frequency prior only decides who survives. It is not stored on the
    /// hypothesis, so the final word frequency is added once, in `consider`.
    private static func prune(
        _ hypotheses: [Hypothesis],
        width: Int,
        lexicon: MappedLexicon,
        costs: AlignmentCosts,
        habitBuckets: [[HabitKey]]
    ) -> [Hypothesis] {
        var grouped: [String: [Hypothesis]] = [:]
        grouped.reserveCapacity(hypotheses.count)
        for hypothesis in hypotheses {
            let letters = String(decoding: hypothesis.letters, as: UTF8.self)
            var group = grouped[letters] ?? []
            if let index = group.firstIndex(where: { $0.cursors == hypothesis.cursors && $0.debtChain == hypothesis.debtChain && $0.debtIndex == hypothesis.debtIndex }) {
                if hypothesis.score > group[index].score { group[index] = hypothesis }
            } else if group.count < 2 {
                group.append(hypothesis)
            } else if let worst = group.indices.min(by: { group[$0].score < group[$1].score }),
                      hypothesis.score > group[worst].score {
                group[worst] = hypothesis
            }
            grouped[letters] = group
        }
        return grouped.values.flatMap { $0 }.sorted { lhs, rhs in
            survival(lhs, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
                > survival(rhs, lexicon: lexicon, costs: costs, habitBuckets: habitBuckets)
        }.prefix(width).map { $0 }
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
        for reading in readings {
            let key = LexiconKey.make(reading.word)
            var score = reading.score
            let fit = StrokeFit.score(key, gesture: gesture, layout: layout, pathScore: &pathScore)
            score += fit
            // A miss already says the curve does not explain the word. Length is not a second bill.
            if fit > StrokeFit.miss {
                score -= PathScore.lengthCost(gestureLength: totalLength, key: key, layout: layout, weight: costs.lengthWeight)
            }
            adjusted.append(DecodeResult.Reading(word: reading.word, score: score))
        }
        adjusted.sort { $0.score > $1.score }
        return adjusted
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
        return pathScore.measure(key, mustExceed: -.infinity, gateLength: false, layout: layout, warp: true).location
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
            let fit = StrokeFit.score(letters, gesture: gesture, layout: layout, pathScore: &pathScore)
            guard accepts(fit: fit, costs: costs) else { continue }
            let score = fit + costs.frequencyWeight * known.logCount + habitBonus(known.display, habits: habits)
            best[key] = DecodeResult.Reading(word: known.display, score: score)
        }
        return best.values.sorted { $0.score > $1.score }
    }

    // MARK: - Shape nominations

    /// How many curve matches from each thumb may be joined into a two-stroke word.
    private static let shapePieceLimit = 3

    /// Words the curve found. A word already on the list keeps the beam's score, unless this
    /// one stroke sits clearly closer to that word than to the leader. Then it leads, far
    /// enough that an aligned graze cannot take the place back. Any other one-stroke curve
    /// stays just outside the tie margin. A tap holds its letter.
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
        let tapped = gesture.evidence.events.contains(where: \.isTap)
        let cap = readings.map(\.score).max().map { $0 - DecodeResult.confidenceMargin - 0.01 }
        let leaderLocation: CGFloat? = {
            guard paths.count == 1, !tapped, let path = paths.first,
                  let leader = readings.max(by: { $0.score < $1.score }) else { return nil }
            return location(of: leader.word, path: path, layout: layout, pathScore: &pathScore)
        }()
        let leaderScore = readings.map(\.score).max()
        var best: [String: DecodeResult.Reading] = [:]
        for reading in readings {
            best[reading.word.lowercased()] = reading
        }
        for reading in extra {
            let key = reading.word.lowercased()
            let clearlyCloser = !tapped && paths.count == 1 && paths.first.map { path in
                isClearlyCloser(reading.word, than: leaderLocation, path: path, layout: layout, pathScore: &pathScore)
            } == true
            let habit = habitBonus(reading.word, habits: habits)
            if let existing = best[key] {
                if clearlyCloser, let leaderScore {
                    let raised = leaderScore + ReadingPolicy.exactLead + 0.01 + habit
                    if raised > existing.score {
                        best[key] = DecodeResult.Reading(word: existing.word, score: raised)
                    }
                }
                continue
            }
            // The cap keeps an ordinary curve just outside the tie. The habit is a preference
            // on top of that, so a repeated shape still moves and the cap cannot erase it.
            var score = reading.score
            if clearlyCloser, let leaderScore {
                score = max(score, leaderScore + ReadingPolicy.exactLead + 0.01)
            } else if let cap {
                score = min(score, cap)
            }
            score += habit
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
        guard let shape = location(of: word, path: path, layout: layout, pathScore: &pathScore) else { return false }
        guard let leader else { return shape < 0.55 }
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
        let fit = StrokeFit.score(LexiconKey.make(known.display), gesture: gesture, layout: layout, pathScore: &pathScore)
        guard accepts(fit: fit, costs: costs) else { return }
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
    /// join never spells. The shared thumb fit only ranks the short list. Each survivor is then
    /// scored on its own letters. An anagram is held under a beam word only when that word
    /// itself sits on both thumbs.
    private static func mergedNominations(
        _ readings: [DecodeResult.Reading],
        gesture: SwipeGesture,
        layout: LetterLayout,
        lexicon: MappedLexicon,
        personal: [PersonalLexicon.Entry],
        costs: AlignmentCosts,
        pathScore: inout PathScore
    ) -> [DecodeResult.Reading] {
        let thumbs = StrokeFit.thumbs(in: gesture)
        guard thumbs.count == 2 else { return [] }
        let left = thumbs[0].letters
        let right = thumbs[1].letters
        guard let leftFirst = left.first, let leftLast = left.last,
              let rightFirst = right.first, let rightLast = right.last else { return [] }
        let maxLength = left.count + right.count + 2
        let fit = StrokeFit.anchorsFit(thumbs, layout: layout, pathScore: &pathScore)
        guard accepts(fit: fit, costs: costs) else { return [] }
        let ceiling = beamCeiling(readings, left: left, right: right, gesture: gesture, layout: layout, pathScore: &pathScore)

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
            let shaped = StrokeFit.score(LexiconKey.make(best[index].word), gesture: gesture, layout: layout, pathScore: &pathScore)
            guard accepts(fit: shaped, costs: costs) else { continue }
            var score = shaped + costs.frequencyWeight * best[index].logCount - costs.lengthWeight * Double(best[index].spare)
            if let ceiling { score = min(score, ceiling - 0.01) }
            best[index].score = score
        }
        best.sort { $0.score > $1.score }
        return best.map { DecodeResult.Reading(word: $0.word, score: $0.score) }
    }

    /// The best beam score among words that contain both thumbs and actually sit on their paths.
    private static func beamCeiling(
        _ readings: [DecodeResult.Reading],
        left: [UInt8],
        right: [UInt8],
        gesture: SwipeGesture,
        layout: LetterLayout,
        pathScore: inout PathScore
    ) -> Double? {
        var ceiling: Double?
        for reading in readings {
            let key = LexiconKey.make(reading.word)
            let covers = key.withUnsafeBytes { raw in
                isSubsequence(left, of: raw) && isSubsequence(right, of: raw)
            }
            guard covers else { continue }
            let fit = StrokeFit.score(key, gesture: gesture, layout: layout, pathScore: &pathScore)
            guard fit < 0, fit > StrokeFit.miss else { continue }
            if ceiling == nil || reading.score > ceiling! { ceiling = reading.score }
        }
        return ceiling
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

    static func apply(
        _ result: DecodeResult,
        aimed: String,
        habits: [String: Double] = [:],
        limit: Int = 4
    ) -> DecodeResult {
        let letters = BeatChooser.collapse(aimed)
        var readings = result.readings
        // The window is the path and the word frequency. A habit sits on top of that score,
        // so it can lift a rival in the list without spending the margin that protects the
        // keys the finger actually hit.
        func standing(_ reading: DecodeResult.Reading) -> Double {
            reading.score - (habits[reading.word.lowercased()] ?? 0)
        }
        let aligned = readings.filter { WordJoiner.aligns($0.word, traced: letters) }
        if let bestAligned = aligned.map(standing).max(),
           let overall = readings.map(standing).max(),
           let chosen = aligned
            .filter({ standing($0) + exactLead >= bestAligned && standing($0) + exactLead >= overall })
            .max(by: { lhs, rhs in
                let left = lhs.word.filter(\.isLetter).count
                let right = rhs.word.filter(\.isLetter).count
                if left != right { return left < right }
                return standing(lhs) < standing(rhs)
            }) {
            readings.removeAll { $0.word.lowercased() == chosen.word.lowercased() }
            readings.insert(chosen, at: 0)
        }
        if readings.count > limit {
            // The bar shows `limit` words. A reading within one exact-lead of the last slot
            // stays in the result, so a legal per-thumb skip is not dropped behind neighbors
            // that merely sat closer. Anything further is cut.
            let floor = readings[limit - 1].score - (exactLead + 0.15)
            var kept = Array(readings.prefix(limit))
            for extra in readings.dropFirst(limit) where extra.score >= floor {
                kept.append(extra)
            }
            readings = kept
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
        habits: [String: Double] = [:],
        clock: SearchClock? = nil
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
            clock: clock,
            pathScore: &pathScore
        )
    }
}

private extension SwipeEvent {
    var directionLength: CGFloat { hypot(directionX, directionY) }
}
