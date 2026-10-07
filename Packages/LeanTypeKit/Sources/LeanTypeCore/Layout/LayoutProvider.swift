import CoreGraphics

/// Everything outside the layer itself that changes which keys appear.
public struct LayoutContext: Hashable, Sendable {
    public var variant: KeyboardVariant
    /// Mirrors `UIInputViewController.needsInputModeSwitchKey`.
    public var showsNextKeyboardKey: Bool

    public init(variant: KeyboardVariant = .standard, showsNextKeyboardKey: Bool = true) {
        self.variant = variant
        self.showsNextKeyboardKey = showsNextKeyboardKey
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

        let returnKey = KeySpec.function(.returnKey, name: "return", on: layer, width: 2.25)
        let usedUnits = (leading + extras + [returnKey]).reduce(0) { $0 + $1.widthUnits }
        let space = KeySpec.function(.space, name: "space", on: layer, width: rowUnits - usedUnits)
        return KeyRow(keys: leading + [space] + extras + [returnKey])
    }

    private static func characterKey(_ value: String, _ layer: KeyboardLayer, width: CGFloat = 1) -> KeySpec {
        .character(value, on: layer, width: width, alternates: alternates[value] ?? [])
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
        ".": ["…"],
        "?": ["¿"],
        "!": ["¡"],
        "'": ["‘", "’", "`"],
        "%": ["‰"],
    ]
}
