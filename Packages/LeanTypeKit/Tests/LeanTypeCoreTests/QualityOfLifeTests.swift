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

    @Test func periodAfterAWordHopsAndTheNextLetterIsCapital() {
        let harness = EngineHarness()
        harness.type("hi")
        harness.tap(.character("."))
        #expect(harness.text == "Hi. ")
        harness.tap(.character("a"))
        #expect(harness.text == "Hi. A")
    }

    @Test func holdingPeriodStartsOnPeriodAndCanInsertDollar() throws {
        let harness = EngineHarness(traits: Self.plain)
        harness.type("hi")
        let origin = harness.point(for: ".")
        let id = harness.down(at: origin)
        harness.wait(CharacterTapSession.longPressDelay + 0.05)
        guard case let .alternates(marks, selected) = harness.state.interaction.callout?.content else {
            Issue.record("Holding the period key should open its marks")
            return
        }
        #expect(marks == [".", "?", "!", "$"])
        #expect(selected == 0)
        let dollar = try #require(marks.firstIndex(of: "$"))
        let frame = try #require(harness.state.interaction.callout?.layout.optionFrames[dollar])
        harness.move(id, to: CGPoint(x: frame.midX, y: origin.y), over: 0.05)
        harness.up(id)
        #expect(harness.text == "hi$")
    }

    @Test func holdingArmsTheRowAndReleasingEndsIt() {
        let harness = EngineHarness(traits: Self.plain)
        let id = harness.down(at: harness.point(for: "."))
        #expect(harness.recorder.events.contains { if case .holdArmed = $0 { true } else { false } })
        harness.wait(CharacterTapSession.longPressDelay + 0.05)
        #expect(harness.recorder.events.contains(.alternatesPresented))
        harness.up(id)
        #expect(harness.recorder.events.contains(.holdEnded))
    }

    @Test func aKeyWithoutAHoldRowDoesNotArm() {
        let harness = EngineHarness(traits: Self.plain)
        let id = harness.down(at: harness.point(for: "q"))
        harness.up(id)
        let armed = harness.recorder.events.contains { if case .holdArmed = $0 { true } else { false } }
        #expect(!armed)
    }

    @Test func releasingAPeriodHoldTypesPeriod() {
        let harness = EngineHarness(traits: Self.plain)
        harness.type("hi")
        let id = harness.down(at: harness.point(for: "."))
        harness.wait(CharacterTapSession.longPressDelay + 0.05)
        harness.up(id)
        #expect(harness.text == "hi. ")
    }

    @Test func apostropheStaysInsideTheWord() {
        let harness = EngineHarness(traits: Self.plain)
        harness.type("don")
        harness.tap(.character("'"))
        harness.tap(.character("t"))
        #expect(harness.text == "don't")
        harness.tap(.backspace)
        #expect(harness.text.isEmpty)
    }

    @Test func flickUpLiftsTheWordAndDeletePutsItBack() {
        let harness = EngineHarness(text: "hello", traits: Self.plain)
        flickUp(on: harness)
        #expect(harness.text.isEmpty)
        #expect(harness.state.candidates.candidates.first == Candidate("hello", role: .picked))
        #expect(harness.state.candidates.highlightedIndex == nil)
        harness.tap(.backspace)
        #expect(harness.text == "hello")
    }

    @Test func typingReplacesAPickedUpWord() {
        let harness = EngineHarness(text: "hello", traits: Self.plain)
        flickUp(on: harness)
        harness.tap(.character("a"))
        #expect(harness.text == "a")
        harness.tap(.backspace)
        #expect(harness.text.isEmpty)
    }

    @Test func flickingUpAgainRestoresTheWord() {
        let harness = EngineHarness(text: "hello world", traits: Self.plain)
        for _ in 0..<("world".count) {
            harness.engine.perform(.moveCursor(-1))
        }
        flickUp(on: harness)
        #expect(harness.text == "world")
        flickUp(on: harness)
        #expect(harness.text == "hello world")
    }

    @Test func aTapOnSpaceStillInsertsASpace() {
        let harness = EngineHarness(traits: Self.plain)
        harness.tap(.space)
        #expect(harness.text == " ")
    }

    @Test func flickUpTypesTheTopRowDigit() {
        let harness = EngineHarness(traits: Self.plain)
        let id = harness.down(at: harness.point(for: "q"))
        harness.move(id, by: CGVector(dx: 1, dy: -(CharacterTapSession.flickDistance + 4)), over: 0.06)
        harness.up(id)
        #expect(harness.text == "1")
    }

    @Test func flickUpPastTheKeyStillTypesTheDigit() {
        let harness = EngineHarness(traits: Self.plain)
        let id = harness.down(at: harness.point(for: "q"))
        harness.move(id, by: CGVector(dx: 1, dy: -40), over: 0.08)
        #expect(harness.state.interaction.callout?.content == .preview("1"))
        #expect(harness.state.interaction.callout?.growsFromKey == true)
        #expect(harness.state.interaction.strokes.isEmpty)
        harness.up(id)
        #expect(harness.text == "1")
    }

    @Test func aLowerRowHasNoFlickCharacter() {
        let harness = EngineHarness(traits: Self.plain)
        let id = harness.down(at: harness.point(for: "a"))
        harness.move(id, by: CGVector(dx: 0, dy: -(CharacterTapSession.flickDistance + 4)), over: 0.06)
        harness.up(id)
        #expect(harness.text == "a")
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
        harness.move(id, by: CGVector(dx: 0, dy: -(CharacterTapSession.flickDistance + 4)), over: 0.06)
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

    @Test func returnSendsTheKeyLabel() {
        let harness = EngineHarness(text: "hi")
        harness.tap(.returnKey)
        let sent = harness.recorder.events.contains { event in
            if case let .returnSent(title, frame) = event {
                title == "return" && frame.width > 1
            } else {
                false
            }
        }
        #expect(sent)
        #expect(harness.text.hasSuffix("\n"))
    }

    @Test func holdingBackspaceEscalates() {
        let text = String(repeating: "Some words here. ", count: 30)
        let harness = EngineHarness(text: text, settings: KeyboardSettings(backspaceTapAction: .deleteCharacter))
        let id = harness.down(at: harness.point(for: .backspace))
        harness.wait(BackspaceSession.holdDelay + 2 * BackspaceSession.escalationDelay + 1)
        harness.up(id)
        let escalations = harness.recorder.events.compactMap { event -> DeleteGear? in
            if case let .deleteEscalated(gear) = event { gear } else { nil }
        }
        #expect(escalations == [.word, .sentence])
        #expect(harness.text.count < text.count - 40)
    }

    @Test func heightSettingScalesRows() {
        let tall = KeyboardMetrics.portrait.scaled(by: KeyboardHeight.tall.scale)
        #expect(tall.keyHeight > KeyboardMetrics.portrait.keyHeight)
        #expect(tall.dockHeight == KeyboardMetrics.portrait.dockHeight)
        #expect(KeyboardMetrics.portrait.scaled(by: 1) == .portrait)
    }

    // MARK: - Helpers

    private func flickUp(on harness: EngineHarness) {
        let id = harness.down(at: harness.point(for: .space))
        harness.move(id, by: CGVector(dx: 0, dy: -(CharacterTapSession.flickDistance + 6)), over: 0.08)
        harness.up(id)
    }

    /// Presses 123, slides to `symbol`, and lifts.
    private func slide(_ harness: EngineHarness, toSymbol symbol: String) {
        let id = harness.down(at: harness.point(for: .layerSwitch(.numbers)))
        harness.move(id, to: harness.point(for: symbol))
        harness.up(id)
    }
}
