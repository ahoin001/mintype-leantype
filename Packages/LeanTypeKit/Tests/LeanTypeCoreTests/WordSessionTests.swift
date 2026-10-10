import CoreGraphics
import Testing
@testable import LeanTypeCore

@Suite("Word session")
struct WordSessionTests {
    private func commit(in effects: [SessionEffect]) -> Timeline? {
        for effect in effects {
            if case let .commit(timeline, _) = effect { return timeline }
        }
        return nil
    }

    private func didCommit(_ effects: [SessionEffect]) -> Bool {
        commit(in: effects) != nil
    }

    @Test func heyStaysOpenAcrossAPauseAndAcceptsTheLaterSwipe() {
        var session = WordSession()
        session.reduce(.fingerDown)
        let lifted = session.reduce(.fingerUp(letter: "h", time: 1, wasStroke: false))
        #expect(!didCommit(lifted))
        #expect(session.phase == .tapOpen)
        #expect(session.timeline.tapLetters == "h")

        session.reduce(.fingerDown)
        session.reduce(.strokeStarted(.left))
        let afterSwipe = session.reduce(.fingerUp(letter: nil, time: 4, wasStroke: true))
        #expect(!didCommit(afterSwipe))
        #expect(afterSwipe.contains(.stayOpen))
        #expect(session.phase == .tapOpen)
        #expect(session.timeline.hasStroke)
        #expect(session.timeline.tapLetters == "h")

        let closed = session.reduce(.delimiter(.space))
        #expect(didCommit(closed))
        #expect(session.phase == .idle)
    }

    @Test func howdyCommitsWhenTheLastFingerLiftsAndEarlierIfContactBreaks() {
        var session = WordSession()
        session.reduce(.fingerDown)
        session.reduce(.strokeStarted(.right))
        #expect(session.phase == .swipeOpen)

        session.reduce(.fingerDown)
        session.reduce(.strokeStarted(.left))
        let handoff = session.reduce(.fingerUp(letter: nil, time: 2, wasStroke: true))
        #expect(!didCommit(handoff))
        #expect(session.phase == .swipeOpen)

        session.reduce(.fingerDown)
        session.reduce(.strokeStarted(.right))
        _ = session.reduce(.fingerUp(letter: nil, time: 3, wasStroke: true))
        let done = session.reduce(.fingerUp(letter: nil, time: 3.1, wasStroke: true))
        #expect(didCommit(done))
        #expect(session.phase == .idle)

        var cut = WordSession()
        cut.reduce(.fingerDown)
        cut.reduce(.strokeStarted(.right))
        let early = cut.reduce(.fingerUp(letter: nil, time: 1, wasStroke: true))
        #expect(didCommit(early))
        #expect(cut.phase == .idle)
    }

    @Test func stayCommitsOnlyWhenTheLastFingerLifts() {
        var session = WordSession()
        session.reduce(.fingerDown)
        session.reduce(.fingerDown)
        let tapped = session.reduce(.fingerUp(letter: "t", time: 1, wasStroke: false))
        #expect(!didCommit(tapped))
        #expect(session.phase == .contact)

        session.reduce(.strokeStarted(.left))
        #expect(session.phase == .swipeOpen)
        session.reduce(.fingerDown)
        session.reduce(.fingerUp(letter: "y", time: 2, wasStroke: false))
        let done = session.reduce(.fingerUp(letter: nil, time: 3, wasStroke: true))
        let draft = commit(in: done)
        #expect(draft?.tapLetters == "ty")
        #expect(draft?.hasStroke == true)
        #expect(session.phase == .idle)
    }

    @Test func aThirdFingerIsATap() {
        var session = WordSession()
        session.reduce(.fingerDown)
        session.reduce(.strokeStarted(.left))
        session.reduce(.fingerDown)
        session.reduce(.strokeStarted(.right))
        session.reduce(.fingerDown)
        let rejected = session.reduce(.strokeStarted(.left))
        #expect(rejected.isEmpty)
        session.reduce(.fingerUp(letter: "z", time: 1, wasStroke: false))
        #expect(session.timeline.strokeCount == 2)
        #expect(session.timeline.tapLetters == "z")
    }
}

@Suite("Gesture segmenter")
struct GestureSegmenterTests {
    private func probe(dx: CGFloat, dy: CGFloat, frame: CGRect = CGRect(x: 0, y: 0, width: 40, height: 40), location: CGPoint? = nil) -> GestureSegmenter.Probe {
        GestureSegmenter.Probe(
            translation: CGVector(dx: dx, dy: dy),
            location: location ?? CGPoint(x: 20 + dx, y: 20 + dy),
            hitFrame: frame,
            holdsUpwardFlick: false
        )
    }

    @Test func sidewaysTravelIsAStroke() {
        #expect(GestureSegmenter.isStroke(probe(dx: 16, dy: 0)))
        #expect(!GestureSegmenter.isStroke(probe(dx: 15, dy: 0)))
    }

    @Test func longTravelUsesSquaredDistance() {
        let frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        let origin = CGPoint(x: 60, y: 60)
        #expect(GestureSegmenter.isStroke(probe(dx: 0, dy: 36, frame: frame, location: CGPoint(x: origin.x, y: origin.y + 36))))
        #expect(!GestureSegmenter.isStroke(probe(dx: 0, dy: 35, frame: frame, location: CGPoint(x: origin.x, y: origin.y + 35))))
        #expect(!GestureSegmenter.isStroke(probe(dx: 10, dy: 10, frame: frame, location: CGPoint(x: origin.x + 10, y: origin.y + 10))))
    }

    @Test func clearingTheFrameSlopIsAStroke() {
        let frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let inside = CGPoint(x: 40 + GestureSegmenter.frameSlop - 1, y: 20)
        let outside = CGPoint(x: 40 + GestureSegmenter.frameSlop + 1, y: 20)
        #expect(!GestureSegmenter.isStroke(probe(dx: 4, dy: 0, frame: frame, location: inside)))
        #expect(GestureSegmenter.isStroke(probe(dx: 4, dy: 0, frame: frame, location: outside)))
    }
}

@Suite("Chunk history")
struct ChunkHistoryTests {
    @Test func undoingAJoinedSwipeRestoresTheTapDraft() {
        var history = ChunkHistory()
        history.rememberDraft("h")
        #expect(history.tapDraft == "h")
        history.noteCommitted()
        #expect(history.tapDraft == nil)
        #expect(history.restoreAfterCommit == "h")
        history.clear()
        #expect(history.restoreAfterCommit == nil)
    }

    @Test func aSwipeThatStartedTheWordHasNoDraft() {
        var history = ChunkHistory()
        history.noteCommitted()
        #expect(history.restoreAfterCommit == nil)
    }
}
