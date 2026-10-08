import CoreGraphics
import Foundation
import Testing
@testable import LeanTypeCore

@Suite("Lexicon format")
struct LexiconFormatTests {
    private static func mapped(_ entries: [LexiconFormat.Entry]) throws -> MappedLexicon {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lexicon-\(UUID().uuidString).bin")
        try LexiconFormat.write(entries).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // The mapping stays valid after the file is unlinked.
        return try MappedLexicon(url: url)
    }

    @Test func roundTripsWordsDisplaysAndFrequencies() throws {
        let lexicon = try Self.mapped([
            .init(display: "the", count: 1000),
            .init(display: "then", count: 300),
            .init(display: "don't", count: 200),
            .init(display: "café", count: 20),
            .init(display: "I", count: 900),
        ])
        #expect(lexicon.wordCount == 5)
        #expect(lexicon.contains("dont"))
        #expect(lexicon.contains("Cafe"))
        #expect(!lexicon.contains("thee"))

        let dont = try #require(lexicon.indices(ofKey: LexiconKey.make("dont")).first)
        #expect(lexicon.display(at: dont) == "don't")
        let the = try #require(lexicon.indices(ofKey: LexiconKey.make("the")).first)
        #expect(lexicon.frequency(at: the) == 255)
        #expect(lexicon.display(at: the) == "the")
    }

    @Test func completionsAreByFrequency() throws {
        let lexicon = try Self.mapped([
            .init(display: "the", count: 1000),
            .init(display: "then", count: 300),
            .init(display: "there", count: 500),
            .init(display: "they", count: 800),
            .init(display: "a", count: 10),
        ])
        let completions = lexicon.completions(prefix: LexiconKey.make("the"), limit: 3).map(lexicon.display(at:))
        #expect(completions == ["the", "they", "there"])
    }

    @Test func bucketsGroupByFirstAndLastLetter() throws {
        let lexicon = try Self.mapped([
            .init(display: "hello", count: 50),
            .init(display: "hero", count: 80),
            .init(display: "help", count: 60),
        ])
        let bucket = lexicon.bucket(first: UInt8(ascii: "h"), last: UInt8(ascii: "o")).map { lexicon.display(at: Int($0)) }
        #expect(bucket == ["hero", "hello"])
    }

    @Test func rejectsGarbage() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).bin")
        try? Data(repeating: 7, count: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: LexiconFormat.Error.badMagic) { try MappedLexicon(url: url) }
    }
}

@Suite("Bundled lexicon")
struct BundledLexiconTests {
    private var lexicon: MappedLexicon { TestLexicon.shared }

    @Test func hasEverydayEnglish() {
        #expect(lexicon.wordCount > 30000)
        for word in ["the", "hello", "keyboard", "because", "don't", "I'm", "you're", "o'clock"] {
            #expect(lexicon.contains(word), "\(word)")
        }
    }

    @Test func restoresContractionsAndCapitalI() throws {
        let dont = try #require(lexicon.indices(ofKey: LexiconKey.make("dont")).first)
        #expect(lexicon.display(at: dont) == "don't")
        let i = try #require(lexicon.indices(ofKey: LexiconKey.make("i")).first)
        #expect(lexicon.display(at: i) == "I")
    }

    @Test func excludesTokenizerFragments() {
        #expect(!lexicon.contains("didn"), "Contraction halves are folded back into whole words")
    }
}

@MainActor
@Suite("Tap autocorrect")
struct TapCorrectorTests {
    private func analyze(_ word: String, personal: Set<String> = []) -> WordAnalysis {
        TapCorrector(lexicon: TestLexicon.shared, personal: []) { personal.contains($0.lowercased()) }
            .analyze(word, touches: nil, layout: TestLayout.shared, completionLimit: 2)
    }

    @Test(arguments: [
        ("teh", "the"),
        ("Teh", "The"),
        ("dont", "don't"),
        ("im", "I'm"),
        ("i", "I"),
        ("becuase", "because"),
        ("keybaord", "keyboard"),
        ("helo", "hello"),
    ])
    func correctsCommonSlips(typed: String, expected: String) {
        #expect(analyze(typed).correction == expected)
    }

    @Test(arguments: ["hello", "The", "keyboard", "don't", "I"])
    func leavesKnownWordsAlone(word: String) {
        let analysis = analyze(word)
        #expect(analysis.isKnown)
        #expect(analysis.correction == nil)
    }

    @Test func respectsPersonalWords() {
        let analysis = analyze("Zyxt", personal: ["zyxt"])
        #expect(analysis.isKnown)
        #expect(analysis.correction == nil)
    }

    @Test func doesNotGuessWildly() {
        #expect(analyze("qzvbxk").correction == nil)
        #expect(analyze("ab12").correction == nil)
    }

    @Test func offersCompletions() {
        #expect(analyze("keyb").completions.contains("keyboard"))
    }

    @Test func touchLocationsDecideBetweenNeighbors() throws {
        let layout = try #require(TestLayout.shared)
        // "tge": the g was touched right at the edge with h, so "the" is a natural reading.
        let t = layout.center(of: UInt8(ascii: "t"))
        let g = layout.center(of: UInt8(ascii: "g"))
        let h = layout.center(of: UInt8(ascii: "h"))
        let edge = CGPoint(x: (g.x + h.x) / 2 + 1, y: g.y)
        let e = layout.center(of: UInt8(ascii: "e"))
        let analysis = TapCorrector(lexicon: TestLexicon.shared, personal: []) { _ in false }
            .analyze("tge", touches: [t, edge, e], layout: layout, completionLimit: 0)
        #expect(analysis.correction == "the")
    }
}

@Suite("Personal lexicon")
struct PersonalLexiconTests {
    @Test func learnsAndSuggestsAfterRepeatedUse() {
        var personal = PersonalLexicon()
        let date = Date()
        personal.learn("Zorbly", at: date)
        #expect(personal.contains("zorbly"))
        #expect(personal.entries(logCountRange: 0...10).isEmpty, "One use isn't enough to suggest")
        personal.learn("Zorbly", at: date)
        #expect(personal.entries(logCountRange: 0...10).map(\.display) == ["Zorbly"])
    }

    @Test func evictsLeastRecentlyUsed() {
        var personal = PersonalLexicon()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<PersonalLexicon.capacity {
            personal.learn("word\(index)", at: start.addingTimeInterval(Double(index)))
        }
        personal.learn("word0", at: start.addingTimeInterval(10_000))
        personal.learn("fresh", at: start.addingTimeInterval(10_001))
        #expect(personal.learnedWords.count == PersonalLexicon.capacity)
        #expect(personal.contains("word0"), "Recently used words survive")
        #expect(!personal.contains("word1"), "The stalest word makes room")
        #expect(personal.contains("fresh"))
    }

    @Test func rememberSuggestsOnTheFirstPinAndForgetDropsOnlyThatWord() {
        var personal = PersonalLexicon()
        personal.learn("kept", at: Date())
        let pinned = personal.remember("zorbly", at: Date())
        #expect(pinned)
        #expect(personal.uses(of: "zorbly") == PersonalLexicon.usesBeforeSuggesting)
        let again = personal.remember("zorbly", at: Date())
        #expect(again)
        #expect(personal.uses(of: "zorbly") == PersonalLexicon.usesBeforeSuggesting + 1)
        #expect(personal.entries(logCountRange: 0...10).map(\.display) == ["zorbly"])
        let forgotten = personal.forget("Zorbly")
        #expect(forgotten)
        #expect(!personal.contains("zorbly"))
        #expect(personal.contains("kept"))
    }
}

@MainActor
@Suite("Autocorrect and suggestions in the engine")
struct EngineLanguageTests {
    private func makeHarness(text: String = "", settings: KeyboardSettings = .default) -> (EngineHarness, MemoryLearnedWordsStore) {
        let store = MemoryLearnedWordsStore()
        let language = LanguageModel(lexicon: TestLexicon.shared, store: store)
        language.isLearningEnabled = true
        let harness = EngineHarness(
            text: text,
            settings: settings,
            traits: InputTraits(autocapitalization: .none),
            language: language
        )
        return (harness, store)
    }

    @Test func spaceAppliesCorrection() {
        let (harness, _) = makeHarness()
        harness.type("teh ")
        #expect(harness.text == "the ")
        #expect(harness.recorder.events.contains(.correctionApplied))
    }

    @Test func backspaceRevertsCorrectionAndTheWordSticks() {
        let (harness, _) = makeHarness()
        harness.type("teh ")
        harness.tap(.backspace)
        #expect(harness.text == "teh")
        #expect(harness.recorder.events.contains(.correctionReverted))
        harness.type(" ")
        #expect(harness.text == "teh ", "A reverted word isn't corrected again")
    }

    @Test func keptRareWordsStopBeingCorrected() {
        let (harness, _) = makeHarness()
        harness.type("helo ")
        #expect(harness.text == "hello ")
        harness.tap(.backspace)
        harness.type(" helo ")
        #expect(harness.text == "helo helo ", "Once kept, a rare dictionary word is the user's word")
    }

    @Test func autocorrectCanBeTurnedOff() {
        let (harness, _) = makeHarness(settings: KeyboardSettings(autocorrectEnabled: false))
        harness.type("teh ")
        #expect(harness.text == "teh ")
    }

    @Test func punctuationEndsAndCorrectsTheWord() {
        let (harness, _) = makeHarness()
        harness.type("dont")
        let id = harness.down(at: harness.point(for: .layerSwitch(.numbers)))
        harness.move(id, to: harness.point(for: "."))
        harness.up(id)
        #expect(harness.text == "don't. ")
    }

    @Test func suggestionStripShowsTypedCorrectionAndCompletions() {
        let (harness, _) = makeHarness()
        harness.type("teh")
        let candidates = harness.state.candidates
        #expect(candidates.candidates.first == Candidate("teh", role: .typed))
        #expect(candidates.highlightedIndex.map { candidates.candidates[$0].text } == "the")
    }

    @Test func acceptingACompletionTypesItWithASpace() throws {
        let (harness, _) = makeHarness()
        harness.type("keyb")
        let index = try #require(harness.state.candidates.candidates.firstIndex { $0.text == "keyboard" })
        harness.engine.acceptCandidate(index)
        #expect(harness.text == "keyboard ")
        #expect(harness.recorder.events.contains(.wordCommitted(.suggestion)))
        #expect(harness.state.candidates.candidates.first == Candidate("keyboard", role: .settled))
        #expect(harness.state.candidates.highlightedIndex == nil)
        harness.engine.acceptCandidate(0)
        #expect(harness.text == "keyboard ")
    }

    @Test func aFinishedWordStaysOnTheStripUntilTheNextLetter() {
        let (harness, _) = makeHarness()
        harness.type("hello ")
        #expect(harness.state.candidates.candidates == [Candidate("hello", role: .settled)])
        #expect(harness.state.candidates.highlightedIndex == nil)
        harness.engine.acceptCandidate(0)
        #expect(harness.text == "hello ")
        harness.tap(.character("a"))
        #expect(!harness.state.candidates.candidates.contains { $0.role == .settled })
        #expect(harness.text == "hello a")
    }

    @Test func keepingTheTypedWordSkipsCorrection() {
        let (harness, _) = makeHarness()
        harness.type("teh")
        harness.engine.acceptCandidate(0)
        #expect(harness.text == "teh ")
    }

    @Test func correctedWordOffersRevert() throws {
        let (harness, _) = makeHarness()
        harness.type("teh ")
        let revert = try #require(harness.state.candidates.candidates.first)
        #expect(revert == Candidate("teh", role: .revert))
        harness.engine.acceptCandidate(0)
        #expect(harness.text == "teh ")
    }

    @Test func unknownWordsAreLearned() {
        let (harness, _) = makeHarness()
        harness.type("zorbly zorbly ")
        #expect(harness.engine.language?.isKnown("zorbly") == true)
        harness.type("zorbl")
        #expect(harness.state.candidates.candidates.contains { $0.text == "zorbly" })
    }

    @Test func rememberingTheTypedWordStopsTheCorrection() {
        let (harness, store) = makeHarness()
        harness.type("teh")
        harness.engine.rememberWord("teh")
        #expect(store.load().first?.uses == PersonalLexicon.usesBeforeSuggesting)
        harness.tap(.space)
        #expect(harness.text == "teh ")
    }

    @Test func rememberingAWordSuggestsItImmediately() {
        let (harness, _) = makeHarness()
        harness.engine.rememberWord("zorbly")
        harness.type("zorbl")
        #expect(harness.state.candidates.candidates.contains { $0.text == "zorbly" })
    }

    @Test func forgettingAWordRemovesItFromSuggestions() {
        let (harness, store) = makeHarness()
        harness.type("zorbly zorbly ")
        harness.engine.forgetWord("zorbly")
        #expect(store.load().isEmpty)
        harness.type("zorbl")
        #expect(!harness.state.candidates.candidates.contains { $0.text == "zorbly" })
    }

    @Test func learnedWordsPersistThroughTheStore() {
        let (harness, store) = makeHarness()
        harness.type("zorbly ")
        harness.engine.language?.save()
        #expect(store.load().map(\.word) == ["zorbly"])
    }

    @Test func banningAWordRemovesItUntilItIsRemembered() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.isLearningEnabled = true
        let ranked = DecodeResult(readings: [
            .init(word: "there", score: -1),
            .init(word: "three", score: -1.2),
        ])
        language.noteRejection(preferred: "three", rejected: "there")
        let swapped = language.applyingRejections(to: ranked)
        #expect(!language.isBlocked("there"))
        #expect(swapped.words.contains("there"))

        #expect(language.ban("there"))
        let banned = language.applyingBlocks(to: ranked)
        #expect(banned.words == ["three"])
        #expect(language.memory(of: "there") == .blocked)

        #expect(language.remember("there"))
        #expect(!language.isBlocked("there"))
        #expect(language.applyingBlocks(to: ranked).words.first == "there")
    }

    @Test func restoringABannedWordFromTheStorePutsItBack() {
        let store = MemoryBlocklistStore()
        let language = LanguageModel(lexicon: TestLexicon.shared, blocklist: store)
        #expect(language.ban("there"))
        store.save(store.load().filter { $0.word != "there" })
        language.reloadLearnedWords()
        #expect(!language.isBlocked("there"))
    }

    @Test func passwordFieldsGetNoLanguageFeatures() {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        let harness = EngineHarness(traits: InputTraits(autocapitalization: .none, allowsAutocorrection: false), language: language)
        harness.type("teh ")
        #expect(harness.text == "teh ")
        #expect(harness.state.candidates.isEmpty)
    }
}

/// Learned words kept in memory for tests.
final class MemoryLearnedWordsStore: LearnedWordsStore, @unchecked Sendable {
    // @unchecked: only touched from the main actor in tests.
    private var words: [LearnedWord] = []

    func load() -> [LearnedWord] { words }
    func save(_ words: [LearnedWord]) { self.words = words }
    func clear() { words = [] }
}

/// Banned spellings kept in memory for tests.
final class MemoryBlocklistStore: BlocklistStore, @unchecked Sendable {
    private var entries: [BlockedSpelling] = []

    func load() -> [BlockedSpelling] { entries }
    func save(_ entries: [BlockedSpelling]) { self.entries = entries }
}

/// The letters layout of a standard iPhone-width keyboard.
@MainActor
enum TestLayout {
    static let shared: LetterLayout? = {
        let metrics = KeyboardMetrics.portrait
        let layout = LayoutProvider.layout(for: .letters, context: LayoutContext(variant: .standard, showsNextKeyboardKey: true))
        let geometry = KeyboardGeometry(layout: layout, size: CGSize(width: 390, height: metrics.keyAreaHeight(rowCount: 4)), metrics: metrics)
        return LetterLayout(geometry: geometry)
    }()
}
