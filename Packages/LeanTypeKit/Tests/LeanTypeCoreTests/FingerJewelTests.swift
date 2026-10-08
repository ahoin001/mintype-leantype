import CoreGraphics
import Testing
@testable import LeanTypeCore

@Suite("Finger jewel")
struct FingerJewelTests {
    @Test func radiusClearsAThumbAtEveryIntensity() {
        #expect(FingerJewel.radius(for: 0.6) >= 28)
        #expect(FingerJewel.radius(for: 1) == 34)
        #expect(FingerJewel.radius(for: 1.35) > 34)
        #expect(FingerJewel.radius(for: 1.35) <= 48)
    }

    @Test func aMovingFingerParksTheBeadOnTheTrailingRim() {
        let contact = CGPoint(x: 100, y: 80)
        let jewel = FingerJewel.place(
            contact: contact,
            previousCenter: nil,
            velocity: CGVector(dx: 600, dy: 0),
            intensity: 1
        )
        #expect(jewel.drawsTrail)
        #expect(jewel.bead.x < contact.x)
        #expect(abs(jewel.bead.y - jewel.center.y) < 0.01)
        let fromCenter = hypot(jewel.bead.x - jewel.center.x, jewel.bead.y - jewel.center.y)
        #expect(abs(fromCenter - jewel.radius) < 0.01)
    }

    @Test func aStillFingerKeepsTheBeadOnTheRingWithoutATrail() {
        let contact = CGPoint(x: 40, y: 40)
        let jewel = FingerJewel.place(
            contact: contact,
            previousCenter: CGPoint(x: 20, y: 40),
            velocity: .zero,
            intensity: 1
        )
        #expect(!jewel.drawsTrail)
        #expect(jewel.center == contact)
        let fromCenter = hypot(jewel.bead.x - jewel.center.x, jewel.bead.y - jewel.center.y)
        #expect(abs(fromCenter - jewel.radius) < 0.01)
    }

    @Test func theRingLagsBehindAndStaysWithinTheLeash() {
        let contact = CGPoint(x: 100, y: 50)
        let first = FingerJewel.place(
            contact: contact,
            previousCenter: CGPoint(x: 40, y: 50),
            velocity: CGVector(dx: 500, dy: 0),
            intensity: 1
        )
        let lead = hypot(first.center.x - contact.x, first.center.y - contact.y)
        #expect(lead <= FingerJewel.lag + 0.01)
        #expect(first.center.x < contact.x)
    }

    @Test func theLiveEndInsideTheRingIsDroppedAndTheBeadBecomesTheTip() {
        let center = CGPoint(x: 200, y: 100)
        let radius: CGFloat = 34
        let bead = CGPoint(x: center.x - radius, y: center.y)
        let samples = [
            FingerJewel.Sample(location: CGPoint(x: 20, y: 100), time: 0),
            FingerJewel.Sample(location: CGPoint(x: 80, y: 100), time: 0.05),
            FingerJewel.Sample(location: CGPoint(x: center.x - 10, y: center.y), time: 0.1),
            FingerJewel.Sample(location: CGPoint(x: center.x, y: center.y), time: 0.15),
        ]
        let visible = FingerJewel.visibleTrail(
            samples: samples,
            center: center,
            radius: radius,
            bead: bead,
            drawsTrail: true
        )
        #expect(visible.map(\.location.x) == [20, 80, bead.x])
        #expect(visible.last?.location == bead)
    }

    @Test func aStillFingerPublishesNoTrail() {
        let visible = FingerJewel.visibleTrail(
            samples: [FingerJewel.Sample(location: .zero, time: 0)],
            center: .zero,
            radius: 34,
            bead: CGPoint(x: 0, y: 34),
            drawsTrail: false
        )
        #expect(visible.isEmpty)
    }

    @Test func partyKeepsMoreGlintsAndSparksThanSubtle() {
        #expect(FingerJewel.glintLimit(intensity: 0.6) < FingerJewel.glintLimit(intensity: 1))
        #expect(FingerJewel.glintLimit(intensity: 1) < FingerJewel.glintLimit(intensity: 1.35))
        #expect(FingerJewel.sparkLimit(intensity: 0.6) < FingerJewel.sparkLimit(intensity: 1.35))
        #expect(FingerJewel.glintLimit(intensity: 1) == 12)
    }
}
