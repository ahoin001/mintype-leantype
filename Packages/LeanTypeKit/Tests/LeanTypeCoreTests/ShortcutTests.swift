import CoreGraphics
import Foundation
import Testing
@testable import LeanTypeCore

@Suite("Hold shortcuts")
struct ShortcutTests {
    @Test func anUntouchedKeyKeepsItsAccents() {
        let accents = ["è", "é"]
        #expect(KeyShortcuts.row(for: "e", builtIn: accents, overrides: [:]) == accents)
    }

    @Test func anOverrideReplacesTheAccents() {
        let row = KeyShortcuts.row(for: "e", builtIn: ["è"], overrides: ["e": ["è", "me@example.com"]])
        #expect(row == ["è", "me@example.com"])
    }

    @Test func anEmptyOverrideClearsTheRow() {
        #expect(KeyShortcuts.row(for: "e", builtIn: ["è"], overrides: ["e": []]).isEmpty)
    }

    @Test func symbolKeysIgnoreOverrides() {
        #expect(KeyShortcuts.row(for: "0", builtIn: ["°"], overrides: ["0": ["zero"]]) == ["°"])
    }

    @Test func normalizationDropsBlanksDuplicatesAndExtras() {
        let extras = (0..<15).map { "item\($0)" }
        let row = KeyShortcuts.normalized(["  hi  ", "", "hi"] + extras)
        #expect(row.count == KeyShortcuts.maxCount)
        #expect(row[0] == "hi")
        #expect(row[1] == "item0")
    }

    @Test func normalizationClipsLength() {
        let row = KeyShortcuts.normalized([String(repeating: "a", count: 80)])
        #expect(row == [String(repeating: "a", count: KeyShortcuts.maxLength)])
    }

    @Test func missingShortcutsDecodeAsEmpty() throws {
        let settings = try JSONDecoder().decode(KeyboardSettings.self, from: Data(#"{"theme":"mint"}"#.utf8))
        #expect(settings.keyShortcuts.isEmpty)
    }
}

@Suite("Callout cell widths")
struct CalloutWidthTests {
    @Test func singleCharactersStayKeyWidth() {
        let widths = CalloutGeometry.cellWidths(for: ["è", "é"], keyWidth: 40, available: 400)
        #expect(widths == [40, 40])
    }

    @Test func aLongStringGrowsAndStaysWithinFourKeys() {
        let widths = CalloutGeometry.cellWidths(for: ["me@example.com"], keyWidth: 40, available: 400)
        #expect(widths[0] > 40)
        #expect(widths[0] <= 160)
    }

    @Test func anOverflowingRowScalesToTheKeyboard() {
        let options = (0..<8).map { _ in "me@example.com" }
        let available: CGFloat = 300
        let widths = CalloutGeometry.cellWidths(for: options, keyWidth: 40, available: available)
        let padding = 2 * CalloutGeometry.bubblePadding
        #expect(widths.reduce(0, +) <= available - padding + 0.01)
    }
}

@MainActor
@Suite("Hold shortcut typing")
struct ShortcutTypingTests {
    @Test func holdingEInsertsTheEmailAndSpaceLeavesIt() {
        var settings = KeyboardSettings()
        let accents = LayoutProvider.builtInAlternates(for: "e")
        settings.keyShortcuts = ["e": accents + ["me@example.com"]]
        let harness = EngineHarness(settings: settings, language: LanguageModel(lexicon: TestLexicon.shared))
        let id = harness.down(at: harness.point(for: "e"))
        harness.wait(CharacterTapSession.longPressDelay + 0.05)

        guard case let .alternates(options, _) = harness.state.interaction.callout?.content,
              let emailIndex = options.firstIndex(of: "me@example.com"),
              let frames = harness.state.interaction.callout?.layout.optionFrames,
              frames.indices.contains(emailIndex)
        else {
            Issue.record("Expected the email on the hold row")
            return
        }

        let target = CGPoint(x: frames[emailIndex].midX, y: harness.point(for: "e").y)
        harness.move(id, to: target)
        harness.up(id)

        #expect(harness.text == "me@example.com")
        #expect(harness.state.candidates.isEmpty)
        harness.tap(.space)
        #expect(harness.text == "me@example.com ")
    }
}
