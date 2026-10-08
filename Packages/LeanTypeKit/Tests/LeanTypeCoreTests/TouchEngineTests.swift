import CoreGraphics
import Testing
@testable import LeanTypeCore

@MainActor
@Suite("Tap typing")
struct TapTypingTests {
    @Test func typesWithAutoCapitalization() {
        let harness = EngineHarness()
        harness.type("hi there")
        #expect(harness.text == "Hi there")
    }

    @Test func rolloverPreservesTouchDownOrder() {
        let harness = EngineHarness(
            settings: KeyboardSettings(typingMode: .tap),
            traits: InputTraits(autocapitalization: .none)
        )
        let first = harness.down(at: harness.point(for: "o"))
        let second = harness.down(at: harness.point(for: "k"))
        #expect(harness.text == "o", "The first key commits as soon as the second finger lands")
        harness.up(second)
        harness.up(first)
        #expect(harness.text == "ok")
    }

    @Test func laterFingerWaitsForEarlierUndecidedFinger() {
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none))
        let accent = harness.down(at: harness.point(for: "e"))
        harness.wait(CharacterTapSession.longPressDelay + 0.05)
        #expect(harness.state.interaction.callout != nil)

        let other = harness.tapDownUp(harness.point(for: "x"))
        #expect(harness.text.isEmpty, "x must wait until the alternates menu resolves")
        _ = other

        harness.up(accent)
        #expect(harness.text == "èx")
    }

    @Test func slidingAcrossKeysRetargetsBeforeCommit() {
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none))
        let id = harness.down(at: harness.point(for: "q"))
        harness.move(id, to: harness.point(for: "w"))
        #expect(harness.state.interaction.pressedKeys.count == 1)
        harness.up(id)
        #expect(harness.text == "w")
    }

    @Test func previewCalloutFollowsPressedKey() {
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none))
        let id = harness.down(at: harness.point(for: "g"))
        guard case let .preview(label) = harness.state.interaction.callout?.content else {
            Issue.record("Expected a preview callout")
            return
        }
        #expect(label == "g")
        harness.up(id)
        #expect(harness.state.interaction == .idle)
    }

    @Test func doubleSpaceInsertsPeriod() {
        let harness = EngineHarness()
        harness.type("ok  ")
        #expect(harness.text == "Ok. ")
        #expect(harness.state.shift == .once, "A new sentence auto-capitalizes")
    }
}

@MainActor
@Suite("Space bar trackpad")
struct SpaceTrackpadTests {
    @Test func dragMovesCursorWithoutTypingSpace() {
        let harness = EngineHarness(text: "hello world")
        let id = harness.down(at: harness.point(for: .space))
        harness.move(id, by: CGVector(dx: -SpaceSession.activationDistance, dy: 0))
        #expect(harness.state.interaction.isTrackpadActive)

        harness.move(id, by: CGVector(dx: -SpaceSession.baseStep * 5, dy: 0), over: 0.5, steps: 5)
        harness.up(id)

        #expect(harness.document.before == "hello ")
        #expect(harness.document.after == "world")
        #expect(!harness.state.interaction.isTrackpadActive)
        #expect(harness.recorder.count { $0 == .cursorStep(direction: -1, byWord: false) } == 5)
    }

    @Test func longPressAlsoEngagesTrackpad() {
        let harness = EngineHarness(text: "abc")
        let id = harness.down(at: harness.point(for: .space))
        harness.wait(SpaceSession.longPressDelay + 0.01)
        #expect(harness.state.interaction.isTrackpadActive)
        harness.up(id)
        #expect(harness.text == "abc")
    }

    @Test func fasterSwipesUseShorterSteps() {
        #expect(SpaceSession.stepLength(forSpeed: 100) == SpaceSession.baseStep)
        #expect(SpaceSession.stepLength(forSpeed: 2000) < SpaceSession.baseStep / 2)
    }

    @Test func stopsAtTextEdges() {
        let harness = EngineHarness(text: "ab")
        let id = harness.down(at: harness.point(for: .space))
        harness.move(id, by: CGVector(dx: SpaceSession.activationDistance, dy: 0))
        harness.move(id, by: CGVector(dx: 60, dy: 0), over: 0.6, steps: 6)
        harness.up(id)
        #expect(harness.text == "ab")
        #expect(harness.document.after.isEmpty)
    }
}

@MainActor
@Suite("Backspace gestures")
struct BackspaceGestureTests {
    @Test func tapDeletesPreviousWord() {
        let harness = EngineHarness(text: "hello world")
        harness.tap(.backspace)
        #expect(harness.text == "hello ")
    }

    @Test func tapDeletesCharacterWhenConfigured() {
        let harness = EngineHarness(text: "hello", settings: KeyboardSettings(backspaceTapAction: .deleteCharacter))
        harness.tap(.backspace)
        #expect(harness.text == "hell")
    }

    @Test func scrubLeftDeletesAndScrubRightRestores() {
        let harness = EngineHarness(text: "typing")
        let id = harness.down(at: harness.point(for: .backspace))
        harness.move(id, by: CGVector(dx: -BackspaceSession.activationDistance, dy: 0))
        harness.move(id, by: CGVector(dx: -BackspaceSession.scrubStep * 3, dy: 0), steps: 3)
        #expect(harness.text == "typ")

        harness.move(id, by: CGVector(dx: BackspaceSession.scrubStep * 2, dy: 0), steps: 2)
        #expect(harness.text == "typin")
        harness.up(id)
        #expect(harness.text == "typin", "Releasing after a scrub does not delete again")
    }

    @Test func swipeRightUndoesWordDelete() {
        let harness = EngineHarness(text: "hello world")
        harness.tap(.backspace)
        #expect(harness.text == "hello ")

        let id = harness.down(at: harness.point(for: .backspace))
        harness.move(id, by: CGVector(dx: BackspaceSession.activationDistance, dy: 0))
        harness.move(id, by: CGVector(dx: BackspaceSession.scrubStep + 1, dy: 0))
        harness.up(id)
        #expect(harness.text == "hello world")
    }

    @Test func holdRepeatsWordDeletion() {
        let harness = EngineHarness(text: "one two three")
        let id = harness.down(at: harness.point(for: .backspace))
        harness.wait(BackspaceSession.holdDelay)
        #expect(harness.text == "one two ")
        harness.wait(BackspaceSession.wordRepeat.initial)
        #expect(harness.text == "one ")
        harness.up(id)
        harness.wait(1)
        #expect(harness.text == "one ")
    }
}

@MainActor
@Suite("Shift and layers")
struct ShiftAndLayerTests {
    @Test func slideFromShiftOntoZTypesOneCapital() {
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none))
        let id = harness.down(at: harness.point(for: .shift))
        harness.move(id, to: harness.point(for: "z"), over: 0.08)
        harness.up(id)
        #expect(harness.text == "Z")
        #expect(harness.state.shift == .off)
    }

    @Test func scrubbingShiftDeletesAndRestoresWithoutTogglingShift() {
        let harness = EngineHarness(text: "typing", traits: InputTraits(autocapitalization: .none))
        let id = harness.down(at: harness.point(for: .shift))
        harness.move(id, by: CGVector(dx: -BackspaceSession.activationDistance, dy: 0))
        harness.move(id, by: CGVector(dx: -BackspaceSession.scrubStep * 3, dy: 0), steps: 3)
        #expect(harness.text == "typ")

        harness.move(id, by: CGVector(dx: BackspaceSession.scrubStep * 2, dy: 0), steps: 2)
        #expect(harness.text == "typin")
        harness.up(id)
        #expect(harness.text == "typin")
        #expect(harness.state.shift == .off)
    }

    @Test func aRightFlickOnShiftRestoresTheLastDeletion() {
        let harness = EngineHarness(text: "hello world", traits: InputTraits(autocapitalization: .none))
        harness.tap(.backspace)
        #expect(harness.text == "hello ")

        let id = harness.down(at: harness.point(for: .shift))
        harness.move(id, by: CGVector(dx: BackspaceSession.activationDistance + 2, dy: 0))
        harness.up(id)
        #expect(harness.text == "hello world")
        #expect(harness.state.shift == .off)
    }

    @Test func scrubbingShiftDoesNotCountAsAShiftTap() {
        let harness = EngineHarness(text: "typing", traits: InputTraits(autocapitalization: .none))
        let id = harness.down(at: harness.point(for: .shift))
        harness.move(id, by: CGVector(dx: -BackspaceSession.activationDistance, dy: 0))
        harness.move(id, by: CGVector(dx: -BackspaceSession.scrubStep, dy: 0))
        harness.up(id)

        harness.tap(.shift, gap: 0.05)
        #expect(harness.state.shift == .once)
    }

    @Test func slideFromShiftTypesOneCapital() {
        let harness = EngineHarness(text: "hey ", traits: InputTraits(autocapitalization: .none))
        let id = harness.down(at: harness.point(for: .shift))
        harness.move(id, to: harness.point(for: "a"))
        harness.up(id)
        harness.type("b")
        #expect(harness.text == "hey Ab")
        #expect(harness.state.shift == .off)
    }

    @Test func doubleTapLocksCaps() {
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none))
        harness.tap(.shift, gap: 0.05)
        harness.tap(.shift)
        #expect(harness.state.shift == .locked)
        #expect(harness.recorder.events.contains(.capsLockEngaged))
        harness.type("ab")
        #expect(harness.text == "AB")
    }

    @Test func tappingShiftOffOverridesAutoCapitalization() {
        let harness = EngineHarness()
        #expect(harness.state.shift == .once)
        harness.tap(.shift, gap: 0.5)
        #expect(harness.state.shift == .off)
        harness.type("x")
        #expect(harness.text == "x")
    }

    @Test func slideFromNumbersKeyTypesSymbolAndReturns() {
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none))
        let id = harness.down(at: harness.point(for: .layerSwitch(.numbers)))
        #expect(harness.state.layer == .numbers)
        harness.move(id, to: harness.point(for: "5"))
        harness.up(id)
        #expect(harness.text == "5")
        #expect(harness.state.layer == .letters)
    }

    @Test func spaceReturnsToLettersFromNumbers() {
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none))
        harness.tap(.layerSwitch(.numbers))
        #expect(harness.state.layer == .numbers)
        harness.tap(.character("7"))
        harness.tap(.space)
        #expect(harness.text == "7 ")
        #expect(harness.state.layer == .letters)
    }

    @Test func returnKeyRespectsAutomaticEnabling() {
        let harness = EngineHarness(traits: InputTraits(enablesReturnKeyAutomatically: true))
        #expect(!harness.state.isReturnKeyEnabled)
        harness.tap(.returnKey)
        #expect(harness.text.isEmpty)
        harness.type("a")
        #expect(harness.state.isReturnKeyEnabled)
    }

    @Test func accessibilityActivationTypes() throws {
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none))
        let key = try #require(harness.engine.geometry.keys.first { $0.key.kind == .character("z") })
        harness.engine.activateKey(key.id)
        #expect(harness.text == "z")
    }
}

extension EngineHarness {
    /// Taps without advancing the clock between down and up.
    @discardableResult
    func tapDownUp(_ location: CGPoint) -> TouchID {
        let id = down(at: location)
        up(id)
        return id
    }
}
