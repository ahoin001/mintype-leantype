import CoreGraphics
import Testing
@testable import LeanTypeCore

/// Mixed taps, holds, and swipes. These lock the lifecycle the decoder assumes.
@MainActor
@Suite("Mixed input")
struct MixedInputTests {
    private func makeHarness() -> EngineHarness {
        EngineHarness(
            traits: InputTraits(autocapitalization: .none),
            language: LanguageModel(lexicon: TestLexicon.shared)
        )
    }

    /// Tap f, r, i, then hold e past the leash while n lifts, then slide to d.
    @Test func tapsThenAHeldPartnerSpellFriend() async {
        let harness = makeHarness()
        harness.type("fri")
        let held = harness.down(at: harness.point(for: "e"))
        harness.wait(0.7)
        #expect(harness.text == "fri")
        let partner = harness.down(at: harness.point(for: "n"))
        harness.up(partner)
        #expect(harness.text == "fri")
        harness.move(held, to: harness.point(for: "d"), over: 0.08)
        harness.up(held)
        await harness.settle()
        harness.tap(.space)
        await harness.settle()
        #expect(harness.text == "friend ")
    }

    /// Two thumbs that never travel still type in touch-down order, including when the later finger lifts first.
    @Test func aPartnerThatLiftsFirstStaysInOrder() {
        let harness = makeHarness()
        let first = harness.down(at: harness.point(for: "t"))
        let second = harness.down(at: harness.point(for: "e"))
        harness.up(second)
        #expect(harness.text.isEmpty)
        harness.up(first)
        #expect(harness.text == "te")
    }

    /// A lone hold still opens the accent row. A second letter finger keeps it closed.
    @Test func aPartnerFingerSuppressesTheAccentRow() {
        var settings = KeyboardSettings()
        settings.keyShortcuts = ["e": ["é"]]
        let harness = EngineHarness(
            settings: settings,
            traits: InputTraits(autocapitalization: .none),
            language: LanguageModel(lexicon: TestLexicon.shared)
        )
        let alone = harness.down(at: harness.point(for: "e"))
        harness.wait(CharacterTapSession.longPressDelay + 0.05)
        #expect(harness.state.interaction.callout != nil)
        harness.up(alone)

        let held = harness.down(at: harness.point(for: "e"))
        let partner = harness.down(at: harness.point(for: "n"))
        harness.wait(CharacterTapSession.longPressDelay + 0.05)
        if case .alternates = harness.state.interaction.callout?.content {
            Issue.record("A partner finger opened the accent row")
        }
        harness.up(partner)
        harness.up(held)
    }

    /// A letter held past 500 ms while another finger draws stays in the beat and can be skipped.
    @Test func aLongRestDoesNotEraseTheOtherThumb() async {
        let harness = makeHarness()
        let rest = harness.down(at: harness.point(for: "x"))
        let stroke = harness.down(at: harness.point(for: "t"))
        harness.move(stroke, to: harness.point(for: "h"), over: 0.06)
        harness.move(stroke, to: harness.point(for: "e"), over: 0.06)
        harness.up(stroke)
        harness.wait(SwipeSession.restDuration)
        harness.up(rest)
        await harness.settle()
        #expect(harness.text == "the ")
    }

    @Test func aSameKeyPairInsideSixtyMillisecondsIsASlip() {
        let first = StrokeObservation(time: 1, point: .zero, directionX: 0, directionY: 0, letter: "l", isTap: true)
        var second = StrokeObservation(time: 1.02, point: .zero, directionX: 0, directionY: 0, letter: "l", isTap: true)
        second.time = first.time + TapThumbs.differentThumbGap / 2
        let gesture = GestureComposer.compose([], taps: [first, second])
        let roles = gesture?.evidence.events.map(\.role) ?? []
        #expect(roles.contains(.slip))
        #expect(roles.contains(.tap))
    }

    /// A new stroke after the fingers are up is its own word, even inside the old leash.
    @Test(arguments: [0.12, 0.18, 0.25])
    func helloThenWorldStaysTwoWords(gap: Double) async {
        let harness = makeHarness()
        swipe("hello", on: harness)
        await harness.settle()
        harness.wait(gap)
        swipe("world", on: harness)
        await harness.settle()
        #expect(harness.text == "hello world ")
    }

    /// The right thumb's letters arrive 120 ms early. `friend` still ranks in the top three.
    @Test func anEarlyRightThumbKeepsFriendInTheTopThree() {
        let harness = makeHarness()
        guard let layout = LetterLayout(geometry: harness.engine.geometry) else {
            Issue.record("No letter layout")
            return
        }
        let left = stroke([("f", 0), ("r", 0.20), ("e", 0.40), ("d", 0.60)], thumb: 0, layout: layout)
        let right = stroke([("i", 0), ("n", 0.18)], thumb: 1, layout: layout)
        guard let gesture = GestureComposer.compose([left, right]) else {
            Issue.record("No gesture")
            return
        }
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
        #expect(result.words.prefix(3).contains("friend"))
    }

    /// Cancelling a finger that never traveled types nothing, and the other thumb still types.
    @Test func cancellingAPendingFingerTypesNothing() {
        let harness = makeHarness()
        let held = harness.down(at: harness.point(for: "e"))
        let partner = harness.down(at: harness.point(for: "n"))
        harness.cancel(partner)
        #expect(harness.text.isEmpty)
        harness.up(held)
        #expect(harness.text == "e")
    }

    private func swipe(_ word: String, on harness: EngineHarness) {
        let points = word.map { harness.point(for: String($0)) }
        let id = harness.down(at: points[0])
        for point in points.dropFirst() {
            harness.move(id, to: point, over: 0.06)
        }
        harness.up(id)
    }

    private func stroke(_ letters: [(String, Double)], thumb: Int, layout: LetterLayout) -> StrokeBuffer {
        func point(of letter: String) -> CGPoint {
            layout.center(of: letter.utf8.first ?? UInt8(ascii: "a"))
        }
        let first = point(of: letters[0].0)
        var buffer = StrokeBuffer(start: StrokePoint(location: first, time: letters[0].1), thumb: thumb)
        for (letter, time) in letters {
            let point = point(of: letter)
            buffer.append(StrokePoint(location: point, time: time))
            buffer.arrive(letter, at: point, touch: point, time: time)
        }
        if let last = letters.last {
            buffer.finish(at: StrokePoint(location: point(of: last.0), time: last.1))
        }
        return buffer
    }
}
