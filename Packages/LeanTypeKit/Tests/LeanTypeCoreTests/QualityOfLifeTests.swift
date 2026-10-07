import CoreGraphics
import Testing
@testable import LeanTypeCore

@MainActor
@Suite("Quality of life")
struct QualityOfLifeTests {
    private static let plain = InputTraits(autocapitalization: .none)

    @Test func downwardFlickOnSpaceInsertsTheMarkUnderTheFinger() {
        let harness = EngineHarness(traits: Self.plain)
        let id = harness.down(at: harness.point(for: .space))
        harness.move(id, by: CGVector(dx: 0, dy: CharacterTapSession.flickDistance + 6), over: 0.08)
        guard case let .alternates(marks, selected) = harness.state.interaction.callout?.content else {
            Issue.record("A downward flick on space should open punctuation")
            return
        }
        #expect(marks == [".", ",", "?", "!", "'"])
        harness.up(id)
        #expect(harness.text == marks[selected])
    }

    @Test func aTapOnSpaceStillInsertsASpace() {
        let harness = EngineHarness(traits: Self.plain)
        harness.tap(.space)
        #expect(harness.text == " ")
    }

    @Test func flickDownTypesSecondary() {
        let harness = EngineHarness(traits: Self.plain)
        let id = harness.down(at: harness.point(for: "q"))
        harness.move(id, by: CGVector(dx: 1, dy: CharacterTapSession.flickDistance + 4), over: 0.06)
        harness.up(id)
        #expect(harness.text == "1")
    }

    @Test func slowDownwardDragIsNotAFlick() {
        let harness = EngineHarness(traits: Self.plain)
        let id = harness.down(at: harness.point(for: "q"))
        harness.wait(CharacterTapSession.flickMaxDuration + 0.05)
        harness.move(id, by: CGVector(dx: 0, dy: 8))
        harness.up(id)
        #expect(harness.text == "q")
    }

    @Test func flickCanBeTurnedOff() {
        let harness = EngineHarness(settings: KeyboardSettings(flickForSecondaryEnabled: false), traits: Self.plain)
        let id = harness.down(at: harness.point(for: "q"))
        harness.move(id, by: CGVector(dx: 0, dy: CharacterTapSession.flickDistance + 4), over: 0.06)
        harness.up(id)
        #expect(harness.text != "1")
    }

    @Test func slidingToSentencePunctuationHopsTheSpace() {
        let harness = EngineHarness(traits: Self.plain)
        harness.type("hi ")
        slide(harness, toSymbol: ".")
        #expect(harness.text == "hi. ")
        #expect(harness.state.layer == .letters)
    }

    @Test func punctuationAfterAWordGetsItsSpace() {
        let harness = EngineHarness(traits: Self.plain)
        harness.type("hi")
        slide(harness, toSymbol: ",")
        #expect(harness.text == "hi, ")
    }

    @Test func smartPunctuationCanBeTurnedOff() {
        let harness = EngineHarness(settings: KeyboardSettings(smartPunctuationEnabled: false), traits: Self.plain)
        harness.type("hi ")
        slide(harness, toSymbol: ".")
        #expect(harness.text == "hi .")
    }

    @Test func flingJumpsWholeWords() {
        let harness = EngineHarness(text: "one two three four")
        let id = harness.down(at: harness.point(for: .space))
        harness.move(id, by: CGVector(dx: -SpaceSession.activationDistance, dy: 0))
        harness.move(id, by: CGVector(dx: -SpaceSession.wordStep * 2, dy: 0), over: 0.02, steps: 2)
        harness.up(id)
        #expect(harness.recorder.events.contains(.cursorStep(direction: -1, byWord: true)))
        #expect(harness.document.after.hasPrefix("four") || harness.document.after.hasPrefix("three"))
    }

    @Test func secondFingerSwitchesTrackpadToWords() {
        let harness = EngineHarness(text: "one two three")
        let primary = harness.down(at: harness.point(for: .space))
        harness.move(primary, by: CGVector(dx: -SpaceSession.activationDistance, dy: 0))
        let secondary = harness.down(at: harness.point(for: "k"))
        #expect(harness.text == "one two three", "The extra finger doesn't type")

        harness.move(primary, by: CGVector(dx: -SpaceSession.wordStep * 2, dy: 0), over: 0.6, steps: 6)
        #expect(harness.document.before == "one ")
        harness.up(secondary)
        harness.up(primary)
        #expect(harness.text == "one two three")
    }

    @Test func parkingAtTheEdgeKeepsGliding() {
        let harness = EngineHarness(text: String(repeating: "word ", count: 40))
        let id = harness.down(at: harness.point(for: .space))
        harness.move(id, by: CGVector(dx: -SpaceSession.activationDistance, dy: 0))
        let start = harness.point(for: .space).x - SpaceSession.activationDistance
        harness.move(id, by: CGVector(dx: -(start - SpaceSession.edgeZone / 2), dy: 0), over: 1, steps: 20)
        let parked = harness.document.before.count
        harness.wait(SpaceSession.edgeRepeat.character * 10 + 0.01)
        #expect(harness.document.before.count <= parked - 9)
        harness.up(id)
    }

    @Test func holdingBackspaceEscalates() {
        let text = String(repeating: "Some words here. ", count: 30)
        let harness = EngineHarness(text: text, settings: KeyboardSettings(backspaceTapAction: .deleteCharacter))
        let id = harness.down(at: harness.point(for: .backspace))
        harness.wait(BackspaceSession.holdDelay + 2 * BackspaceSession.escalationDelay + 1)
        harness.up(id)
        let escalations = harness.recorder.count { $0 == .deleteEscalated }
        #expect(escalations == 2, "Characters, then words, then sentences")
        #expect(harness.text.count < text.count - 40)
    }

    @Test func heightSettingScalesRows() {
        let tall = KeyboardMetrics.portrait.scaled(by: KeyboardHeight.tall.scale)
        #expect(tall.keyHeight > KeyboardMetrics.portrait.keyHeight)
        #expect(tall.dockHeight == KeyboardMetrics.portrait.dockHeight)
        #expect(KeyboardMetrics.portrait.scaled(by: 1) == .portrait)
    }

    // MARK: - Helpers

    /// Presses 123, slides to `symbol`, and lifts.
    private func slide(_ harness: EngineHarness, toSymbol symbol: String) {
        let id = harness.down(at: harness.point(for: .layerSwitch(.numbers)))
        harness.move(id, to: harness.point(for: symbol))
        harness.up(id)
    }
}
