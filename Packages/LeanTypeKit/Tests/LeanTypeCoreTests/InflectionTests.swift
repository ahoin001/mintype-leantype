import CoreGraphics
import Foundation
import Testing
@testable import LeanTypeCore

@Suite("Suffix joining")
struct InflectionTests {
    private let known: Set<String> = ["walking", "walked", "walks"]

    @Test func walkPlusIngJoins() {
        let joined = InflectionJoiner.joined(previous: "walk", draft: "ing") { known.contains($0) }
        #expect(joined == "walking")
    }

    @Test func thePlusNStaysTwoWords() {
        let joined = InflectionJoiner.joined(previous: "the", draft: "n") { _ in true }
        #expect(joined == nil)
    }

    @Test func anUnknownConcatenationDoesNotJoin() {
        let joined = InflectionJoiner.joined(previous: "walk", draft: "ly") { known.contains($0) }
        #expect(joined == nil)
    }

    @Test func aCapitalizedWordKeepsItsFirstLetter() {
        #expect(InflectionJoiner.matchingCase("walking", like: "Walk") == "Walking")
        #expect(InflectionJoiner.matchingCase("walking", like: "walk") == "walking")
    }

    @Test func touchBiasCapsTheMeanError() {
        let samples = (0..<8).map { _ in TouchOffsetLog.Sample(side: "left", dx: 2, dy: -3) }
        let bias = TouchBias.summarizing(samples)
        #expect(abs(bias.left.dx - 0.2) < 0.001)
        #expect(abs(bias.left.dy + 0.2) < 0.001)
        #expect(bias.right == .zero)
        let shift = bias.offset(thumb: 0, keyWidth: 40, keyHeight: 50)
        #expect(abs(shift.dx - 8) < 0.01)
        #expect(abs(shift.dy + 10) < 0.01)
        #expect(bias.offset(thumb: 1, keyWidth: 40, keyHeight: 50) == .zero)
    }
}
