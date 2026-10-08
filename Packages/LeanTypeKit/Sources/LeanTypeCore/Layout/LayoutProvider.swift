import CoreGraphics

/// Everything outside the layer itself that changes which keys appear.
public struct LayoutContext: Hashable, Sendable {
    public var variant: KeyboardVariant
    /// Mirrors `UIInputViewController.needsInputModeSwitchKey`.
    public var showsNextKeyboardKey: Bool
    /// Which emoji set to show when the layer is `.emoji`.
    public var emojiPage: EmojiCategory

    public init(
        variant: KeyboardVariant = .standard,
        showsNextKeyboardKey: Bool = true,
        emojiPage: EmojiCategory = .smileys
    ) {
        self.variant = variant
        self.showsNextKeyboardKey = showsNextKeyboardKey
        self.emojiPage = emojiPage
    }
}

/// Builds the English (US) layouts. Each row sums to ten units so keys line up column-wise.
public enum LayoutProvider {
    static let rowUnits: CGFloat = 10

    public static func layout(for layer: KeyboardLayer, context: LayoutContext) -> KeyboardLayout {
        switch layer {
        case .letters: letters(context)
        case .numbers: numbers(context)
        case .symbols: symbols(context)
        case .emoji: emoji(context)
        }
    }

    // MARK: - Layers

    private static func letters(_ context: LayoutContext) -> KeyboardLayout {
        let layer = KeyboardLayer.letters
        let top = "qwertyuiop".map { characterKey(String($0), layer) }
        let middle = "asdfghjkl".map { characterKey(String($0), layer) }
        let bottom = "zxcvbnm".map { characterKey(String($0), layer) }

        return KeyboardLayout(layer: layer, rows: [
            KeyRow(keys: top),
            KeyRow(keys: middle, insetUnits: 1),
            KeyRow(keys: [.function(.shift, name: "shift", on: layer, width: 1.5)]
                + bottom
                + [.function(.backspace, name: "backspace", on: layer, width: 1.5)]),
            bottomRow(for: layer, context: context),
        ])
    }

    private static func numbers(_ context: LayoutContext) -> KeyboardLayout {
        let layer = KeyboardLayer.numbers
        return KeyboardLayout(layer: layer, rows: [
            KeyRow(keys: "1234567890".map { characterKey(String($0), layer) }),
            KeyRow(keys: ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map { characterKey($0, layer) }),
            punctuationRow(for: layer, switchTo: .symbols, switchName: "toSymbols"),
            bottomRow(for: layer, context: context),
        ])
    }

    private static func symbols(_ context: LayoutContext) -> KeyboardLayout {
        let layer = KeyboardLayer.symbols
        return KeyboardLayout(layer: layer, rows: [
            KeyRow(keys: ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { characterKey($0, layer) }),
            KeyRow(keys: ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map { characterKey($0, layer) }),
            punctuationRow(for: layer, switchTo: .numbers, switchName: "toNumbers"),
            bottomRow(for: layer, context: context),
        ])
    }

    private static func emoji(_ context: LayoutContext) -> KeyboardLayout {
        let layer = KeyboardLayer.emoji
        let symbols = EmojiCatalog.symbols(on: context.emojiPage)
        let rowCount = 3
        let perRow = symbols.count / rowCount
        let rows = (0..<rowCount).map { index -> KeyRow in
            let slice = symbols[index * perRow..<(index + 1) * perRow]
            let width = rowUnits / CGFloat(slice.count)
            return KeyRow(keys: slice.map { characterKey($0, layer, width: width) })
        }
        return KeyboardLayout(layer: layer, rows: rows + [emojiBottomRow(context)])
    }

    private static func emojiBottomRow(_ context: LayoutContext) -> KeyRow {
        let layer = KeyboardLayer.emoji
        var side: [KeySpec] = [.function(.layerSwitch(.letters), name: "bottomSwitch", on: layer, width: 1.25)]
        if context.showsNextKeyboardKey {
            side.append(.function(.nextKeyboard, name: "nextKeyboard", on: layer, width: 1.25))
        }
        let delete = KeySpec.function(.backspace, name: "backspace", on: layer, width: 1.5)
        let categories = EmojiCategory.allCases
        let used = (side + [delete]).reduce(0) { $0 + $1.widthUnits }
        let width = (rowUnits - used) / CGFloat(categories.count)
        let pages = categories.map { category in
            KeySpec.function(.emojiCategory(category), name: category.rawValue, on: layer, width: width)
        }
        return KeyRow(keys: side + pages + [delete])
    }

    // MARK: - Shared rows

    private static func punctuationRow(
        for layer: KeyboardLayer,
        switchTo target: KeyboardLayer,
        switchName: String
    ) -> KeyRow {
        let punctuation = [".", ",", "?", "!", "'"]
        let width = (rowUnits - 3) / CGFloat(punctuation.count)
        return KeyRow(keys: [.function(.layerSwitch(target), name: switchName, on: layer, width: 1.5)]
            + punctuation.map { characterKey($0, layer, width: width) }
            + [.function(.backspace, name: "backspace", on: layer, width: 1.5)])
    }

    private static func bottomRow(for layer: KeyboardLayer, context: LayoutContext) -> KeyRow {
        let switchTarget: KeyboardLayer = layer == .letters ? .numbers : .letters
        var leading: [KeySpec] = [.function(.layerSwitch(switchTarget), name: "bottomSwitch", on: layer, width: 1.25)]
        if context.showsNextKeyboardKey {
            leading.append(.function(.nextKeyboard, name: "nextKeyboard", on: layer, width: 1.25))
        }

        let extras: [KeySpec] = switch (layer, context.variant) {
        case (.letters, .email): [characterKey("@", layer), characterKey(".", layer)]
        case (.letters, .url): [characterKey("/", layer), characterKey(".", layer)]
        default: []
        }
        // Apostrophe and period flank the space bar on the plain letter keyboard. Email and
        // web layouts already add their own extra keys, including a period.
        let flank: (left: [KeySpec], right: [KeySpec]) = if layer == .letters, context.variant == .standard {
            (
                [characterKey("'", layer, width: sideMarkWidth)],
                [characterKey(".", layer, width: sideMarkWidth)]
            )
        } else {
            ([], [])
        }
        let emojiKey = KeySpec.function(.emoji, name: "emoji", on: layer, width: sideMarkWidth)
        let returnKey = KeySpec.function(.returnKey, name: "return", on: layer, width: 2.25)
        var fixed = leading
        fixed.append(emojiKey)
        fixed.append(contentsOf: flank.left)
        fixed.append(contentsOf: flank.right)
        fixed.append(contentsOf: extras)
        fixed.append(returnKey)
        let usedUnits = fixed.reduce(0) { $0 + $1.widthUnits }
        let space = KeySpec.function(.space, name: "space", on: layer, width: rowUnits - usedUnits)
        var keys = leading
        keys.append(emojiKey)
        keys.append(contentsOf: flank.left)
        keys.append(space)
        keys.append(contentsOf: flank.right)
        keys.append(contentsOf: extras)
        keys.append(returnKey)
        return KeyRow(keys: keys)
    }

    /// Narrow enough that the space bar can still be a trackpad.
    private static let sideMarkWidth: CGFloat = 0.85

    private static func characterKey(_ value: String, _ layer: KeyboardLayer, width: CGFloat = 1) -> KeySpec {
        .character(
            value,
            on: layer,
            width: width,
            alternates: alternates[value] ?? [],
            secondary: layer == .letters ? secondaries[value] : nil
        )
    }

    // MARK: - Flick secondaries (letters layer)

    /// Digits across the top row, in the same order as the numbers page. Lower rows have no
    /// corner mark: a flick there would travel through other letters and become a swipe.
    static let secondaries: [String: String] = [
        "q": "1", "w": "2", "e": "3", "r": "4", "t": "5", "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
    ]

    /// Accents and symbols a hold offers before the user edits that key.
    public static func builtInAlternates(for key: String) -> [String] {
        alternates[key] ?? []
    }

    // MARK: - Long-press alternates (English)

    static let alternates: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "0": ["°"],
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "$": ["¢", "€", "£", "¥", "₩"],
        "&": ["§"],
        "\"": ["“", "”", "„", "«", "»"],
        ".": [".", "?", "!", "$"],
        "?": ["¿"],
        "!": ["¡"],
        "'": ["‘", "’", "`"],
        "%": ["‰"],
    ]
}
