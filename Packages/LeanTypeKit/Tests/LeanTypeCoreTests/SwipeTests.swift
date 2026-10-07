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

    @Test func decodesFastEnough() async {
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
        // slower, and this wall-clock measurement shares the CPU with the rest of the suite.
        #expect(average < .milliseconds(120), "Average \(average), slowest \(slowest)")
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
    private func makeHarness(text: String = "") -> EngineHarness {
        EngineHarness(
            text: text,
            traits: InputTraits(autocapitalization: .none),
            language: LanguageModel(lexicon: TestLexicon.shared)
        )
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

    @Test func backspaceRemovesTheWholeSwipedWordAndCanRestoreIt() async {
        let harness = makeHarness(text: "say")
        swipe("hello", on: harness)
        await harness.settle()
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
        try #require(!alternatives.isEmpty)
        #expect(alternatives.allSatisfy { $0.role == .alternative })
        harness.engine.acceptCandidate(0)
        #expect(harness.text == alternatives[0].text + " ")
        #expect(harness.text != first)
        #expect(harness.state.candidates.candidates.contains { $0.text + " " == first }, "The original reading is offered back")
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
        #expect(harness.text.isEmpty, "A preview is not typed yet")
        harness.up(id)
        await harness.settle()
        #expect(harness.text == "hello ")
        #expect(!harness.state.candidates.isTentative)
    }

    @Test func aShortDownwardFlickStillTypesTheSecondary() {
        let harness = makeHarness()
        let id = harness.down(at: harness.point(for: "q"))
        harness.move(id, by: CGVector(dx: 1, dy: CharacterTapSession.flickDistance + 4), over: 0.06)
        harness.up(id)
        #expect(harness.text == "1")
        #expect(harness.state.interaction.strokes.isEmpty)
    }

    @Test func aSupersededSwipeDoesNotBlockLaterTyping() async {
        let hold = DecodeHold()
        var committed: [KeyboardIntent] = []
        let composer = InputComposer { committed.append(contentsOf: $0) }
        let coordinator = SwipeCoordinator(composer: composer) { _ in
            await hold.wait()
            return DecodeResult(readings: [.init(word: "hello", score: 0)])
        }

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
        #expect(committed == [.commitSwipe(["hello"], unsure: false, strokes: 1, observations: [])])
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
        let alternatives = harness.state.candidates.candidates
        try #require(!alternatives.isEmpty)
        #expect(alternatives.allSatisfy { $0.role == .alternative })
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
        let coordinator = SwipeCoordinator(composer: composer) { _ in .empty }
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
        guard case let .commitSwipe(words, unsure, strokes, observations) = committed.first else {
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

    @Test func pillThenLStaysPill() async {
        let harness = makeHarness()
        swipe("pil", on: harness)
        await harness.settle()
        harness.tap(.character("l"))
        #expect(harness.text == "pill ")
    }

    @Test func pilThenEBecomesPile() async {
        let harness = makeHarness()
        swipe("pil", on: harness)
        await harness.settle()
        harness.tap(.character("e"))
        #expect(harness.text == "pile ")
    }

    @Test func quitFromATapASwipeAndATap() async {
        let harness = makeHarness()
        harness.tap(.character("q"))
        swipe("ui", on: harness)
        await harness.settle()
        harness.tap(.character("t"))
        #expect(harness.text == "quit ")
    }

    @Test func waitFromASwipeAndTwoTaps() async {
        let harness = makeHarness()
        swipe("wa", on: harness)
        await harness.settle()
        harness.tap(.character("i"))
        harness.tap(.character("t"))
        #expect(harness.text == "wait ")
    }

    @Test func privateFromTapsAndTwoSwipes() async {
        let harness = makeHarness()
        harness.tap(.character("p"))
        harness.tap(.character("r"))
        harness.tap(.character("i"))
        swipe("va", on: harness)
        await harness.settle()
        swipe("te", on: harness)
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
        #expect(harness.text == "estranged ")
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
        #expect(harness.text == "pile ")
        harness.tap(.backspace)
        #expect(harness.text == swiped)
    }

    @Test func aRejectedTapCorrectionIsNotApplied() {
        let model = LanguageModel(lexicon: TestLexicon.shared)
        let before = model.analyze("teh", touches: nil, layout: nil)
        guard before.correction?.lowercased() == "the" else { return }
        model.noteRejection(preferred: "teh", rejected: "the")
        let after = model.analyze("teh", touches: nil, layout: nil)
        #expect(after.correction?.lowercased() != "the")
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
        var attempts = 0
        while engine.composer.hasPendingCommits, attempts < 500 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
