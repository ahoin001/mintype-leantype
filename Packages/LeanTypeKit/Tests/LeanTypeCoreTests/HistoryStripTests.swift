import Foundation
import Testing
@testable import LeanTypeCore

@Suite @MainActor struct HistoryStripTests {
    private func harness(_ text: String = "") -> EngineHarness {
        let language = LanguageModel(lexicon: TestLexicon.shared)
        language.isLearningEnabled = true
        return EngineHarness(
            text: text,
            traits: InputTraits(autocapitalization: .none),
            language: language
        )
    }

    @Test func theRingDropsWhenTheFieldNoLongerMatches() {
        let harness = harness()
        harness.type("one two ")
        harness.document.replaceAll(with: "nope")
        harness.engine.documentDidChange()
        harness.engine.performStripAction(.replaceHistory(entry: 0, text: "gone"))
        #expect(harness.text == "nope")
    }

    @Test func replacingAnEarlierWordKeepsTheCaretAndTheSpace() {
        let harness = harness()
        harness.type("hello world ")
        harness.engine.performStripAction(.replaceHistory(entry: 0, text: "hi"))
        #expect(harness.text == "hi world ")
        #expect(harness.document.after.isEmpty)
    }

    @Test func theAndNAreBothOfferings() {
        let cuts = HistoryRanking.segmentations(of: "then", known: { ["the", "then", "he"].contains($0) })
        #expect(cuts.contains("the n"))
    }

    @Test func itsStaysAndTheContractionIsAChip() {
        let entry = HistoryEntry(
            text: "its",
            readings: [HistoryReading(word: "its", score: 1)],
            aimed: "its",
            unsure: false,
            trailing: " ",
            startsSentence: false
        )
        let words = HistoryRanking.alternatives(
            for: entry,
            previous: nil,
            next: nil,
            known: { _ in true },
            pair: { _, _ in 0 }
        )
        #expect(words.first == "its")
        #expect(words.contains("it's"))

        let harness = harness()
        harness.type("its ")
        #expect(harness.text == "its ")
    }

    @Test func mergeAndSplitRewriteTheWords() {
        let merged = harness()
        merged.type("in to ")
        merged.engine.performStripAction(.merge(entry: 0))
        #expect(merged.text == "into ")

        let split = harness()
        split.type("then ")
        split.engine.performStripAction(.replaceHistory(entry: 0, text: "the n"))
        #expect(split.text == "the n ")
    }

    @Test func theCalculatorAndASnippet() {
        #expect(ExpressionValue.result(of: "12*7") == "84")
        #expect(ExpressionValue.result(of: "(2+3)*4") == "20")
        #expect(SnippetBook.bundled.first?.expansion == "on my way")

        let harness = harness()
        harness.type("omw ")
        let chip = harness.state.candidates.candidates.first { $0.text == "on my way" }
        #expect(chip != nil)
        if let index = harness.state.candidates.candidates.firstIndex(where: { $0.text == "on my way" }) {
            harness.engine.acceptCandidate(index)
        }
        #expect(harness.text == "on my way ")
    }

    @Test func undoRestoresThePreviousText() {
        let harness = harness()
        harness.type("hello world ")
        harness.engine.performStripAction(.replaceHistory(entry: 0, text: "hi"))
        #expect(harness.text == "hi world ")
        harness.engine.performStripAction(.undoEdit)
        #expect(harness.text == "hello world ")
    }

    @Test func aTentativeRowIgnoresAHistoryTap() {
        let tentative = CandidateState([Candidate("the", role: .history, action: .openHistory(0))], isTentative: true, isHistory: true)
        #expect(StripMotion.ignoresHistoryTap(isTentative: tentative.isTentative))
        #expect(!tentative.allowsHistoryTap)
        let idle = CandidateState([Candidate("the", role: .history)], isHistory: true)
        #expect(idle.allowsHistoryTap)
    }

    @Test func reduceMotionFadesInsteadOfFlying() {
        #expect(StripMotion.fadesInsteadOfTraveling(reduceMotion: true))
        #expect(!StripMotion.fadesInsteadOfTraveling(reduceMotion: false))
    }

    @Test func theEditLogUsesTheInjectedDuration() {
        let record = HistoryEditLog.record(elapsed: 0.004)
        #expect(record.milliseconds == 4)
    }

    @Test func anIdleFieldStillListsTheWordsAlreadyThere() {
        let harness = harness("one two three ")
        let words = harness.state.candidates.candidates.map(\.text)
        #expect(words == ["one", "two", "three"])
        harness.engine.acceptCandidate(0)
        #expect(harness.text == "one two three ")
    }
}
