import CoreGraphics
import Testing
import LeanTypeDesign

@Suite("Morph")
struct MorphTests {
    private let from = CGRect(x: 0, y: 0, width: 40, height: 20)
    private let to = CGRect(x: 80, y: 0, width: 40, height: 20)

    @Test func aStretchLetsTheLeadingEdgeArriveFirst() {
        let mid = Morph.frame(from: from, to: to, kind: .stretch, progress: 0.45, travels: true)
        let leadingLeft = abs(to.maxX - mid.maxX)
        let trailingLeft = abs(to.minX - mid.minX)
        #expect(leadingLeft < trailingLeft)
        #expect(mid.width > from.width)
    }

    @Test func reduceMotionMovesBothEdgesTogether() {
        let mid = Morph.frame(from: from, to: to, kind: .stretch, progress: 0.5, travels: false)
        #expect(mid.minX == 40)
        #expect(mid.maxX == 80)
        #expect(mid.width == from.width)
    }

    @Test func expandPassesTheDestinationThenRests() {
        let over = Morph.frame(from: from, to: to, kind: .expand, progress: 0.75, travels: true)
        let rest = Morph.frame(from: from, to: to, kind: .expand, progress: 1, travels: true)
        #expect(over.width > to.width)
        #expect(rest == to)
        #expect(Morph.frame(from: from, to: to, kind: .expand, progress: 0, travels: true) == from)
    }

    @Test func settlePinchesInTheMiddleAndMeetsBothEnds() {
        #expect(Morph.frame(from: from, to: to, kind: .settle, progress: 0, travels: true) == from)
        #expect(Morph.frame(from: from, to: to, kind: .settle, progress: 1, travels: true) == to)
        let mid = Morph.frame(from: from, to: to, kind: .settle, progress: 0.5, travels: true)
        let straight = Morph.frame(from: from, to: to, kind: .settle, progress: 0.5, travels: false)
        #expect(mid.width < straight.width)
    }

    @Test func contractStartsSlowerThanAStraightMove() {
        let mid = Morph.frame(from: to, to: from, kind: .contract, progress: 0.5, travels: true)
        let straight = Morph.frame(from: to, to: from, kind: .contract, progress: 0.5, travels: false)
        #expect(abs(mid.midX - to.midX) < abs(straight.midX - to.midX))
    }

    @Test func aPlanKeepsTheShapeAtItsSampleTimes() {
        let plan = Morph.plan(from: from, to: to, kind: .stretch, duration: 0.12, travels: true)
        #expect(plan.samples.first?.time == 0)
        #expect(plan.samples.last?.time == 1)
        #expect(plan.samples.last?.frame == to)
        let posed = plan.samples.first { $0.time == 0.45 }
        let direct = Morph.frame(from: from, to: to, kind: .stretch, progress: 0.45, travels: true)
        #expect(posed?.frame == direct)
    }

    @Test func onlyAnExpandingShapeDelaysItsContents() {
        let open = Morph.plan(from: from, to: to, kind: .expand, duration: 0.2, travels: true)
        let slide = Morph.plan(from: from, to: to, kind: .stretch, duration: 0.12, travels: true)
        let still = Morph.plan(from: from, to: to, kind: .expand, duration: 0.2, travels: false)
        #expect(open.contentReveal > 0)
        #expect(slide.contentReveal == 0)
        #expect(still.contentReveal == 0)
    }
}
