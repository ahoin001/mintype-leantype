import Testing
@testable import LeanTypeCore

@Suite("Emoji")
struct EmojiCatalogTests {
    @Test func everyPageIsThreeFullRowsOfSingleEmoji() {
        for page in EmojiCategory.allCases {
            let symbols = EmojiCatalog.symbols(on: page)
            #expect(symbols.count == EmojiCatalog.rowCount * EmojiCatalog.perRow)
            #expect(Set(symbols).count == symbols.count)
            #expect(symbols.allSatisfy { $0.count == 1 })
            let layout = LayoutProvider.layout(
                for: .emoji,
                context: LayoutContext(emojiPage: page)
            )
            for row in layout.rows {
                #expect(abs(row.totalUnits - 10) < 0.001)
            }
        }
    }
}

@MainActor
@Suite("Emoji keyboard")
struct EmojiKeyboardTests {
    private static let plain = InputTraits(autocapitalization: .none)

    @Test func theSmileyKeyOpensEmojiAndATapInsertsIt() {
        let harness = EngineHarness(traits: Self.plain)
        harness.type("hi")
        harness.tap(.emoji)
        #expect(harness.state.layer == .emoji)
        #expect(harness.text == "hi")
        let face = EmojiCatalog.symbols(on: .smileys)[0]
        harness.tap(.character(face))
        #expect(harness.text == "hi \(face)")
        harness.tap(.layerSwitch(.letters))
        #expect(harness.state.layer == .letters)
    }

    @Test func categoryKeysChangeThePage() {
        let harness = EngineHarness(traits: Self.plain)
        harness.tap(.emoji)
        harness.tap(.emojiCategory(.gestures))
        #expect(harness.state.emojiPage == .gestures)
        let wave = EmojiCatalog.symbols(on: .gestures)[0]
        #expect(harness.engine.geometry.keys.contains { $0.key.kind == .character(wave) })
        harness.tap(.character(wave))
        #expect(harness.text == wave)
    }
}
