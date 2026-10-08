import Foundation
import Testing
@testable import LeanTypeCore

@Suite("Word boundaries")
struct WordBoundaryTests {
    @Test(arguments: [
        ("hello world", 5),
        ("hello world ", 6),
        ("hello world   ", 8),
        ("hello\n", 1),
        ("hello\n  ", 2),
        ("wait...", 3),
        ("don't", 5),
        ("hi 👋🏽", 1),
        ("abc123", 6),
        ("", 1),
        ("   ", 3),
    ])
    func wordDeletionLength(text: String, expected: Int) {
        #expect(TextBoundary.wordDeletionLength(before: text) == expected)
    }

    @Test func nilContextDeletesOne() {
        #expect(TextBoundary.wordDeletionLength(before: nil) == 1)
    }
}

@Suite("Auto-capitalization")
struct AutoCapitalizationTests {
    @Test(arguments: [
        ("", true),
        ("Hello. ", true),
        ("Hello.", false),
        ("Hello ", false),
        ("Really?! ", true),
        ("He said \"hi.\" ", true),
        ("Line\n", true),
        ("Done… ", true),
    ])
    func sentences(text: String, expected: Bool) {
        #expect(TextBoundary.shouldAutoCapitalize(before: text, mode: .sentences) == expected)
    }

    @Test func wordsMode() {
        #expect(TextBoundary.shouldAutoCapitalize(before: "new ", mode: .words))
        #expect(!TextBoundary.shouldAutoCapitalize(before: "new", mode: .words))
    }

    @Test func noneAndAll() {
        #expect(!TextBoundary.shouldAutoCapitalize(before: "", mode: .none))
        #expect(TextBoundary.shouldAutoCapitalize(before: "abc", mode: .allCharacters))
    }

    @Test func doubleSpacePeriodEligibility() {
        #expect(TextBoundary.canApplyDoubleSpacePeriod(before: "word "))
        #expect(!TextBoundary.canApplyDoubleSpacePeriod(before: "word  "))
        #expect(!TextBoundary.canApplyDoubleSpacePeriod(before: "word. "))
        #expect(!TextBoundary.canApplyDoubleSpacePeriod(before: " "))
    }
}

@MainActor
@Suite("Text editor")
struct TextEditorTests {
    @Test func deleteWordThenRestoreWholeWord() {
        let document = InMemoryTextDocument(text: "hello brave world")
        let editor = TextEditor(document: document)

        #expect(editor.deleteWord() == "world")
        #expect(document.text == "hello brave ")
        #expect(editor.restoreLastDeletion() == "world")
        #expect(document.text == "hello brave world")
    }

    @Test func deleteSentenceKeepsPreviousSentence() {
        let document = InMemoryTextDocument(text: "First one. Second one here")
        let editor = TextEditor(document: document)
        #expect(editor.deleteSentence() == "Second one here")
        #expect(document.text == "First one. ")
    }

    @Test func swipedWordGetsSpacingAndUndoesAsUnit() {
        let document = InMemoryTextDocument(text: "say")
        let editor = TextEditor(document: document)
        editor.commitWord("hello")
        #expect(document.text == "say hello ")
        #expect(editor.replaceRecentCommitWord(with: "jello"))
        #expect(document.text == "say jello ")
        #expect(editor.undoRecentCommit()?.word == "jello")
        #expect(document.text == "say")
        #expect(editor.restoreLastDeletion() == " jello ")
    }

    @Test func correctionRevertsToTypedWord() {
        let document = InMemoryTextDocument(text: "see teh")
        let editor = TextEditor(document: document)
        #expect(editor.replaceCurrentWord(with: "the", kind: .corrected))
        #expect(document.text == "see the ")
        #expect(editor.recentCommit?.original == "teh")
        #expect(editor.undoRecentCommit() != nil)
        #expect(document.text == "see teh")
        #expect(editor.recentCommit == nil)
    }

    @Test func punctuationHopsOverKeyboardSpace() {
        let document = InMemoryTextDocument(text: "done")
        let editor = TextEditor(document: document)
        editor.insertSpace()
        #expect(editor.insertPunctuation(".", hoppingSpace: true))
        #expect(document.text == "done. ")
    }

    @Test func punctuationDoesNotHopOverUsersOwnSpace() {
        let document = InMemoryTextDocument(text: "done ")
        let editor = TextEditor(document: document)
        #expect(!editor.insertPunctuation(".", hoppingSpace: true))
        #expect(document.text == "done .")
    }

    @Test func cursorMovesByWord() {
        let document = InMemoryTextDocument(before: "one two", after: " three")
        let editor = TextEditor(document: document)
        #expect(editor.moveCursorByWord(-1))
        #expect(document.before == "one ")
        #expect(editor.moveCursorByWord(1))
        #expect(editor.moveCursorByWord(1))
        #expect(document.before == "one two three")
    }

    @Test func scrubDeleteThenRestoreCharacterByCharacter() {
        let document = InMemoryTextDocument(text: "typing")
        let editor = TextEditor(document: document)

        for _ in 0..<3 { editor.deleteCharacter() }
        #expect(document.text == "typ")
        #expect(editor.restoreCharacter())
        #expect(document.text == "typi")
        #expect(editor.restoreCharacter())
        #expect(editor.restoreCharacter())
        #expect(document.text == "typing")
        #expect(!editor.restoreCharacter())
    }

    @Test func restoreWalksBackThroughEarlierWordDeletes() {
        let document = InMemoryTextDocument(text: "one two")
        let editor = TextEditor(document: document)

        editor.deleteWord()
        editor.deleteWord()
        #expect(document.text == "")
        #expect(editor.restoreCharacter())
        #expect(document.text == "o")
        #expect(editor.restoreLastDeletion() != nil)
        #expect(document.text == "one ")
        #expect(editor.restoreLastDeletion() != nil)
        #expect(document.text == "one two")
    }

    @Test func typingClearsDeletionHistory() {
        let document = InMemoryTextDocument(text: "abc")
        let editor = TextEditor(document: document)

        editor.deleteCharacter()
        editor.insert("x")
        #expect(!editor.restoreCharacter())
        #expect(document.text == "abx")
    }

    @Test func outsideEditsInvalidateHistory() {
        let document = InMemoryTextDocument(text: "abc")
        let editor = TextEditor(document: document)

        editor.deleteWord()
        document.insert("pasted")
        #expect(editor.restoreLastDeletion() == nil)
    }

    @Test func cursorMovesByGraphemeAndStopsAtEdges() {
        let document = InMemoryTextDocument(before: "a👋🏽", after: "b")
        let editor = TextEditor(document: document)

        #expect(editor.moveCursor(by: -1))
        #expect(document.before == "a")
        #expect(document.after == "👋🏽b")
        #expect(editor.moveCursor(by: -1))
        #expect(!editor.moveCursor(by: -1))
        #expect(editor.moveCursor(by: 1))
        #expect(document.before == "a")
    }

    @Test func doubleSpacePeriod() {
        let document = InMemoryTextDocument(text: "nice ")
        let editor = TextEditor(document: document)
        #expect(editor.applyDoubleSpacePeriod())
        #expect(document.text == "nice. ")
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func roundTrips() throws {
        let settings = KeyboardSettings(theme: "mint", backspaceTapAction: .deleteCharacter, hapticsEnabled: false)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(KeyboardSettings.self, from: data) == settings)
    }

    @Test func missingAndInvalidFieldsFallBackToDefaults() throws {
        let json = #"{"theme":"peach","backspaceTapAction":"somethingNew","futureOption":true}"#
        let settings = try JSONDecoder().decode(KeyboardSettings.self, from: Data(json.utf8))
        #expect(settings.theme == "peach")
        #expect(settings.backspaceTapAction == .deleteWord)
        #expect(settings.hapticsEnabled)
        #expect(settings.schemaVersion == KeyboardSettings.currentSchemaVersion)
    }

    @Test func versionOneSettingsGainPhaseTwoDefaults() throws {
        let json = #"{"schemaVersion":1,"theme":"mint","hapticsEnabled":false}"#
        let settings = try JSONDecoder().decode(KeyboardSettings.self, from: Data(json.utf8))
        #expect(settings.theme == "mint")
        #expect(!settings.hapticsEnabled)
        #expect(settings.typingMode == .swipe)
        #expect(settings.extendFinishedWords)
        #expect(settings.effects == .default)
        #expect(settings.height == .regular)
    }

    @Test func effectsDecodeLeniently() throws {
        let json = #"{"effects":{"intensity":"party","trailStyle":"unknownStyle"}}"#
        let settings = try JSONDecoder().decode(KeyboardSettings.self, from: Data(json.utf8))
        #expect(settings.effects.intensity == .party)
        #expect(settings.effects.trailStyle == .lantern)
        #expect(settings.effects.celebrateMilestones)
    }

    @Test func savedTrailNamesLoadAsTheNewLooks() throws {
        let theme = #"{"effects":{"trailStyle":"theme"}}"#
        let brush = #"{"effects":{"trailStyle":"brush"}}"#
        let prism = #"{"effects":{"trailStyle":"prism"}}"#
        #expect(try JSONDecoder().decode(KeyboardSettings.self, from: Data(theme.utf8)).effects.trailStyle == .lantern)
        #expect(try JSONDecoder().decode(KeyboardSettings.self, from: Data(brush.utf8)).effects.trailStyle == .silk)
        #expect(try JSONDecoder().decode(KeyboardSettings.self, from: Data(prism.utf8)).effects.trailStyle == .prism)
    }
}
