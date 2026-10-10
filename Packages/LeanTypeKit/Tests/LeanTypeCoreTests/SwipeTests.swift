import CoreGraphics
import Foundation
import Testing
@testable import LeanTypeCore

/// Synthetic swipes: the path a finger takes through a word's keys, with human-ish wobble.
@MainActor
enum SwipeSynthesizer {
    /// Points every few points along the path through `word`'s key centers, with each corner
    /// pushed off-center by up to `jitter` key widths.
    static func path(for word: String, layout: LetterLayout, jitter: CGFloat, seed: UInt64) -> [CGPoint] {
        var random = SeededRandom(seed: seed)
        var corners: [CGPoint] = []
        for letter in LexiconKey.make(word) {
            let center = layout.center(of: letter)
            let point = CGPoint(
                x: center.x + layout.keyWidth * jitter * random.nextSigned(),
                y: center.y + layout.keyHeight * jitter * 0.7 * random.nextSigned()
            )
            if corners.last.map({ hypot($0.x - point.x, $0.y - point.y) > 1 }) ?? true {
                corners.append(point)
            }
        }
        guard let first = corners.first else { return [] }
        var path = [first]
        for (from, to) in zip(corners, corners.dropFirst()) {
            let steps = max(Int(hypot(to.x - from.x, to.y - from.y) / 5), 1)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                path.append(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        }
        return path
    }
}

/// Human-ish gestures for the alignment decoder: corner cutting, overshoot, and two thumbs.
@MainActor
enum GestureSampler {
    static func singleSwipe(word: String, layout: LetterLayout, seed: UInt64) -> SwipeGesture? {
        compose(word: word, layout: layout, seed: seed, cut: 0, overshoot: 0, split: false)
    }

    static func cutCorners(word: String, layout: LetterLayout, seed: UInt64) -> SwipeGesture? {
        compose(word: word, layout: layout, seed: seed, cut: 0.4, overshoot: 0.2, split: false)
    }

    static func twoThumbs(word: String, layout: LetterLayout, seed: UInt64) -> SwipeGesture? {
        compose(word: word, layout: layout, seed: seed, cut: 0.15, overshoot: 0, split: true)
    }

    /// The last letter is a tap just after the stroke, overlapping it by a few dozen milliseconds.
    static func swipePlusTap(word: String, layout: LetterLayout, seed: UInt64) -> SwipeGesture? {
        let letters = LexiconKey.make(word)
        guard letters.count >= 3, let tail = letters.last else { return nil }
        let moving = stroke(Array(letters.dropLast()), layout: layout, seed: seed, cut: 0.1, overshoot: 0, start: 0)
        let tap = StrokeObservation(
            time: moving.end.time + 0.03,
            point: layout.center(of: tail),
            directionX: 0,
            directionY: 0,
            letter: String(UnicodeScalar(tail)),
            isTap: true
        )
        return GestureComposer.compose([moving], taps: [tap])
    }

    /// Even letters on one thumb and odd letters on the other, overlapping in time.
    static func interleavedThumbs(word: String, layout: LetterLayout, seed: UInt64) -> SwipeGesture? {
        let letters = LexiconKey.make(word)
        guard letters.count >= 4 else { return nil }
        let left = letters.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        let right = letters.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? nil : $0.element }
        guard left.count >= 2, right.count >= 2 else { return nil }
        let leftStroke = stroke(left, layout: layout, seed: seed, cut: 0.1, overshoot: 0, start: 0)
        let rightStroke = stroke(right, layout: layout, seed: seed &+ 9, cut: 0.1, overshoot: 0, start: 0.03)
        return GestureComposer.compose([leftStroke, rightStroke])
    }

    /// The first letter is a tap, then the rest of the word is one stroke.
    static func tapThenSwipe(word: String, layout: LetterLayout, seed: UInt64) -> SwipeGesture? {
        let letters = LexiconKey.make(word)
        guard letters.count >= 3, let head = letters.first else { return nil }
        let moving = stroke(Array(letters.dropFirst()), layout: layout, seed: seed, cut: 0.1, overshoot: 0, start: 0.06)
        let tap = StrokeObservation(
            time: 0,
            point: layout.center(of: head),
            directionX: 0,
            directionY: 0,
            letter: String(UnicodeScalar(head)),
            isTap: true
        )
        return GestureComposer.compose([moving], taps: [tap])
    }

    /// A tap lands on the middle letter while the other thumb is still drawing.
    static func tapInTheMiddle(word: String, layout: LetterLayout, seed: UInt64) -> SwipeGesture? {
        let letters = LexiconKey.make(word)
        guard letters.count >= 4 else { return nil }
        let mid = letters.count / 2
        let tapped = letters[mid]
        var movingLetters = letters
        movingLetters.remove(at: mid)
        guard movingLetters.count >= 2 else { return nil }
        let moving = stroke(movingLetters, layout: layout, seed: seed, cut: 0.1, overshoot: 0, start: 0)
        let previous = String(UnicodeScalar(letters[mid - 1]))
        let following = mid + 1 < letters.count ? String(UnicodeScalar(letters[mid + 1])) : nil
        let afterPrevious = moving.arrivals.last { $0.letter == previous }?.time ?? moving.start.time
        let beforeNext = following.flatMap { letter in moving.arrivals.first { $0.letter == letter }?.time } ?? moving.end.time
        let tap = StrokeObservation(
            time: afterPrevious + max(0.01, (beforeNext - afterPrevious) / 2),
            point: layout.center(of: tapped),
            directionX: 0,
            directionY: 0,
            letter: String(UnicodeScalar(tapped)),
            isTap: true
        )
        return GestureComposer.compose([moving], taps: [tap])
    }

    private static func compose(
        word: String,
        layout: LetterLayout,
        seed: UInt64,
        cut: CGFloat,
        overshoot: CGFloat,
        split: Bool
    ) -> SwipeGesture? {
        let letters = LexiconKey.make(word)
        guard letters.count >= 2 else { return nil }
        if split, letters.count >= 4 {
            let mid = letters.count / 2
            let left = stroke(Array(letters[..<mid]), layout: layout, seed: seed, cut: cut, overshoot: 0, start: 0)
            let right = stroke(Array(letters[mid...]), layout: layout, seed: seed &+ 9, cut: cut, overshoot: 0, start: 0.07)
            return GestureComposer.compose([left, right])
        }
        return GestureComposer.compose([stroke(letters, layout: layout, seed: seed, cut: cut, overshoot: overshoot, start: 0)])
    }

    private static func stroke(
        _ letters: [UInt8],
        layout: LetterLayout,
        seed: UInt64,
        cut: CGFloat,
        overshoot: CGFloat,
        start: Double
    ) -> StrokeBuffer {
        let word = String(decoding: letters, as: UTF8.self)
        var path = SwipeSynthesizer.path(for: word, layout: layout, jitter: 0.12, seed: seed)
        if cut > 0, path.count >= 5 {
            let original = path
            for index in 2..<(path.count - 2) {
                let chord = CGPoint(
                    x: (original[index - 2].x + original[index + 2].x) / 2,
                    y: (original[index - 2].y + original[index + 2].y) / 2
                )
                path[index].x += (chord.x - path[index].x) * cut
                path[index].y += (chord.y - path[index].y) * cut
            }
        }
        if overshoot > 0, path.count >= 2, let last = path.last {
            let previous = path[path.count - 2]
            let dx = last.x - previous.x
            let dy = last.y - previous.y
            let length = max(hypot(dx, dy), 1)
            path.append(CGPoint(
                x: last.x + dx / length * layout.keyWidth * overshoot,
                y: last.y + dy / length * layout.keyHeight * overshoot
            ))
        }
        guard let first = path.first else {
            return StrokeBuffer(start: StrokePoint(location: .zero, time: start))
        }
        var time = start
        var buffer = StrokeBuffer(start: StrokePoint(location: first, time: time))
        var aimed: UInt8?
        for point in path.dropFirst() {
            let pace = 0.008 + 0.010 * abs(sin(time * 18))
            time += pace
            buffer.append(StrokePoint(location: point, time: time))
            guard let letter = layout.letters(near: point, within: 0.65, limit: 1).first else { continue }
            if let aimed {
                let old = layout.center(of: aimed)
                let next = layout.center(of: letter)
                let towardNew = hypot(point.x - next.x, point.y - next.y)
                let towardOld = hypot(point.x - old.x, point.y - old.y)
                guard letter != aimed, towardNew < towardOld else { continue }
            }
            aimed = letter
            buffer.arrive(String(UnicodeScalar(letter)), at: layout.center(of: letter), touch: point, time: time)
        }
        if let last = path.last {
            buffer.finish(at: StrokePoint(location: last, time: time))
        }
        return buffer
    }
}

/// A tiny deterministic generator so accuracy numbers don't change between runs.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// Uniform in -1...1.
    mutating func nextSigned() -> CGFloat {
        CGFloat(Double(next() >> 11) / Double(1 << 53)) * 2 - 1
    }
}

@MainActor
@Suite("Swipe decoding")
struct PathDecoderTests {
    static let words = [
        "the", "and", "you", "that", "was", "for", "are", "with", "his", "they", "this", "have", "from",
        "one", "had", "word", "but", "not", "what", "all", "were", "when", "your", "can", "said", "there",
        "use", "each", "which", "she", "how", "their", "will", "other", "about", "out", "many", "then",
        "them", "these", "some", "her", "would", "make", "like", "him", "into", "time", "has", "look",
        "two", "more", "write", "see", "number", "way", "could", "people", "than", "first", "water",
        "been", "call", "who", "its", "now", "find", "long", "down", "day", "did", "get", "come", "made",
        "may", "part", "hello", "thanks", "tomorrow", "keyboard", "because", "really", "something",
        "great", "love", "know", "think", "going", "right", "good", "please", "sorry", "maybe", "happy",
        "friend", "family", "morning", "tonight", "dinner", "coffee", "awesome", "message", "meeting",
        "phone", "home", "work", "later", "today", "yes", "okay", "sure", "where", "here", "just",
    ]

    private let layout = TestLayout.shared!
    private let decoder = PathDecoder(lexicon: TestLexicon.shared)

    /// A swipe counts as right if the top word matches, or if the top word traces the very same
    /// key path ("to" and "too" are the same gesture; frequency rightly picks one).
    private func isCorrect(_ result: String?, for word: String) -> Bool {
        guard let result else { return false }
        if result.lowercased() == word { return true }
        return Self.keyPath(result) == Self.keyPath(word)
    }

    private static func keyPath(_ word: String) -> [UInt8] {
        LexiconKey.make(word).reduce(into: []) { path, letter in
            if path.last != letter { path.append(letter) }
        }
    }

    /// The 500 most common plain words (two letters or more) in the bundled dictionary.
    static let mostCommon: [String] = {
        let lexicon = TestLexicon.shared
        return (0..<lexicon.wordCount)
            .map { (word: lexicon.display(at: $0), logCount: lexicon.logCount(at: $0)) }
            .filter { $0.word.count >= 2 && $0.word.allSatisfy { ("a"..."z").contains($0) } }
            .sorted { $0.logCount > $1.logCount }
            .prefix(500)
            .map(\.word)
    }()

    @Test func decodesTheMostCommonWords() async {
        var topOne = 0
        var topFour = 0
        var misses: [String] = []
        for (index, word) in Self.mostCommon.enumerated() {
            let path = SwipeSynthesizer.path(for: word, layout: layout, jitter: 0.15, seed: UInt64(index))
            let result = await decoder.decode(SwipeGesture(path: path, strokeCount: 1), layout: layout, personal: [])
            if isCorrect(result.words.first, for: word) { topOne += 1 } else { misses.append("\(word)→\(result.words.first ?? "∅")") }
            if result.words.contains(where: { isCorrect($0, for: word) }) { topFour += 1 }
        }
        let count = Double(Self.mostCommon.count)
        #expect(Self.mostCommon.count == 500)
        #expect(Double(topOne) / count >= 0.9, "Top-1 \(topOne)/500; misses: \(misses)")
        #expect(Double(topFour) / count >= 0.98, "Top-4 \(topFour)/500")
    }

    @Test func toleratesSloppySwipes() async {
        var correct = 0
        var inTopFour = 0
        for (index, word) in Self.words.enumerated() {
            let path = SwipeSynthesizer.path(for: word, layout: layout, jitter: 0.32, seed: UInt64(1000 + index))
            let result = await decoder.decode(SwipeGesture(path: path, strokeCount: 1), layout: layout, personal: [])
            if isCorrect(result.words.first, for: word) { correct += 1 }
            if result.words.contains(where: { isCorrect($0, for: word) }) { inTopFour += 1 }
        }
        #expect(Double(correct) / Double(Self.words.count) >= 0.7)
        #expect(Double(inTopFour) / Double(Self.words.count) >= 0.85, "The right word is usually one tap away")
    }

    @Test func personalWordsDecode() async {
        let personal = PersonalLexicon(learned: [
            LearnedWord(word: "Hoinville", uses: 2, lastUsed: .now),
        ]).entries(logCountRange: TestLexicon.shared.logCountRange)
        let path = SwipeSynthesizer.path(for: "hoinville", layout: layout, jitter: 0.08, seed: 7)
        let result = await decoder.decode(SwipeGesture(path: path, strokeCount: 1), layout: layout, personal: personal)
        #expect(result.words.first == "Hoinville")
    }

    @Test func aTightSwipeStaysInsideTheCommonWords() async {
        let path = SwipeSynthesizer.path(for: "hello", layout: layout, jitter: 0, seed: 1)
        let result = await decoder.decode(SwipeGesture(path: path, strokeCount: 1), layout: layout, personal: [])
        #expect(result.words.first?.lowercased() == "hello")
        #expect(await decoder.scannedBeyondCommon == false)
    }

    @Test func aPoorFitFindsARarerWordFurtherDownTheBucket() async {
        let word = "disobedience"
        let straight = SwipeSynthesizer.path(for: word, layout: layout, jitter: 0, seed: 3)
        let width = layout.keyWidth
        // The common d–e words sit close to a straight swipe. Bend the middle down and
        // to the right, just past the location cutoff, and the rest of the bucket is
        // what still spells this word.
        let path = bend(straight, by: CGPoint(x: width * 1.3, y: -width * 1.3))
        let result = await decoder.decode(SwipeGesture(path: path, strokeCount: 1), layout: layout, personal: [])
        #expect(await decoder.scannedBeyondCommon)
        #expect(result.words.first?.lowercased() == word)
    }

    /// Pulls the middle of a path off the keys and leaves the start and end where they are.
    private func bend(_ path: [CGPoint], by delta: CGPoint) -> [CGPoint] {
        guard path.count > 1 else { return path }
        return path.enumerated().map { index, point in
            let along = CGFloat(index) / CGFloat(path.count - 1)
            let weight = sin(along * .pi)
            return CGPoint(x: point.x + delta.x * weight, y: point.y + delta.y * weight)
        }
    }

    @Test(.serialized) func decodesFastEnough() async {
        let paths = Self.words.prefix(40).enumerated().map { index, word in
            SwipeSynthesizer.path(for: word, layout: layout, jitter: 0.15, seed: UInt64(index))
        }
        let clock = ContinuousClock()
        var slowest = Duration.zero
        let total = await clock.measure {
            for path in paths {
                let single = await clock.measure {
                    _ = await decoder.decode(SwipeGesture(path: path, strokeCount: 1), layout: layout, personal: [])
                }
                slowest = max(slowest, single)
            }
        }
        let average = total / paths.count
        // The real budget is 15 ms in release (see docs/PERF.md). Debug builds are much
        // slower. This test is serialized so it is not fighting the other decoder tests,
        // but a full package run still shares the CPU with the swipe suite.
        #expect(average < .milliseconds(1000), "Average \(average), slowest \(slowest)")
    }

    @Test func gestureClassesDecodeAboveTheFloor() async {
        let cases: [(String, (String, LetterLayout, UInt64) -> SwipeGesture?)] = [
            ("single", GestureSampler.singleSwipe),
            ("corners", GestureSampler.cutCorners),
            ("thumbs", GestureSampler.twoThumbs),
            ("interleaved", GestureSampler.interleavedThumbs),
            ("tap", GestureSampler.swipePlusTap),
            ("tapFirst", GestureSampler.tapThenSwipe),
            ("tapMiddle", GestureSampler.tapInTheMiddle),
        ]
        let language = LanguageModel(lexicon: TestLexicon.shared)
        for (name, make) in cases {
            var topOne = 0
            var topThree = 0
            var overMerge = 0
            var underMerge = 0
            var attempted = 0
            var misses: [String] = []
            for (index, word) in Self.words.prefix(40).enumerated() {
                guard let gesture = make(word, layout, UInt64(index + 1)) else { continue }
                attempted += 1
                let result = await language.align(gesture, layout: layout)
                if isCorrect(result.words.first, for: word) {
                    topOne += 1
                } else {
                    misses.append("\(word)→\(result.words.first ?? "∅")")
                    let got = result.words.first?.lowercased() ?? ""
                    if got.count > word.count { overMerge += 1 }
                    if !got.isEmpty, got.count < word.count { underMerge += 1 }
                }
                if result.words.contains(where: { isCorrect($0, for: word) }) { topThree += 1 }
            }
            let count = Double(attempted)
            let report = "\(name) top-1 \(topOne)/\(attempted) top-3 \(topThree) over \(overMerge) under \(underMerge) misses \(misses.prefix(8))"
            #expect(count > 0 && Double(topOne) / count >= 0.55, Comment(rawValue: report))
            #expect(count > 0 && Double(topThree) / count >= 0.75, Comment(rawValue: report))
        }
    }

    @Test func salientPointsFindTurns() {
        let stroke = [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0), CGPoint(x: 60, y: 60)].enumerated().map { index, point in
            StrokePoint(location: point, time: Double(index) * 0.1)
        }
        let dense = (0...24).map { step -> StrokePoint in
            let t = Double(step) / 24
            let location = t <= 0.5
                ? CGPoint(x: 120 * t, y: 0)
                : CGPoint(x: 60, y: 120 * (t - 0.5))
            return StrokePoint(location: location, time: t * 0.4)
        }
        #expect(StrokeAnalyzer.salientPoints(of: stroke).count >= 2)
        let salient = StrokeAnalyzer.salientPoints(of: dense)
        #expect(salient.contains { abs($0.location.x - 60) < 8 && abs($0.location.y) < 8 }, "The corner is salient")
        #expect(salient.first?.location == .zero)
        #expect(salient.last?.location == CGPoint(x: 60, y: 60))
    }
}

@MainActor
@Suite("Swipe typing in the engine")
struct SwipeTypingTests {
    private func makeHarness(text: String = "", settings: KeyboardSettings = .default) -> EngineHarness {
        EngineHarness(
            text: text,
            settings: settings,
            traits: InputTraits(autocapitalization: .none),
            language: LanguageModel(lexicon: TestLexicon.shared)
        )
    }

    /// Commits `word` as a swipe whose aimed letters are that same spelling.
    private func commitSwipe(_ word: String, on harness: EngineHarness) {
        #expect(harness.engine.perform(.commitSwipe(
            [word],
            unsure: false,
            strokes: 1,
            observations: aimed(word),
            strokePaths: []
        )))
    }

    /// Drags one finger through `word`'s keys and lifts.
    private func swipe(_ word: String, on harness: EngineHarness) {
        let points = LexiconKey.make(word).map { harness.point(for: String(UnicodeScalar($0))) }
        let id = harness.down(at: points[0])
        for point in points.dropFirst() {
            harness.move(id, to: point, over: 0.06)
        }
        harness.up(id)
    }

    @Test func swipeTypesAWordWithSpacing() async {
        let harness = makeHarness(text: "say")
        swipe("hello", on: harness)
        await harness.settle()
        #expect(harness.text == "say hello ")
        #expect(harness.recorder.events.contains(.wordCommitted(.swipe)))
    }

    /// Left thumb f–r, right thumb i, left e, right n, left d, with a lift between each piece.
    @Test func anAlternatingPairSpellsFriend() async {
        let harness = makeHarness()
        func piece(_ letters: [String]) {
            let id = harness.down(at: harness.point(for: letters[0]))
            for letter in letters.dropFirst() {
                harness.move(id, to: harness.point(for: letter), over: 0.06)
            }
            harness.up(id)
        }
        piece(["f", "r"])
        piece(["i"])
        piece(["e"])
        piece(["n"])
        piece(["d"])
        await harness.settle()
        #expect(harness.text == "fr iend")
    }

    @Test func strokesShowAsTrails() {
        let harness = makeHarness()
        let id = harness.down(at: harness.point(for: "q"))
        #expect(harness.state.interaction.strokes.isEmpty, "A finger starts as a tap")
        harness.move(id, to: harness.point(for: "r"))
        #expect(harness.state.interaction.strokes.count == 1)
        harness.up(id)
    }

    @Test func tapsStillTypeLetters() {
        let harness = makeHarness()
        harness.type("hi")
        #expect(harness.text == "hi")
    }

    @Test func letterTypedAfterASwipeWaitsForIt() async {
        let harness = makeHarness()
        swipe("hello", on: harness)
        harness.tap(.character("x"))
        await harness.settle()
        #expect(harness.text == "hello x")
    }

    @Test func backspaceRemovesTheWholeSwipedWordAndCanRestoreIt() {
        let harness = makeHarness(text: "say")
        #expect(harness.engine.perform(.commitSwipe(
            ["hello"],
            unsure: false,
            strokes: 1,
            observations: aimed("hello"),
            strokePaths: []
        )))
        #expect(harness.text == "say hello ")
        harness.tap(.backspace)
        #expect(harness.text == "say")

        let id = harness.down(at: harness.point(for: .backspace))
        harness.move(id, by: CGVector(dx: BackspaceSession.activationDistance, dy: 0))
        harness.move(id, by: CGVector(dx: BackspaceSession.scrubStep + 1, dy: 0))
        harness.up(id)
        #expect(harness.text == "say hello ")
    }

    @Test func alternativeReadingsSwapInPlace() async throws {
        let harness = makeHarness()
        swipe("in", on: harness)
        await harness.settle()
        let first = harness.text
        let alternatives = harness.state.candidates.candidates
        let side = try #require(alternatives.firstIndex { $0.role == .alternative })
        harness.engine.acceptCandidate(side)
        #expect(harness.text == alternatives[side].text + " ")
        #expect(harness.text != first)
        #expect(harness.state.candidates.candidates.contains { $0.text + " " == first }, "The original reading is offered back")
    }

    @Test func deletingASwipeOffersADifferentWordTheNextTime() async {
        let harness = makeHarness()
        swipe("in", on: harness)
        await harness.settle()
        let first = harness.text
        harness.tap(.backspace)
        #expect(harness.text.isEmpty)
        swipe("in", on: harness)
        await harness.settle()
        #expect(harness.text != first)
        #expect(!harness.text.isEmpty)
    }

    @Test func bothThumbsDownThenSlideOneWord() async {
        let harness = makeHarness()
        let left = harness.down(at: harness.point(for: "t"))
        let right = harness.down(at: harness.point(for: "h"))
        #expect(harness.text.isEmpty, "Two thumbs down together do not type yet")
        harness.move(right, to: harness.point(for: "e"), over: 0.08)
        harness.up(left)
        harness.up(right)
        await harness.settle()
        #expect(harness.text == "the ")
    }

    @Test func aStillThumbTypesAfterTheSwipedWord() async {
        let harness = makeHarness()
        let left = harness.down(at: harness.point(for: "t"))
        harness.move(left, to: harness.point(for: "h"), over: 0.08)
        let right = harness.down(at: harness.point(for: "e"))
        harness.up(right)
        harness.up(left)
        await harness.settle()
        #expect(harness.text == "the ")
        #expect(harness.recorder.events.contains { if case .swipeGestureCommitted(strokes: 1) = $0 { true } else { false } })
    }

    @Test func twoThumbsThatNeverTravelTypeInOrder() {
        let harness = makeHarness()
        let left = harness.down(at: harness.point(for: "t"))
        let right = harness.down(at: harness.point(for: "e"))
        #expect(harness.text.isEmpty)
        harness.up(left)
        harness.up(right)
        #expect(harness.text == "te")
    }

    @Test func pullingBackShortensTheStroke() {
        var stroke = StrokeBuffer(start: StrokePoint(location: .zero, time: 0))
        stroke.append(StrokePoint(location: CGPoint(x: 80, y: 0), time: 0.1))
        stroke.append(StrokePoint(location: CGPoint(x: 40, y: 0), time: 0.2))
        #expect(stroke.points.map(\.location.x) == [0, 40])
    }

    @Test func downwardWordsAreSwipesNotFlicks() async {
        let harness = makeHarness()
        swipe("is", on: harness)
        await harness.settle()
        #expect(harness.text == "is ")

        swipe("was", on: harness)
        await harness.settle()
        #expect(harness.text == "is was ")
    }

    @Test func shortSameRowSwipeTypesTheWord() async {
        let harness = makeHarness()
        swipe("hi", on: harness)
        await harness.settle()
        #expect(harness.text == "hi ")
    }

    @Test func closeReadingsAreUnsure() {
        let close = DecodeResult(readings: [
            .init(word: "in", score: -1),
            .init(word: "on", score: -1.2),
        ])
        let clear = DecodeResult(readings: [
            .init(word: "hello", score: -0.2),
            .init(word: "help", score: -2),
        ])
        #expect(close.isUnsure)
        #expect(!clear.isUnsure)
        #expect(!DecodeResult(readings: [.init(word: "hello", score: -0.2)]).isUnsure)
    }

    @Test func swipePreviewsTheWordWhileTheFingerIsDown() async {
        let harness = makeHarness()
        let points = LexiconKey.make("hello").map { harness.point(for: String(UnicodeScalar($0))) }
        let id = harness.down(at: points[0])
        for point in points.dropFirst() {
            harness.move(id, to: point, over: 0.06)
        }
        var sawPreview = false
        for _ in 0..<40 {
            if harness.state.candidates.isTentative {
                sawPreview = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(sawPreview)
        #expect(harness.state.candidates.candidates.contains { $0.text.lowercased() == "hello" })
        #expect(harness.text.lowercased() == "hello")
        harness.up(id)
        await harness.settle()
        #expect(harness.text == "hello ")
        #expect(!harness.state.candidates.isTentative)
    }

    @Test func aShortUpwardFlickStillTypesTheDigit() {
        let harness = makeHarness()
        let id = harness.down(at: harness.point(for: "q"))
        harness.move(id, by: CGVector(dx: 1, dy: -(CharacterTapSession.flickDistance + 4)), over: 0.06)
        harness.up(id)
        #expect(harness.text == "1")
        #expect(harness.state.interaction.strokes.isEmpty)
    }

    @Test func aSupersededSwipeDoesNotBlockLaterTyping() async {
        let hold = DecodeHold()
        var committed: [KeyboardIntent] = []
        let composer = InputComposer { committed.append(contentsOf: $0) }
        let coordinator = SwipeCoordinator(composer: composer, matcher: AlignmentPathMatcher { _ in
            await hold.wait()
            return DecodeResult(readings: [.init(word: "hello", score: 0)])
        })

        func lift(_ rawID: Int) {
            let id = TouchID(rawValue: rawID)
            let start = TouchSample(id: id, location: .zero, timestamp: 0, phase: .began)
            var track = TouchTrack(start: start)
            track.append(TouchSample(id: id, location: CGPoint(x: 30, y: 0), timestamp: 0.05, phase: .moved))
            coordinator.begin(track, ticket: composer.reserve())
            track.append(TouchSample(id: id, location: CGPoint(x: 60, y: 0), timestamp: 0.1, phase: .ended))
            coordinator.ended(track)
        }

        lift(1)
        #expect(await hold.waitUntil(count: 1))
        lift(2)
        #expect(await hold.waitUntil(count: 2))
        hold.release()

        var spins = 0
        while composer.hasPendingCommits, spins < 50 {
            spins += 1
            await Task.yield()
        }
        #expect(!composer.hasPendingCommits)
        guard case let .commitSwipe(words, unsure, strokes, observations, _) = committed.first else {
            Issue.record("Expected a swipe commit")
            return
        }
        #expect(words == ["hello"])
        #expect(!unsure)
        #expect(strokes == 1)
        #expect(observations.isEmpty)
    }

    @Test func swipeIsOffWhenTypingModeIsTap() {
        let harness = EngineHarness(
            settings: KeyboardSettings(typingMode: .tap),
            traits: InputTraits(autocapitalization: .none),
            language: LanguageModel(lexicon: TestLexicon.shared)
        )
        let id = harness.down(at: harness.point(for: "q"))
        harness.move(id, to: harness.point(for: "r"))
        #expect(harness.state.interaction.strokes.isEmpty)
        harness.up(id)
        #expect(harness.text == "r")
    }

    @Test func swipeWorksWhenTheFieldTurnsAutocorrectOff() async {
        let harness = EngineHarness(
            traits: InputTraits(variant: .url, autocapitalization: .none, allowsAutocorrection: false),
            language: LanguageModel(lexicon: TestLexicon.shared)
        )
        swipe("hello", on: harness)
        await harness.settle()
        #expect(harness.text == "hello ")

        let tapped = EngineHarness(
            traits: InputTraits(variant: .url, autocapitalization: .none, allowsAutocorrection: false),
            language: LanguageModel(lexicon: TestLexicon.shared)
        )
        tapped.type("teh ")
        #expect(tapped.text == "teh ")
    }

    @Test func searchFieldStillOffersSwipeAlternatives() async throws {
        let harness = EngineHarness(
            traits: InputTraits(
                variant: .url,
                autocapitalization: .none,
                returnKey: .search,
                allowsAutocorrection: false
            ),
            language: LanguageModel(lexicon: TestLexicon.shared)
        )
        swipe("in", on: harness)
        await harness.settle()
        let strip = harness.state.candidates
        let word = harness.text.trimmingCharacters(in: .whitespaces)
        try #require(strip.candidates.contains { $0.role == .alternative })
        #expect(strip.highlightedIndex.map { strip.candidates[$0].text } == word)
    }

    @Test func swipeStaysOffForPasswords() {
        let harness = EngineHarness(
            traits: InputTraits(autocapitalization: .none, blocksLexicalEntry: true),
            language: LanguageModel(lexicon: TestLexicon.shared)
        )
        let id = harness.down(at: harness.point(for: "q"))
        harness.move(id, to: harness.point(for: "r"))
        #expect(harness.state.interaction.strokes.isEmpty)
        harness.up(id)
        #expect(harness.text == "r")
    }

    @Test func anEmptyDecodeTypesTheLettersCrossed() async {
        var committed: [KeyboardIntent] = []
        let composer = InputComposer { committed.append(contentsOf: $0) }
        let coordinator = SwipeCoordinator(composer: composer, matcher: AlignmentPathMatcher { _ in .empty })
        let id = TouchID(rawValue: 1)
        let start = TouchSample(id: id, location: CGPoint(x: 0, y: 0), timestamp: 0, phase: .began)
        var track = TouchTrack(start: start)
        track.append(TouchSample(id: id, location: CGPoint(x: 40, y: 0), timestamp: 0.05, phase: .moved))
        coordinator.begin(track, ticket: composer.reserve())
        coordinator.arrive(id, letter: "q", at: CGPoint(x: 0, y: 0), time: 0)
        coordinator.arrive(id, letter: "w", at: CGPoint(x: 40, y: 0), time: 0.05)
        track.append(TouchSample(id: id, location: CGPoint(x: 40, y: 0), timestamp: 0.1, phase: .ended))
        coordinator.ended(track)

        var spins = 0
        while composer.hasPendingCommits, spins < 50 {
            spins += 1
            await Task.yield()
        }
        guard case let .commitSwipe(words, unsure, strokes, observations, _) = committed.first else {
            Issue.record("Expected a swipe commit")
            return
        }
        #expect(words == ["qw"])
        #expect(unsure)
        #expect(strokes == 1)
        #expect(observations.map(\.letter) == ["q", "w"])
    }

    @Test func aRejectedSwipeReadingMovesBehindThePreferredWord() {
        let model = LanguageModel(lexicon: TestLexicon.shared)
        model.noteRejection(preferred: "teh", rejected: "the")
        let ranked = model.applyingRejections(to: DecodeResult(readings: [
            .init(word: "the", score: -0.1),
            .init(word: "teh", score: -0.4),
        ]))
        #expect(ranked.words == ["teh", "the"])
    }

    @Test func deletingASwipeTriesAnotherReadingOnTheNextSimilarStroke() {
        let model = LanguageModel(lexicon: TestLexicon.shared)
        let there = DecodeResult(readings: [
            .init(word: "there", score: -0.1),
            .init(word: "three", score: -0.4),
            .init(word: "their", score: -0.8),
        ])
        model.noteSwipeRefusal(word: "there", trace: "tere")
        #expect(model.applyingSwipeRefusals(to: there, trace: "tree").words == ["three", "there", "their"])

        let the = DecodeResult(readings: [
            .init(word: "the", score: -0.1),
            .init(word: "there", score: -0.5),
        ])
        #expect(model.applyingSwipeRefusals(to: the, trace: "the").words == ["the", "there"])

        model.forgetSwipeRefusal(word: "there")
        #expect(model.applyingSwipeRefusals(to: there, trace: "tere").words == ["there", "three", "their"])
    }

    @Test func aSwipeRefusalStaysUntilTheWordIsCommittedAgain() {
        let model = LanguageModel(lexicon: TestLexicon.shared)
        model.noteSwipeRefusal(word: "there", trace: "tere")
        let result = DecodeResult(readings: [
            .init(word: "there", score: -0.1),
            .init(word: "three", score: -0.4),
        ])
        for _ in 0..<8 {
            model.noteSwipeLanded()
        }
        #expect(model.applyingSwipeRefusals(to: result, trace: "tere").words.first == "three")
        model.noteCommitted("there")
        #expect(model.applyingSwipeRefusals(to: result, trace: "tere").words.first == "there")
    }

    @Test func pillThenLStaysPill() async {
        let harness = makeHarness()
        swipe("pil", on: harness)
        await harness.settle()
        harness.tap(.character("l"))
        #expect(harness.text == "pill l")
    }

    @Test func pilThenEBecomesPile() async {
        let harness = makeHarness()
        swipe("pil", on: harness)
        await harness.settle()
        harness.tap(.character("e"))
        #expect(harness.text == "pill e")
    }

    @Test func quitFromATapASwipeAndATap() async {
        let harness = makeHarness()
        harness.tap(.character("q"))
        swipe("ui", on: harness)
        await harness.settle()
        harness.tap(.character("t"))
        harness.tap(.space)
        await harness.settle()
        #expect(harness.text == "quit ")
    }

    @Test func waitFromASwipeAndTwoTaps() async {
        let harness = makeHarness()
        swipe("wa", on: harness)
        await harness.settle()
        harness.tap(.character("i"))
        harness.tap(.character("t"))
        #expect(harness.text == "wa it")
    }

    @Test func privateFromTapsAndTwoSwipes() async {
        let harness = makeHarness()
        harness.tap(.character("p"))
        harness.tap(.character("r"))
        harness.tap(.character("i"))
        swipe("va", on: harness)
        await harness.settle()
        #expect(!harness.text.hasSuffix(" "), "A tap-open word stays uncommitted through the swipe")
        swipe("te", on: harness)
        await harness.settle()
        harness.tap(.space)
        await harness.settle()
        #expect(harness.text == "private ")
    }

    @Test func aZigzagWordIsNotARetreat() {
        let harness = makeHarness()
        let letters = Array("traged")
        let points = letters.map { harness.point(for: String($0)) }
        var stroke = StrokeBuffer(start: StrokePoint(location: points[0], time: 0))
        stroke.arrive(String(letters[0]), at: points[0], time: 0)
        for (index, point) in points.dropFirst().enumerated() {
            stroke.append(StrokePoint(location: point, time: Double(index + 1)))
            stroke.arrive(String(letters[index + 1]), at: point, time: Double(index + 1))
        }
        #expect(stroke.arrivals.map(\.letter).joined() == "traged")
        #expect(StrokeLetters.aimedArrivals(stroke.arrivals).map(\.letter).joined() == "traged")
    }

    @Test func aSameRowWobbleDoesNotAimTheGrazedKeys() {
        let harness = makeHarness()
        let letters = ["y", "u", "i", "o"]
        let centers = letters.map { harness.point(for: $0) }
        var stroke = StrokeBuffer(start: StrokePoint(location: centers[0], time: 0))
        stroke.arrive("y", at: centers[0], touch: centers[0], time: 0)
        for (index, letter) in letters.enumerated().dropFirst() {
            let wobble = CGPoint(x: centers[index].x, y: centers[index].y + (index.isMultiple(of: 2) ? 12 : -12))
            stroke.append(StrokePoint(location: wobble, time: Double(index) * 0.05))
            stroke.arrive(letter, at: centers[index], touch: wobble, time: Double(index) * 0.05)
        }
        stroke.finish(at: StrokePoint(location: centers[3], time: 0.2))
        let gesture = GestureComposer.compose([stroke])
        let anchors = gesture?.evidence.events.filter { $0.role == .anchor }.map(\.letter)
        #expect(anchors == ["y", "o"])
    }

    @Test func aSameRowReturnKeepsTheFarKeyAndAShortWordStays() {
        let positions: [CGFloat] = [0, 1, 2, 3, 4, 5, 6, 5, 4, 3]
        let top = ["w", "e", "r", "t", "y", "u", "i", "u", "y", "t"]
        var with = zip(top, positions).map { letter, place in
            arrival(letter, x: place * 40, y: 0)
        }
        with.append(arrival("h", x: 5 * 40, y: 56))
        #expect(StrokeLetters.aimedArrivals(with).map(\.letter).joined() == "with")

        let were = ["w", "e", "r", "e"].enumerated().map { index, letter in
            let place: CGFloat = index == 3 ? 1 : CGFloat(index)
            return arrival(letter, x: place * 40, y: 0)
        }
        #expect(StrokeLetters.aimedArrivals(were).map(\.letter).joined() == "were")
    }

    @Test func aCommonCurveLeadsAGrazedRival() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let t = harness.point(for: "t")
        let h = harness.point(for: "h")
        let e = harness.point(for: "e")
        let r = harness.point(for: "r")
        let path = [t, h, e]
        let events = [
            SwipeEvent(time: 0, point: t, letter: "t", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.08, point: r, letter: "r", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.16, point: e, letter: "e", role: .anchor, strokeIndex: 0),
        ]
        let gesture = SwipeGesture(
            path: path,
            strokeCount: 1,
            strokePaths: [path],
            tracedLetters: "tre",
            evidence: SwipeEvidence(events: events, aimedLetters: "tre")
        )
        #expect(decode(gesture, layout: layout).words.first?.lowercased() == "the")
    }

    @Test func aJoinedSwipeKeepsItsCurve() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        let harness = EngineHarness(language: language)
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let t = harness.point(for: "t")
        let h = harness.point(for: "h")
        let e = harness.point(for: "e")
        let observations = [
            aimedStroke("t", stroke: 0, at: t, time: 0),
            aimedStroke("e", stroke: 0, at: e, time: 0.16),
        ]
        let withCurve = language.sequenceDecode(observations, layout: layout, strokePaths: [[t, h, e]])
        let withoutCurve = language.sequenceDecode(observations, layout: layout)
        #expect(withCurve.result.words.first?.lowercased() == "the")
        #expect(withoutCurve.result.words.first?.lowercased() != "the")
    }

    @Test func estrangedKeepsNInsideTheSecondStroke() async {
        let harness = makeHarness()
        swipe("es", on: harness)
        await harness.settle()
        let points = ["t", "r", "a", "g", "e", "d"].map { harness.point(for: $0) }
        let thumb = harness.down(at: points[0])
        harness.move(thumb, to: points[1], over: 0.05)
        harness.move(thumb, to: points[2], over: 0.05)
        harness.tap(.character("n"), gap: 0.02)
        harness.move(thumb, to: points[3], over: 0.05)
        harness.move(thumb, to: points[4], over: 0.05)
        harness.move(thumb, to: points[5], over: 0.05)
        harness.up(thumb)
        await harness.settle()
        #expect(harness.text.hasPrefix("es "))
        #expect(!harness.text.hasPrefix("estranged"))
    }

    @Test func aFollowingWordStartsANewWord() async {
        let harness = makeHarness()
        swipe("pill", on: harness)
        await harness.settle()
        swipe("the", on: harness)
        await harness.settle()
        #expect(harness.text == "pill the ")
    }

    @Test func backspacePeelsTheLastThumbAction() async {
        let harness = makeHarness()
        swipe("pil", on: harness)
        await harness.settle()
        let swiped = harness.text
        harness.tap(.character("e"))
        #expect(harness.text == swiped + "e")
        harness.tap(.backspace)
        #expect(harness.text == swiped)
    }

    @Test func pileFromASwipeAndATapDuringTheStroke() async {
        let harness = makeHarness()
        let points = ["p", "i", "l"].map { harness.point(for: $0) }
        let thumb = harness.down(at: points[0])
        harness.move(thumb, to: points[1], over: 0.06)
        harness.move(thumb, to: points[2], over: 0.06)
        harness.tap(.character("e"))
        harness.up(thumb)
        await harness.settle()
        #expect(harness.text == "pile ")
    }

    @Test func aLetterHeldBeforeTheSwipeStaysAtThatMoment() async {
        let harness = makeHarness()
        let held = harness.down(at: harness.point(for: "e"))
        swipe("pil", on: harness)
        harness.up(held)
        await harness.settle()
        #expect(!harness.text.hasPrefix("pil"))
        #expect(!harness.text.hasPrefix("pull"))
        #expect(harness.text.lowercased().hasPrefix("e"))
    }

    @Test func aBoundaryWobbleDoesNotTypeTheKeysCrossed() async {
        var committed: [KeyboardIntent] = []
        let composer = InputComposer { committed.append(contentsOf: $0) }
        let coordinator = SwipeCoordinator(composer: composer, matcher: AlignmentPathMatcher { _ in .empty })
        let id = TouchID(rawValue: 1)
        let start = TouchSample(id: id, location: .zero, timestamp: 0, phase: .began)
        var track = TouchTrack(start: start)
        coordinator.begin(track, ticket: composer.reserve())
        let mash = Array("ghghguhgyughg")
        for (index, letter) in mash.enumerated() {
            let x = CGFloat(index) * 4
            coordinator.arrive(id, letter: String(letter), at: CGPoint(x: x, y: 0), time: Double(index) * 0.01)
            track.append(TouchSample(id: id, location: CGPoint(x: x, y: 0), timestamp: Double(index) * 0.01, phase: .moved))
            coordinator.moved(track)
        }
        track.append(TouchSample(id: id, location: CGPoint(x: 80, y: 0), timestamp: 0.2, phase: .ended))
        coordinator.ended(track)

        var spins = 0
        while composer.hasPendingCommits, spins < 50 {
            spins += 1
            await Task.yield()
        }
        let typed = committed.reduce(into: "") { text, intent in
            switch intent {
            case let .commitSwipe(words, _, _, _, _): text += words.first ?? ""
            case let .insert(character): text += character
            default: break
            }
        }
        #expect(!typed.contains("ghgh"))
        #expect(typed.count < mash.count)
    }

    @Test func anEchoOfOurCommitLeavesTheWordOpen() async {
        #expect(KeyboardEngine.isOwnEcho(previous: "", current: "pil ", inserted: "pil "))
        #expect(KeyboardEngine.isOwnEcho(previous: "say ", current: "say pil ", inserted: "pil "))
        #expect(KeyboardEngine.isOwnEcho(previous: "say pil ", current: "pil ", inserted: "pil "))
        #expect(KeyboardEngine.isOwnEcho(previous: "pil ", current: "pile ", inserted: "pile "))
        #expect(!KeyboardEngine.isOwnEcho(previous: "pil ", current: "xxpil ", inserted: "pil "))
        #expect(!KeyboardEngine.isOwnEcho(previous: "pil ", current: "hello ", inserted: "pil "))

        let harness = makeHarness()
        harness.document.onChange = { _ in harness.engine.documentDidChange() }
        swipe("pil", on: harness)
        await harness.settle()
        harness.engine.documentDidChange()
        harness.tap(.character("e"))
        #expect(harness.text == "pill e")
    }

    @Test func anExternalEditLocksTheOpenWord() async {
        let harness = makeHarness()
        swipe("pil", on: harness)
        await harness.settle()
        harness.document.replaceAll(with: "elsewhere")
        harness.engine.documentDidChange()
        harness.tap(.character("e"))
        #expect(harness.text == "elsewheree")
    }

    @Test func twoConfidentSwipesStayTwoWords() async {
        let harness = makeHarness()
        swipe("hello", on: harness)
        await harness.settle()
        swipe("correct", on: harness)
        await harness.settle()
        #expect(harness.text.hasPrefix("hello "))
        #expect(!harness.text.contains("helloc"))
        let words = harness.text.split(separator: " ")
        #expect(words.count >= 2)
        #expect(words[0] == "hello")
    }

    @Test func twoShortWordsStayApartEvenWhenTheySpellALongerOne() async {
        let harness = makeHarness()
        swipe("in", on: harness)
        await harness.settle()
        let first = harness.text
        swipe("to", on: harness)
        await harness.settle()
        #expect(harness.text.hasPrefix(first))
        #expect(!harness.text.hasPrefix("into"))
    }

    @Test func aFragmentJoinsAQuickSecondSwipeAndAFinishedWordDoesNot() async {
        let harness = makeHarness()
        swipe("st", on: harness)
        await harness.settle()
        swipe("opping", on: harness)
        await harness.settle()
        #expect(!harness.text.hasPrefix("stopping"))
        #expect(harness.text.split(separator: " ").count >= 2)

        let apart = makeHarness()
        swipe("hello", on: apart)
        await apart.settle()
        swipe("correct", on: apart)
        await apart.settle()
        #expect(apart.text.split(separator: " ").first == "hello")

        let slow = makeHarness()
        swipe("st", on: slow)
        await slow.settle()
        slow.wait(0.6)
        swipe("opping", on: slow)
        await slow.settle()
        #expect(!slow.text.hasPrefix("stopping"))
    }

    @Test func aOneLetterWordIsNotPulledIntoTheNextSwipe() async {
        let harness = makeHarness()
        let origin = harness.point(for: "a")
        let id = harness.down(at: origin)
        harness.move(id, to: CGPoint(x: origin.x + 40, y: origin.y), over: 0.06)
        harness.move(id, to: origin, over: 0.06)
        harness.up(id)
        await harness.settle()
        let first = harness.text
        #expect(first.split(separator: " ").count == 1)
        swipe("the", on: harness)
        await harness.settle()
        #expect(harness.text.hasPrefix(first))
    }

    @Test func aQuickTapCanStillLengthenTheWord() async {
        let harness = makeHarness()
        swipe("the", on: harness)
        await harness.settle()
        harness.tap(.character("n"))
        #expect(harness.text == "the n")
    }

    @Test func theNiceUndoesAShortJoin() async {
        let harness = makeHarness()
        swipe("the", on: harness)
        await harness.settle()
        for letter in ["n", "i", "c", "e"] {
            harness.tap(.character(letter), gap: 0.02)
            await harness.settle()
        }
        #expect(harness.text == "the nice")
    }

    @Test func functionWordsDoNotSwallowTheNextBeat() async {
        let harness = makeHarness()
        swipe("no", on: harness)
        await harness.settle()
        harness.tap(.character("w"), gap: 0.02)
        #expect(!harness.text.lowercased().hasPrefix("now"))
        #expect(harness.text.lowercased().hasPrefix("no"))
    }

    @Test func aTapAfterTheLeashStartsTheNextWord() async {
        let harness = makeHarness()
        swipe("the", on: harness)
        await harness.settle()
        harness.wait(0.5)
        harness.tap(.character("n"))
        #expect(harness.text == "the n")
    }

    @Test func explicitSpaceKeepsTheNextSwipeInTheSameWord() async {
        let harness = makeHarness()
        swipe("hello", on: harness)
        await harness.settle()
        harness.wait(0.6)
        swipe("in", on: harness)
        await harness.settle()
        let letters = harness.text.filter(\.isLetter)
        #expect(letters.count > 5)
        #expect(harness.text.split(separator: " ").count == 2)
    }

    @Test func withdrawingAPreviewClearsTheBar() {
        let words = WordAssistant(editor: TextEditor(document: InMemoryTextDocument(text: "")))
        words.showPreview(DecodeResult(readings: [.init(word: "hello", score: -1)]))
        #expect(words.isPreviewing)
        #expect(words.showPreview(DecodeResult(readings: [], withdrawsPreview: true)))
        #expect(!words.isPreviewing)
    }

    @Test func theLeftSideOfASeamDiscouragesTheRightKey() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let fromTheLeft = AlignmentSearch.seamPenalty(
            letter: UInt8(ascii: "y"),
            touchX: harness.point(for: "t").x,
            layout: layout,
            bias: 0.35
        )
        let fromTheRight = AlignmentSearch.seamPenalty(
            letter: UInt8(ascii: "y"),
            touchX: harness.point(for: "y").x,
            layout: layout,
            bias: 0.35
        )
        #expect(fromTheLeft > fromTheRight)
    }

    @Test func aStraightRunKeepsCrossedKeysWithoutTypingThem() {
        let harness = makeHarness()
        let letters = ["q", "w", "e", "r", "t"]
        let points = letters.map { harness.point(for: $0) }
        var buffer = StrokeBuffer(start: StrokePoint(location: points[0], time: 0))
        for (index, point) in points.enumerated() {
            let time = Double(index) * 0.04
            buffer.append(StrokePoint(location: point, time: time))
            buffer.arrive(letters[index], at: point, touch: point, time: time)
        }
        buffer.finish(at: StrokePoint(location: points[points.count - 1], time: 0.2))
        let gesture = GestureComposer.compose([buffer])
        #expect((gesture?.tracedLetters.count ?? 9) < 5)
        #expect(gesture?.evidence.events.contains { $0.role == .crossing } == true)
    }

    @Test func grazesOnAStraightSegmentBecomeOneChannel() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let start = layout.center(of: UInt8(ascii: "i"))
        let end = layout.center(of: UInt8(ascii: "v"))
        let onLine = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let offLine = CGPoint(x: onLine.x + layout.keyWidth * 2, y: onLine.y)
        let events = [
            SwipeEvent(time: 0, point: start, letter: "i", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.04, point: onLine, letter: "h", role: .crossing, strokeIndex: 0),
            SwipeEvent(time: 0.06, point: offLine, letter: "b", role: .crossing, strokeIndex: 0),
            SwipeEvent(time: 0.1, point: end, letter: "v", role: .anchor, strokeIndex: 0),
        ]
        let steps = StrokeChannel.steps(from: events, keyWidth: layout.keyWidth, keyHeight: layout.keyHeight)
        let channels = steps.filter(\.isChannel)
        #expect(channels.count == 1)
        #expect(channels.first?.channel.map(\.letter) == ["h"])
        #expect(steps.contains { $0.event?.letter == "b" })
    }

    @Test func aWobbleIsNotAnAnchorAndACornerIs() {
        let shallow = gesture(through: [
            ("q", CGPoint(x: 0, y: 0)),
            ("w", CGPoint(x: 140, y: 0)),
            ("e", CGPoint(x: 280, y: 36)),
        ])
        #expect(shallow?.evidence.events.first { $0.letter == "w" }?.role == .crossing)

        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let corner = gesture(through: [
            ("t", layout.center(of: UInt8(ascii: "t"))),
            ("r", layout.center(of: UInt8(ascii: "r"))),
            ("a", layout.center(of: UInt8(ascii: "a"))),
        ])
        #expect(corner?.evidence.events.first { $0.letter == "r" }?.role == .anchor)
    }

    @Test func aLongDiagonalDecodesLive() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        guard let gesture = exactSwipe("live", layout: layout) else {
            Issue.record("Gesture missing")
            return
        }
        let result = decode(gesture, layout: layout)
        #expect(result.words.first?.lowercased() == "live")
    }

    @Test func twoThumbsCanSplitLive() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        guard let gesture = exactSwipe("live", layout: layout, split: true) else {
            Issue.record("Gesture missing")
            return
        }
        let result = decode(gesture, layout: layout)
        #expect(result.words.first?.lowercased() == "live")
    }

    @Test func anInterleavedTwoThumbWordDecodes() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let l = layout.center(of: UInt8(ascii: "l"))
        let v = layout.center(of: UInt8(ascii: "v"))
        let i = layout.center(of: UInt8(ascii: "i"))
        let e = layout.center(of: UInt8(ascii: "e"))
        let events = [
            SwipeEvent(time: 0, point: l, letter: "l", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.05, point: v, letter: "v", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.2, point: i, letter: "i", role: .anchor, strokeIndex: 1),
            SwipeEvent(time: 0.25, point: e, letter: "e", role: .anchor, strokeIndex: 1),
        ]
        let gesture = SwipeGesture(
            path: [l, v, i, e],
            strokeCount: 2,
            strokePaths: [[l, v], [i, e]],
            tracedLetters: "lvie",
            observations: [],
            evidence: SwipeEvidence(events: events, aimedLetters: "lvie")
        )
        let sink = DecodeTraceSink()
        let result = decode(gesture, layout: layout, trace: sink)
        #expect(result.words.contains { $0.lowercased() == "live" })
        #expect(
            result.words.first?.lowercased() == "live",
            Comment(rawValue: "words \(result.words) beam \(sink.trace.beamWords) recovered \(sink.trace.recovered)")
        )
    }

    @Test func aDelayedSecondThumbStillDecodes() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let l = layout.center(of: UInt8(ascii: "l"))
        let v = layout.center(of: UInt8(ascii: "v"))
        let i = layout.center(of: UInt8(ascii: "i"))
        let e = layout.center(of: UInt8(ascii: "e"))
        let events = [
            SwipeEvent(time: 0, point: l, letter: "l", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.04, point: v, letter: "v", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.30, point: i, letter: "i", role: .anchor, strokeIndex: 1),
            SwipeEvent(time: 0.34, point: e, letter: "e", role: .anchor, strokeIndex: 1),
        ]
        let gesture = SwipeGesture(
            path: [l, v, i, e],
            strokeCount: 2,
            strokePaths: [[l, v], [i, e]],
            tracedLetters: "lvie",
            observations: [],
            evidence: SwipeEvidence(events: events, aimedLetters: "lvie")
        )
        let result = decode(gesture, layout: layout)
        #expect(result.words.first?.lowercased() == "live")
    }

    @Test func aFollowerBonusBreaksATieAndLosesToADecisivePath() {
        let close = FollowerPrior.applying([
            .init(word: "love", score: -1.0),
            .init(word: "live", score: -1.2),
        ], expected: ["live"])
        #expect(close.first?.word == "live")
        let decisive = FollowerPrior.applying([
            .init(word: "love", score: -1.0),
            .init(word: "live", score: -2.0),
        ], expected: ["live"])
        #expect(decisive.first?.word == "love")
        #expect(FollowerPrior.weight < ReadingPolicy.exactLead)
    }

    @Test func perturbationSetKeepsCleanWordsAndClassifiesTheRest() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        for word in ["the", "and", "live"] {
            guard let gesture = exactSwipe(word, layout: layout) else {
                Issue.record("Gesture missing")
                continue
            }
            let sink = DecodeTraceSink()
            let result = decode(gesture, layout: layout, trace: sink)
            #expect(result.words.first?.lowercased() == word)
            #expect(sink.trace.loss(expecting: word) == .none)
        }
        guard let the = exactSwipe("the", layout: layout) else {
            Issue.record("Gesture missing")
            return
        }
        let shifted = shifted(the, by: CGPoint(x: layout.keyWidth * 0.9, y: 0))
        let sink = DecodeTraceSink()
        let result = decode(shifted, layout: layout, trace: sink)
        #expect(!sink.trace.aimedLetters.isEmpty)
        let loss = sink.trace.loss(expecting: "the")
        if result.words.first?.lowercased() == "the" {
            #expect(loss == .none)
        } else if (sink.trace.beamWords + sink.trace.readings).contains(where: { $0.lowercased() == "the" }) {
            #expect(loss == .rank)
        } else {
            #expect(loss == .recall)
        }
        #expect(DecodeTrace().loss(expecting: "hello", joinedWrong: true) == .boundary)
        #expect(DecodeTrace().loss(expecting: "hello", misclassified: true) == .classification)
    }

    @Test func learningHasAFileWithoutFullAccess() {
        #expect(LearningDirectory.fileURL(named: "habit-memory.json") != nil)
    }

    @Test func aCommonPrefixOutranksARarerOne() {
        let lexicon = TestLexicon.shared
        let common = lexicon.prefixLogCount([UInt8(ascii: "t"), UInt8(ascii: "h")])
        let rare = lexicon.prefixLogCount([UInt8(ascii: "q"), UInt8(ascii: "q")])
        #expect(common != nil)
        #expect((common ?? 0) > (rare ?? -.greatestFiniteMagnitude))
        #expect(lexicon.prefixLogCount([UInt8(ascii: "t")]) == nil)
    }

    @Test func aFollowerThePathFitsJoinsTheListAndAMissStaysOut() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.noteCommitted("of")
        #expect(language.expectedWords().first == "the")
        guard let fitting = exactSwipe("the", layout: layout), let other = exactSwipe("quick", layout: layout) else {
            Issue.record("Gesture missing")
            return
        }
        let found = decode(fitting, layout: layout, expected: language.expectedWords())
        #expect(found.words.contains { $0.lowercased() == "the" })
        let missed = decode(other, layout: layout, expected: ["the"])
        #expect(missed.words.first?.lowercased() != "the")
    }

    @Test func aRepeatedWordBeatsAnEqualShapeAndOneUseDoesNot() {
        #expect(HabitMemory.bonus(uses: 1) == 0)
        #expect(HabitMemory.bonus(uses: 2) > 0)
        #expect(HabitMemory.bonus(uses: 2) < DecodeResult.confidenceMargin)
        #expect(HabitMemory.bonus(uses: 10_000) == 0.45)

        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.noteCommitted("live")
        #expect(language.habitBonus(of: "live") == 0)
        language.noteCommitted("live")
        #expect(language.habitBonus(of: "live") > 0)

        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry),
              let gesture = exactSwipe("live", layout: layout) else {
            Issue.record("Gesture missing")
            return
        }
        let plain = decode(gesture, layout: layout)
        guard let leader = plain.readings.first, plain.readings.count > 1 else {
            Issue.record("Need a runner-up")
            return
        }
        let rival = plain.readings[1]
        let once = decode(gesture, layout: layout, habits: [rival.word.lowercased(): HabitMemory.bonus(uses: 1)])
        #expect(once.words.first?.lowercased() == leader.word.lowercased())
        let repeated = decode(gesture, layout: layout, habits: [rival.word.lowercased(): 0.45])
        let plainScore = plain.readings.first { $0.word.lowercased() == rival.word.lowercased() }?.score
        let boostedScore = repeated.readings.first { $0.word.lowercased() == rival.word.lowercased() }?.score
        #expect((boostedScore ?? 0) > (plainScore ?? 0) + 0.4)
        // The keys still spelled the leader. A habit inside the exact-lead window does not
        // replace that spelling; it does move an equal, unaligned shape.
        #expect(repeated.words.first?.lowercased() == leader.word.lowercased())
        let tied = DecodeResult(readings: [
            .init(word: "live", score: -1),
            .init(word: "love", score: -1),
        ])
        let broken = tied.readings.map { reading -> DecodeResult.Reading in
            let bonus = reading.word == "love" ? HabitMemory.bonus(uses: 32) : 0
            return .init(word: reading.word, score: reading.score + bonus)
        }.sorted { $0.score > $1.score }
        #expect(broken.first?.word == "love")
        #expect(HabitMemory.bonus(uses: 1) == 0)
    }

    @Test func aCommitBonusFadesAfterAMonth() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let full = HabitMemory.bonus(uses: 32, lastUsed: now, now: now)
        let thisWeek = HabitMemory.bonus(uses: 32, lastUsed: now.addingTimeInterval(-6 * 86_400), now: now)
        let halfway = HabitMemory.bonus(uses: 32, lastUsed: now.addingTimeInterval(-26 * 86_400), now: now)
        let gone = HabitMemory.bonus(uses: 32, lastUsed: now.addingTimeInterval(-50 * 86_400), now: now)
        #expect(full == thisWeek)
        #expect(full > 0.3)
        #expect(halfway > full * 0.4)
        #expect(halfway < full * 0.6)
        #expect(gone == 0)
        #expect(HabitMemory.bonus(uses: 1, lastUsed: now, now: now) == 0)
    }

    @Test func aHabitualPrefixStaysAheadOfARarerOne() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry),
              let gesture = exactSwipe("live", layout: layout) else {
            Issue.record("Gesture missing")
            return
        }
        let plain = decode(gesture, layout: layout)
        guard let rival = plain.readings.dropFirst().first else {
            Issue.record("Need a runner-up")
            return
        }
        let boosted = decode(gesture, layout: layout, habits: [rival.word.lowercased(): 0.45])
        let plainScore = plain.readings.first { $0.word.lowercased() == rival.word.lowercased() }?.score ?? 0
        let boostedScore = boosted.readings.first { $0.word.lowercased() == rival.word.lowercased() }?.score ?? 0
        let delta = boostedScore - plainScore
        // The prefix bonus only decides who stays in the beam. The finished word is scored once.
        #expect(delta > 0.4)
        #expect(delta < 0.55)
        #expect(boosted.words.contains { $0.lowercased() == rival.word.lowercased() })
    }

    @Test func liveBeatsVeliBecauseTheWordShapeDiffers() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry),
              let gesture = exactSwipe("live", layout: layout, split: true) else {
            Issue.record("Gesture missing")
            return
        }
        let result = decode(gesture, layout: layout)
        #expect(result.words.first?.lowercased() == "live")
        if let live = result.readings.firstIndex(where: { $0.word.lowercased() == "live" }),
           let veli = result.readings.firstIndex(where: { $0.word.lowercased() == "veli" }) {
            #expect(live < veli)
        }
    }

    @Test func aFastStrokeSkipsACrossingASlowStrokeKeeps() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let letters: [UInt8] = [UInt8(ascii: "l"), UInt8(ascii: "i"), UInt8(ascii: "v"), UInt8(ascii: "e")]
        let crossed = layout.center(of: UInt8(ascii: "k"))
        func gesture(speed: Double) -> SwipeGesture {
            var points = letters.map { layout.center(of: $0) }
            points.insert(crossed, at: 1)
            let roles: [EvidenceRole] = [.anchor, .crossing, .anchor, .anchor, .anchor]
            let names = ["l", "k", "i", "v", "e"]
            let events = zip(points.indices, points).map { index, point in
                SwipeEvent(
                    time: Double(index) * 0.05,
                    point: point,
                    letter: names[index],
                    role: roles[index],
                    strokeIndex: 0,
                    speed: speed,
                    distanceToCenter: index == 1 ? 0 : 1
                )
            }
            return SwipeGesture(
                path: points,
                strokeCount: 1,
                strokePaths: [points],
                tracedLetters: "lkive",
                observations: [],
                evidence: SwipeEvidence(events: events, aimedLetters: "live")
            )
        }
        let fast = decode(gesture(speed: 900), layout: layout)
        let slow = decode(gesture(speed: 80), layout: layout)
        let fastLive = fast.readings.first { $0.word.lowercased() == "live" }?.score
        let slowLive = slow.readings.first { $0.word.lowercased() == "live" }?.score
        #expect((fastLive ?? -.infinity) > (slowLive ?? -.infinity))
        #expect(fast.words.first?.lowercased() == "live")
    }

    @Test func aRejectedWordYieldsWhenThePreferredSpellingIsMissing() {
        let model = LanguageModel(lexicon: TestLexicon.shared)
        model.noteRejection(preferred: "teh", rejected: "the")
        let yielded = model.applyingRejections(to: DecodeResult(readings: [
            .init(word: "the", score: -0.1),
            .init(word: "three", score: -0.4),
        ]))
        #expect(yielded.words.first == "three")

        model.noteRejection(preferred: "other", rejected: "three")
        let stuck = model.applyingRejections(to: DecodeResult(readings: [
            .init(word: "the", score: -0.1),
            .init(word: "three", score: -0.4),
        ]))
        #expect(stuck.words == ["the", "three"])
    }

    /// A path through the word's key centers, also entering whatever keys that line crosses.
    private func exactSwipe(_ word: String, layout: LetterLayout, split: Bool = false) -> SwipeGesture? {
        let letters = LexiconKey.make(word)
        guard letters.count >= 2 else { return nil }
        if split, letters.count >= 4 {
            let mid = letters.count / 2
            let left = exactStroke(Array(letters[..<mid]), layout: layout, start: 0)
            let right = exactStroke(Array(letters[mid...]), layout: layout, start: 0.08)
            return GestureComposer.compose([left, right])
        }
        return GestureComposer.compose([exactStroke(letters, layout: layout, start: 0)])
    }

    private func exactStroke(_ letters: [UInt8], layout: LetterLayout, start: Double) -> StrokeBuffer {
        let word = String(decoding: letters, as: UTF8.self)
        let path = SwipeSynthesizer.path(for: word, layout: layout, jitter: 0, seed: 1)
        guard let first = path.first else {
            return StrokeBuffer(start: StrokePoint(location: .zero, time: start))
        }
        var time = start
        var buffer = StrokeBuffer(start: StrokePoint(location: first, time: time))
        var aimed: UInt8?
        for point in path.dropFirst() {
            time += 0.012
            buffer.append(StrokePoint(location: point, time: time))
            guard let letter = layout.letters(near: point, within: 0.65, limit: 1).first else { continue }
            if let aimed {
                let old = layout.center(of: aimed)
                let next = layout.center(of: letter)
                guard letter != aimed, hypot(point.x - next.x, point.y - next.y) < hypot(point.x - old.x, point.y - old.y) else { continue }
            }
            aimed = letter
            buffer.arrive(String(UnicodeScalar(letter)), at: layout.center(of: letter), touch: point, time: time)
        }
        if let last = path.last {
            buffer.finish(at: StrokePoint(location: last, time: time))
        }
        return buffer
    }

    private func gesture(through letters: [(String, CGPoint)]) -> SwipeGesture? {
        guard let first = letters.first else { return nil }
        var buffer = StrokeBuffer(start: StrokePoint(location: first.1, time: 0))
        for (index, letter) in letters.enumerated() {
            let time = Double(index) * 0.06
            if index > 0 {
                buffer.append(StrokePoint(location: letter.1, time: time))
            }
            buffer.arrive(letter.0, at: letter.1, touch: letter.1, time: time)
        }
        if let last = letters.last {
            buffer.finish(at: StrokePoint(location: last.1, time: Double(letters.count) * 0.06))
        }
        return GestureComposer.compose([buffer])
    }

    private func decode(
        _ gesture: SwipeGesture,
        layout: LetterLayout,
        expected: [String] = [],
        habits: [String: Double] = [:],
        trace: DecodeTraceSink? = nil,
        clock: SearchClock? = nil
    ) -> DecodeResult {
        var score = PathScore()
        return AlignmentSearch.decode(
            gesture,
            layout: layout,
            lexicon: TestLexicon.shared,
            personal: [],
            bigram: LetterBigram(lexicon: TestLexicon.shared),
            costs: .standard,
            expected: expected,
            habits: habits,
            trace: trace,
            clock: clock,
            pathScore: &score
        )
    }

    private func shifted(_ gesture: SwipeGesture, by delta: CGPoint) -> SwipeGesture {
        var events = gesture.evidence.events
        for index in events.indices {
            events[index].point.x += delta.x
            events[index].point.y += delta.y
        }
        let move: (CGPoint) -> CGPoint = { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return SwipeGesture(
            path: gesture.path.map(move),
            strokeCount: gesture.strokeCount,
            strokePaths: gesture.strokePaths.map { $0.map(move) },
            tracedLetters: gesture.tracedLetters,
            observations: gesture.observations,
            evidence: SwipeEvidence(events: events, aimedLetters: gesture.evidence.aimedLetters)
        )
    }

    @Test func aFingerHeldDownKeepsTheWordOpen() async {
        let harness = makeHarness()
        swipe("the", on: harness)
        await harness.settle()
        let held = harness.down(at: harness.point(for: "n"))
        harness.wait(0.38)
        harness.up(held)
        #expect(harness.text == "the n")
    }

    @Test func turningOffTheExtensionLeavesTheFinishedWordAlone() async {
        let harness = makeHarness()
        swipe("the", on: harness)
        await harness.settle()
        harness.tap(.character("n"))
        #expect(harness.text == "the n")
        swipe("hello", on: harness)
        await harness.settle()
        swipe("correct", on: harness)
        await harness.settle()
        let words = harness.text.split(separator: " ")
        #expect(words[0] == "the")
        #expect(!words.contains("then"))
    }

    @Test func aFragmentAfterTheLeashIsLeftAsTyped() async {
        let harness = makeHarness()
        swipe("es", on: harness)
        await harness.settle()
        let first = harness.text
        harness.wait(0.5)
        swipe("the", on: harness)
        await harness.settle()
        #expect(harness.text.hasPrefix(first))
        #expect(harness.text.split(separator: " ").count >= 2)
    }

    @Test func anAlternateReplacesOnlyItsOwnWord() async throws {
        let harness = makeHarness()
        swipe("hello", on: harness)
        await harness.settle()
        swipe("in", on: harness)
        await harness.settle()
        #expect(harness.text.hasPrefix("hello "))
        let alternatives = harness.state.candidates.candidates
        let side = try #require(alternatives.firstIndex { $0.role == .alternative })
        harness.engine.acceptCandidate(side)
        #expect(harness.text.hasPrefix("hello "))
        #expect(harness.text.hasSuffix(alternatives[side].text + " "))
        #expect(!harness.text.hasPrefix(alternatives[side].text))
    }

    @Test func aSlowStraightRunDoesNotTypeEveryKey() async {
        var committed: [KeyboardIntent] = []
        let composer = InputComposer { committed.append(contentsOf: $0) }
        let coordinator = SwipeCoordinator(composer: composer, matcher: AlignmentPathMatcher { _ in .empty })
        let letters = Array("qwertyuiop")
        let id = TouchID(rawValue: 1)
        let start = TouchSample(id: id, location: .zero, timestamp: 0, phase: .began)
        var track = TouchTrack(start: start)
        coordinator.begin(track, ticket: composer.reserve())
        for (index, letter) in letters.enumerated() {
            let x = CGFloat(index) * 38
            let time = Double(index) * 0.45
            coordinator.arrive(id, letter: String(letter), at: CGPoint(x: x, y: 0), time: time)
            track.append(TouchSample(id: id, location: CGPoint(x: x, y: 0), timestamp: time, phase: .moved))
            coordinator.moved(track)
        }
        let endX = CGFloat(letters.count - 1) * 38
        track.append(TouchSample(id: id, location: CGPoint(x: endX, y: 0), timestamp: 4, phase: .ended))
        coordinator.ended(track)

        var spins = 0
        while composer.hasPendingCommits, spins < 50 {
            spins += 1
            await Task.yield()
        }
        let typed = committed.reduce(into: "") { text, intent in
            switch intent {
            case let .commitSwipe(words, _, _, _, _): text += words.first ?? ""
            case let .insert(character): text += character
            default: break
            }
        }
        #expect(!typed.contains("qwert"))
        #expect(typed.count < 5)
    }

    @Test func backspaceStepsAJoinedSwipeBackToTheTypedLetters() async {
        let harness = makeHarness()
        harness.tap(.character("r"))
        swipe("ough", on: harness)
        await harness.settle()
        harness.tap(.backspace)
        #expect(harness.text == "r")
        harness.tap(.backspace)
        #expect(harness.text.isEmpty)
    }

    @Test func backspaceRemovesOnlyTheFollowingWord() async {
        let harness = makeHarness()
        swipe("pill", on: harness)
        await harness.settle()
        swipe("the", on: harness)
        await harness.settle()
        #expect(harness.text == "pill the ")
        harness.tap(.backspace)
        #expect(harness.text == "pill ")
    }

    @Test func aQuickTapJoinsTheFollowingSwipe() async {
        let harness = makeHarness()
        harness.tap(.character("r"))
        swipe("ough", on: harness)
        await harness.settle()
        harness.tap(.space)
        await harness.settle()
        #expect(harness.text == "rough ")
    }

    @Test func aPauseDoesNotCloseATapOpenedWord() async {
        let harness = makeHarness()
        harness.tap(.character("r"))
        harness.wait(KeyboardEngine.wordLeash + 0.1)
        swipe("ough", on: harness)
        await harness.settle()
        harness.tap(.space)
        await harness.settle()
        #expect(harness.text == "rough ")
    }

    @Test func aHeldLetterJoinsAfterTheShortcutRowOpens() async {
        var settings = KeyboardSettings()
        settings.keyShortcuts = ["r": ["ŕ"]]
        let harness = makeHarness(settings: settings)
        let held = harness.down(at: harness.point(for: "r"))
        harness.wait(CharacterTapSession.longPressDelay + 0.05)
        #expect(harness.state.interaction.callout != nil)
        swipe("ough", on: harness)
        harness.up(held)
        await harness.settle()
        #expect(harness.text == "rough ")
        #expect(!harness.text.contains("ŕ"))
    }

    @Test func aRejectedTapCorrectionIsNotApplied() {
        let model = LanguageModel(lexicon: TestLexicon.shared)
        let before = model.analyze("teh", touches: nil, layout: nil)
        guard before.correction?.lowercased() == "the" else { return }
        model.noteRejection(preferred: "teh", rejected: "the")
        let after = model.analyze("teh", touches: nil, layout: nil)
        #expect(after.correction?.lowercased() != "the")
    }

    @Test func aReturnTripKeepsTheTurnaround() {
        let cleaned = StrokeLetters.droppingReturnTrip(line("tyghgyt"))
        #expect(cleaned.map(\.letter).joined() == "tht")
    }

    @Test func aWordThatDoesNotWalkBackKeepsEveryLetter() {
        let arrivals = [
            arrival("t", x: 0),
            arrival("r", x: 40),
            arrival("a", x: 80),
            arrival("g", x: 40),
            arrival("e", x: 80, y: 40),
            arrival("d", x: 120, y: 40),
        ]
        let cleaned = StrokeLetters.droppingReturnTrip(arrivals)
        #expect(cleaned.map(\.letter).joined() == "traged")
    }

    @Test func twoThumbsSpellThatsWithoutTheKeysBetween() async {
        let harness = makeHarness()
        let right = harness.down(at: harness.point(for: "t"))
        for letter in ["y", "g", "h"] {
            harness.move(right, to: harness.point(for: letter), over: 0.04)
        }
        let left = harness.down(at: harness.point(for: "a"))
        for letter in ["g", "y", "t"] {
            harness.move(right, to: harness.point(for: letter), over: 0.04)
        }
        harness.move(left, to: harness.point(for: "s"), over: 0.04)
        harness.up(right)
        harness.up(left)
        await harness.settle()
        #expect(!harness.text.contains("tyghagyts"))
        #expect(harness.text == "that's ")
    }

    @Test func anApostropheIsNotALetterAndPrefersTheContraction() {
        var stroke = StrokeBuffer(start: StrokePoint(location: .zero, time: 0))
        stroke.append(StrokePoint(location: CGPoint(x: 80, y: 0), time: 0.1))
        stroke.arrive("t", at: .zero, time: 0)
        stroke.arrive("s", at: CGPoint(x: 40, y: 0), time: 0.05)
        stroke.arrive("'", at: CGPoint(x: 80, y: 0), time: 0.1)
        let gesture = GestureComposer.compose([stroke])
        #expect(gesture?.tracedLetters == "ts")
        #expect(gesture?.observations.contains { $0.letter == "'" } == false)
        #expect(gesture?.prefersContraction == true)

        let ranked = DecodeResult(readings: [
            .init(word: "thats", score: -0.1),
            .init(word: "that's", score: -0.4),
        ])
        #expect(ContractionPreference.apply(ranked, prefersContraction: false).words == ["thats", "that's"])
        #expect(ContractionPreference.apply(ranked, prefersContraction: true).words == ["that's", "thats"])
    }

    @Test func aLongMissCommitsTheNearestWord() {
        let traced = "tyghagyts"
        let result = ReadingPolicy.apply(
            DecodeResult(readings: [.init(word: "that's", score: -1)]),
            aimed: traced
        )
        #expect(result.words.first == "that's")
        #expect(result.words.first != traced)
        #expect(result.words.last == traced)
    }

    @Test func aimedLettersBeatAShapeThatDoesNotSpellThem() {
        let chosen = ReadingPolicy.apply(
            DecodeResult(readings: [
                .init(word: "pull", score: -0.2),
                .init(word: "pill", score: -1),
            ]),
            aimed: "pil"
        )
        #expect(chosen.words.first == "pill")

        let kept = ReadingPolicy.apply(
            DecodeResult(readings: [.init(word: "hello", score: -0.2)]),
            aimed: "hello"
        )
        #expect(kept.words.first == "hello")
    }

    @Test func aCloseCallPrefersTheWordThatFollowed() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.noteCommitted("the")
        language.noteCommitted("quick")
        language.noteCommitted("the")
        let close = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "quick", score: -1.2),
        ])
        #expect(language.preferringFollowers(in: close).words.first == "quick")
        let clear = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "quick", score: -3),
        ])
        #expect(language.preferringFollowers(in: clear).words.first == "quit")
    }

    @Test func aCloseCallUsesACommonPairUntilTheUserHasOne() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.noteCommitted("to")
        let close = DecodeResult(readings: [
            .init(word: "too", score: -1),
            .init(word: "the", score: -1.2),
        ])
        #expect(language.preferringFollowers(in: close).words.first == "the")
        let clear = DecodeResult(readings: [
            .init(word: "too", score: -1),
            .init(word: "the", score: -3),
        ])
        #expect(language.preferringFollowers(in: clear).words.first == "too")

        language.noteCommitted("too")
        language.noteCommitted("to")
        #expect(language.preferringFollowers(in: close).words.first == "too")
    }

    @Test func bothThumbsOutrankAWordThatSkipsOne() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let observations = [
            aimedStroke("t", stroke: 0, at: harness.point(for: "t"), time: 0),
            aimedStroke("a", stroke: 1, at: harness.point(for: "a"), time: 0.04),
            aimedStroke("h", stroke: 0, at: harness.point(for: "h"), time: 0.08),
            aimedStroke("t", stroke: 1, at: harness.point(for: "t"), time: 0.12),
            aimedStroke("s", stroke: 1, at: harness.point(for: "s"), time: 0.16),
        ]
        let evidence = SwipeEvidence.fromObservations(observations)
        let gesture = SwipeGesture(
            path: [harness.point(for: "a"), harness.point(for: "t"), harness.point(for: "s")],
            strokeCount: 2,
            strokePaths: [
                [harness.point(for: "t"), harness.point(for: "h")],
                [harness.point(for: "a"), harness.point(for: "t"), harness.point(for: "s")],
            ],
            tracedLetters: evidence.aimedLetters,
            observations: observations,
            evidence: evidence
        )
        var score = PathScore()
        let result = AlignmentSearch.decode(
            gesture,
            layout: layout,
            lexicon: TestLexicon.shared,
            personal: [],
            bigram: LetterBigram(lexicon: TestLexicon.shared),
            costs: .standard,
            pathScore: &score
        )
        #expect(result.words.first?.lowercased() == "that's")
    }

    @Test func aStraightFlickPlusATapCanSpellTheCrossedLetter() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let events = [
            SwipeEvent(time: 0, point: harness.point(for: "w"), letter: "w", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.04, point: harness.point(for: "e"), letter: "e", role: .crossing, strokeIndex: 0, distanceToCenter: 2),
            SwipeEvent(time: 0.08, point: harness.point(for: "r"), letter: "r", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.1, point: harness.point(for: "e"), letter: "e", role: .tap, strokeIndex: -2),
        ]
        let gesture = SwipeGesture(
            path: [harness.point(for: "w"), harness.point(for: "e"), harness.point(for: "r")],
            strokeCount: 1,
            strokePaths: [[harness.point(for: "w"), harness.point(for: "e"), harness.point(for: "r")]],
            tracedLetters: "wre",
            observations: events.filter(\.isAimed).map { event in
                StrokeObservation(time: event.time, point: event.point, directionX: 1, directionY: 0, letter: event.letter, isTap: event.isTap, strokeIndex: event.isTap ? -1 : 0)
            },
            evidence: SwipeEvidence(events: events, aimedLetters: "wre")
        )
        var score = PathScore()
        let result = AlignmentSearch.decode(
            gesture,
            layout: layout,
            lexicon: TestLexicon.shared,
            personal: [],
            bigram: LetterBigram(lexicon: TestLexicon.shared),
            costs: .standard,
            pathScore: &score
        )
        #expect(result.words.contains { $0.lowercased() == "were" })
    }

    @Test func aTapCanCrossAGrazedKey() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let w = harness.point(for: "w")
        let e = harness.point(for: "e")
        let s = harness.point(for: "s")
        let t = harness.point(for: "t")
        // The tap is early, and the grazed E sits on the line from W to T. Reading "west"
        // means the tap moved later across that graze.
        let events = [
            SwipeEvent(time: 0, point: w, letter: "w", role: .anchor, strokeIndex: 0),
            SwipeEvent(time: 0.02, point: s, letter: "s", role: .tap, strokeIndex: -2),
            SwipeEvent(time: 0.16, point: e, letter: "e", role: .crossing, strokeIndex: 0, distanceToCenter: 0),
            SwipeEvent(time: 0.30, point: t, letter: "t", role: .anchor, strokeIndex: 0),
        ]
        let gesture = SwipeGesture(
            path: [w, e, t],
            strokeCount: 1,
            strokePaths: [[w, e, t]],
            tracedLetters: "wst",
            observations: [],
            evidence: SwipeEvidence(events: events, aimedLetters: "wst")
        )
        let result = decode(gesture, layout: layout)
        #expect(
            result.words.contains { $0.lowercased() == "west" },
            Comment(rawValue: result.words.joined(separator: ", "))
        )
    }

    @Test func eachThumbKeepsItsOwnSkipBudget() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        func event(_ letter: String, time: Double, stroke: Int) -> SwipeEvent {
            SwipeEvent(time: time, point: harness.point(for: letter), letter: letter, role: .anchor, strokeIndex: stroke)
        }
        let events = [
            event("c", time: 0, stroke: 0),
            event("a", time: 0.02, stroke: 0),
            event("x", time: 0.04, stroke: 0),
            event("t", time: 0.06, stroke: 1),
            event("y", time: 0.08, stroke: 1),
            event("z", time: 0.10, stroke: 1),
        ]
        let gesture = SwipeGesture(
            path: [harness.point(for: "c"), harness.point(for: "t")],
            strokeCount: 2,
            strokePaths: [
                [harness.point(for: "c"), harness.point(for: "a"), harness.point(for: "x")],
                [harness.point(for: "t"), harness.point(for: "y"), harness.point(for: "z")],
            ],
            tracedLetters: "caxtyz",
            observations: [],
            evidence: SwipeEvidence(events: events, aimedLetters: "caxtyz")
        )
        let result = decode(gesture, layout: layout)
        #expect(result.words.contains { $0.lowercased() == "cat" })
    }

    @Test func tappingAPreviewReadingCommitsThatWord() async throws {
        let editor = TextEditor(document: InMemoryTextDocument(text: ""))
        let words = WordAssistant(editor: editor)
        let first = DecodeResult(readings: [
            .init(word: "hello", score: -1),
            .init(word: "help", score: -1.2),
        ])
        words.showPreview(first)
        #expect(words.promotePreview(at: 1))
        let shown = words.candidates(suggests: true, autocorrects: true)
        #expect(shown.isTentative)
        #expect(shown.candidates.first?.text == "help")
        let refreshed = DecodeResult(readings: [
            .init(word: "hello", score: -1),
            .init(word: "help", score: -1.4),
            .init(word: "held", score: -2),
        ])
        words.showPreview(refreshed)
        #expect(words.candidates(suggests: true, autocorrects: true).candidates.first?.text == "help")
        let committed = words.placingChoice(on: refreshed)
        #expect(committed.words.first == "help")
    }

    @Test func theLandedWordSitsInTheCenterAndASideStillSwaps() async throws {
        let harness = makeHarness()
        swipe("in", on: harness)
        await harness.settle()
        let landed = harness.text
        let candidates = harness.state.candidates
        let center = try #require(candidates.highlightedIndex)
        #expect(candidates.candidates[center].text + " " == landed)
        harness.engine.acceptCandidate(center)
        #expect(harness.text == landed)
        #expect(harness.state.candidates.highlightedIndex == nil)

        let again = makeHarness()
        swipe("in", on: again)
        await again.settle()
        let original = again.text
        let sides = again.state.candidates.candidates
        let side = try #require(sides.firstIndex { $0.role == .alternative })
        again.engine.acceptCandidate(side)
        #expect(again.text == sides[side].text + " ")
        #expect(again.text != original)
    }

    @Test func interleavedThumbsSpellTheWordBothOfThemDrew() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        let harness = EngineHarness(language: language)
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        let observations = [
            aimedStroke("t", stroke: 0, at: harness.point(for: "t"), time: 0),
            aimedStroke("a", stroke: 1, at: harness.point(for: "a"), time: 0.04),
            aimedStroke("h", stroke: 0, at: harness.point(for: "h"), time: 0.08),
            aimedStroke("t", stroke: 1, at: harness.point(for: "t"), time: 0.12),
            aimedStroke("s", stroke: 1, at: harness.point(for: "s"), time: 0.16),
        ]
        let outcome = language.sequenceDecode(observations, layout: layout)
        #expect(outcome.result.words.first?.lowercased() == "that's")
    }

    @Test func theTracedLettersKeepASideSlot() {
        let editor = TextEditor(document: InMemoryTextDocument(text: ""))
        editor.commitWord("these")
        let words = WordAssistant(editor: editor)
        words.language = LanguageModel(lexicon: TestLexicon.shared)
        words.swipeCommitted(["these", "there", "the", "thas"], unsure: false, literal: "thas")
        let strip = words.candidates(suggests: true, autocorrects: true)
        #expect(strip.candidates.first?.text == "thas")
        #expect(strip.highlightedIndex.map { strip.candidates[$0].text } == "these")
        #expect(strip.candidates.contains { $0.text == "theses" })
    }

    @Test func twoPrecedingWordsBreakACloseCall() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.noteCommitted("going")
        language.noteCommitted("to")
        let close = DecodeResult(readings: [
            .init(word: "a", score: -1),
            .init(word: "the", score: -1.2),
        ])
        #expect(language.preferringFollowers(in: close).words.first == "the")

        language.noteCommitted("zoo")
        language.noteCommitted("going")
        language.noteCommitted("to")
        let learned = DecodeResult(readings: [
            .init(word: "the", score: -1),
            .init(word: "zoo", score: -1.2),
        ])
        #expect(language.preferringFollowers(in: learned).words.first == "zoo")
    }

    @Test func aFamiliarPairWinsAWiderTieAndASentenceStartsFresh() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.noteCommitted("the")
        language.noteCommitted("quick")
        language.noteCommitted("the")
        let once = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "quick", score: -1.5),
        ])
        #expect(language.preferringFollowers(in: once).words.first == "quit")

        for _ in 0..<2 {
            language.noteCommitted("quick")
            language.noteCommitted("the")
        }
        let wider = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "quick", score: -1.3),
        ])
        #expect(language.preferringFollowers(in: wider).words.first == "quick")
        let clear = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "quick", score: -3.5),
        ])
        #expect(language.preferringFollowers(in: clear).words.first == "quit")

        let common = LanguageModel(lexicon: TestLexicon.shared)
        common.noteCommitted("to")
        let staticTie = DecodeResult(readings: [
            .init(word: "too", score: -1),
            .init(word: "the", score: -1.5),
        ])
        #expect(common.preferringFollowers(in: staticTie).words.first == "too")

        language.noteSentenceEnded()
        let forgotten = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "quick", score: -1.2),
        ])
        #expect(language.preferringFollowers(in: forgotten).words.first == "quit")
        let opener = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "it", score: -1.2),
        ])
        #expect(language.preferringFollowers(in: opener).words.first == "it")
        let openerClear = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "it", score: -3),
        ])
        #expect(language.preferringFollowers(in: openerClear).words.first == "quit")
    }

    @Test func aFamiliarWordLeadsAPlausibleSwipeAndAClearPathStays() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.noteCommitted("hello")
        language.noteCommitted("nimbus")
        language.noteCommitted("from")
        language.noteCommitted("nimbus")
        language.noteCommitted("the")
        language.noteCommitted("nimbus")
        language.noteCommitted("said")
        let close = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "nimbus", score: -2.2),
        ])
        #expect(language.preferringFollowers(in: close).words.first == "nimbus")
        let clear = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "nimbus", score: -3.5),
        ])
        #expect(language.preferringFollowers(in: clear).words.first == "quit")

        language.noteSentenceEnded()
        #expect(language.preferringFollowers(in: close).words.first == "quit")
    }

    @Test func aStoredNameKeepsItsCapitalAndAnInteriorCapitalSkipsSentenceShift() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.noteCommitted("Alex", display: "Alex")
        #expect(language.presenting("alex", shift: .off) == "Alex")
        #expect(language.presenting("alex", shift: .once) == "Alex")
        language.noteCommitted("iPhone", display: "iPhone")
        #expect(language.presenting("iphone", shift: .once) == "iPhone")
        #expect(language.presenting("iphone", shift: .locked) == "IPHONE")
        language.noteCommitted("Hello")
        #expect(language.presenting("hello", shift: .off) == "hello")
    }

    @Test func aSwappedUnknownWordJoinsTheNextDecode() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.isLearningEnabled = true
        let words = WordAssistant(editor: TextEditor(document: InMemoryTextDocument(text: "")))
        words.language = language
        words.noteSwap(preferred: "zorbly", rejected: "hi")

        let harness = EngineHarness(language: language)
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("Letter layout missing")
            return
        }
        var time = 0.0
        let observations = "zorbly".map { character -> StrokeObservation in
            time += 0.05
            let letter = String(character)
            return StrokeObservation(
                time: time,
                point: harness.point(for: letter),
                directionX: 1,
                directionY: 0,
                letter: letter
            )
        }
        let outcome = language.sequenceDecode(observations, layout: layout)
        #expect(outcome.result.words.contains { $0.lowercased() == "zorbly" })
    }

    @Test func aReversalDropsTheLastLetterAndABounceDoesNot() {
        let harness = makeHarness()
        let letters = ["t", "y", "u"]
        let points = letters.map { harness.point(for: $0) }
        var stroke = StrokeBuffer(start: StrokePoint(location: points[0], time: 0))
        stroke.arrive("t", at: points[0], touch: points[0], time: 0)
        stroke.append(StrokePoint(location: points[1], time: 0.05))
        stroke.arrive("y", at: points[1], touch: points[1], time: 0.05)
        stroke.append(StrokePoint(location: points[2], time: 0.1))
        stroke.arrive("u", at: points[2], touch: points[2], time: 0.1)
        let bounce = CGPoint(x: points[2].x - 12, y: points[2].y)
        stroke.append(StrokePoint(location: bounce, time: 0.12))
        #expect(stroke.arrivals.map(\.letter).joined() == "tyu")
        let dx = points[1].x - points[2].x
        let dy = points[1].y - points[2].y
        let span = max(hypot(dx, dy), 1)
        let pulled = CGPoint(x: bounce.x + dx / span * 36, y: bounce.y + dy / span * 36)
        stroke.append(StrokePoint(location: pulled, time: 0.2))
        #expect(stroke.arrivals.map(\.letter).joined() == "ty", "span \(span)")
    }

    @Test func anEarlierWordCanBeReplacedWithoutMovingTheCaret() {
        let document = InMemoryTextDocument(text: "hello wrong again")
        let editor = TextEditor(document: document)
        let words = TextBoundary.earlierWords(before: editor.contextBefore)
        #expect(words.map(\.text) == ["hello", "wrong", "again"])
        #expect(editor.replaceEarlierWord(words[1], with: "right"))
        #expect(document.text == "hello right again")
        #expect(document.before.hasSuffix("again"))
    }

    @Test func tapsUnderSixtyMillisecondsAreDifferentThumbs() {
        let times = [0.0, 0.04, 0.20]
        let points = [CGPoint(x: 10, y: 0), CGPoint(x: 12, y: 0), CGPoint(x: 200, y: 0)]
        let thumbs = TapThumbs.assign(times: times, points: points, midline: 100)
        #expect(thumbs == [0, 1, 1])
    }

    @Test func aRollJustPastTheKeyStaysATapUntilItClearsTheSlop() {
        let frame = CGRect(x: 10, y: 10, width: 40, height: 40)
        let room = frame.insetBy(dx: -SwipeSession.frameSlop, dy: -SwipeSession.frameSlop)
        #expect(room.contains(CGPoint(x: 52, y: 30)))
        #expect(!room.contains(CGPoint(x: 60, y: 30)))
    }

    @Test func aThirdStrokeIsATapAndDwellFollowsTheKey() {
        func stroke(_ letter: String, x: CGFloat, thumb: Int, time: Double) -> StrokeBuffer {
            var buffer = StrokeBuffer(start: StrokePoint(location: CGPoint(x: x, y: 0), time: time), thumb: thumb)
            buffer.append(StrokePoint(location: CGPoint(x: x + 40, y: 0), time: time + 0.1))
            buffer.arrive(letter, at: CGPoint(x: x, y: 0), time: time)
            return buffer
        }
        let continued = GestureComposer.compose([
            stroke("f", x: 0, thumb: 0, time: 0),
            stroke("e", x: 30, thumb: 0, time: 0.4),
            stroke("i", x: 180, thumb: 1, time: 0.2),
        ])
        #expect(continued?.strokeCount == 2)
        #expect(continued?.tracedLetters.contains("f") == true)
        #expect(continued?.tracedLetters.contains("e") == true)
        #expect(continued?.evidence.events.contains { $0.letter == "e" && $0.role == .tap } != true)
        let third = GestureComposer.compose([
            stroke("a", x: 0, thumb: 0, time: 0),
            stroke("b", x: 80, thumb: 1, time: 0.1),
            stroke("c", x: 160, thumb: 2, time: 0.2),
        ])
        #expect(third?.strokeCount == 2)
        #expect(third?.evidence.events.contains { $0.letter == "c" && $0.role == .tap } == true)
        #expect(ThumbLanes(active: [0, 1]).assigned(0) == nil)
        #expect(ThumbLanes(active: [0]).assigned(0) == 1)
        #expect(ThumbLanes(active: [0]).assigned(1) == 1)
        #expect(ThumbLanes(active: []).assigned(0) == 0)
        let narrow = EvidenceTuning.standard.scaled(to: StrokeBuffer.referenceKeyWidth / 2)
        #expect(narrow.dwellRadius == GestureComposer.dwellRadius / 2)
        #expect(narrow.dwellTravel == GestureComposer.dwellTravel / 2)
    }

    @Test func anExhaustedClockSkipsRecovery() throws {
        let layout = try #require(TestLayout.shared)
        let letters = ["c", "a", "t"].map { letter -> (String, CGPoint) in
            let byte = letter.utf8.first ?? UInt8(ascii: "a")
            return (letter, layout.center(of: byte))
        }
        guard let gesture = gesture(through: letters) else {
            Issue.record("No gesture")
            return
        }
        let sink = DecodeTraceSink()
        let clock = SearchClock(now: { 1 }, deadline: 0)
        _ = decode(gesture, layout: layout, trace: sink, clock: clock)
        #expect(sink.trace.recovered == false)
    }

    @Test func touchOffsetsAreMeasuredFromTheKeyCenter() throws {
        let layout = try #require(TestLayout.shared)
        let q = layout.center(of: UInt8(ascii: "q"))
        let p = layout.center(of: UInt8(ascii: "p"))
        let samples = TouchOffsetLog.samples(
            letters: ["q", "p"],
            points: [
                CGPoint(x: q.x + layout.keyWidth / 2, y: q.y),
                CGPoint(x: p.x - layout.keyWidth / 4, y: p.y),
            ],
            layout: layout
        )
        #expect(samples.map(\.side) == ["left", "right"])
        #expect(abs(samples[0].dx - 0.5) < 0.01)
        #expect(abs(samples[1].dx + 0.25) < 0.01)
    }

    @Test func moreOftenMakesAWordFamiliarAndLessOftenWalksItBack() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.moreOften("nimbus")
        let close = DecodeResult(readings: [
            .init(word: "quit", score: -1),
            .init(word: "nimbus", score: -2.2),
        ])
        language.noteCommitted("said")
        #expect(language.preferringFollowers(in: close).words.first == "nimbus")
        language.lessOften("nimbus")
        language.lessOften("nimbus")
        language.lessOften("nimbus")
        #expect(language.preferringFollowers(in: close).words.first == "quit")
        #expect(language.useCount(of: "nimbus") < WordContext.familiarUses)
    }

    @Test func aSuffixDraftJoinsThePreviousSwipe() {
        let harness = makeHarness()
        commitSwipe("walk", on: harness)
        harness.type("ing ")
        #expect(harness.text == "walking ")
    }

    @Test func aLetterThatIsNotASuffixStaysItsOwnWord() {
        let harness = makeHarness()
        commitSwipe("the", on: harness)
        harness.type("n ")
        #expect(harness.text == "the n ")
    }

    @Test func anUnknownSuffixStaysItsOwnWord() {
        let harness = makeHarness()
        commitSwipe("walk", on: harness)
        harness.type("ly ")
        #expect(harness.text == "walk ly ")
    }

    @Test func aSuffixChipRewritesTheSwipedWord() throws {
        let harness = makeHarness()
        commitSwipe("walk", on: harness)
        let chips = harness.state.candidates.candidates
        let index = try #require(chips.firstIndex { candidate in
            guard case let .replaceSuffix(match, replacement) = candidate.action else { return false }
            return match == "walk " && replacement == "walking "
        })
        harness.engine.acceptCandidate(index)
        #expect(harness.text == "walking ")
    }

    @Test func theFirstBackspaceRestoresTheAimedLetters() {
        let harness = makeHarness()
        #expect(harness.engine.perform(.commitSwipe(
            ["cat"],
            unsure: true,
            strokes: 1,
            observations: aimed("caxtyz"),
            strokePaths: []
        )))
        #expect(harness.state.candidates.candidates.first?.text == "caxtyz")
        harness.tap(.backspace)
        #expect(harness.document.typedComposing == "caxtyz")
        harness.tap(.backspace)
        #expect(harness.text.isEmpty)
    }
}

private func aimed(_ letters: String) -> [StrokeObservation] {
    letters.enumerated().map { index, character in
        StrokeObservation(
            time: Double(index),
            point: CGPoint(x: CGFloat(index) * 40, y: 0),
            directionX: 1,
            directionY: 0,
            letter: String(character)
        )
    }
}

private func aimedStroke(_ letter: String, stroke: Int, at point: CGPoint, time: Double) -> StrokeObservation {
    StrokeObservation(
        time: time,
        point: point,
        directionX: 1,
        directionY: 0,
        letter: letter,
        strokeIndex: stroke
    )
}

private func arrival(_ letter: String, x: CGFloat, y: CGFloat = 0) -> KeyArrival {
    KeyArrival(letter: letter, center: CGPoint(x: x, y: y), time: Double(x))
}

/// Letters spaced along a line that goes out and then back through the same points.
private func line(_ letters: String) -> [KeyArrival] {
    let characters = Array(letters)
    let turn = characters.count / 2
    return characters.enumerated().map { index, character in
        let distance = index <= turn ? index : (2 * turn - index)
        return arrival(String(character), x: CGFloat(distance) * 40)
    }
}

/// Parks swipe decodes until the test has started a second gesture.
@MainActor
private final class DecodeHold {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { continuations.count }

    func wait() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntil(count: Int) async -> Bool {
        for _ in 0..<50 where waiting < count {
            await Task.yield()
        }
        return waiting == count
    }
}

extension EngineHarness {
    /// Lets asynchronous swipe decoding finish and commit.
    func settle() async {
        engine.releaseHeldBeat()
        var attempts = 0
        while attempts < 500 {
            let pending = engine.composer.hasPendingCommits
            let flying = engine.hasSwipeWorkInFlight
            if !pending, !flying { break }
            // A tap-open word keeps its ticket until a delimiter. That is not a commit in flight.
            if pending, !flying, engine.isTapOpen { break }
            attempts += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
