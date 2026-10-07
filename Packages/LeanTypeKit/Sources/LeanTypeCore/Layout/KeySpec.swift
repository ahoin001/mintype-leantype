import CoreGraphics

/// The pages a keyboard can show.
public enum KeyboardLayer: String, Hashable, Sendable, CaseIterable {
    case letters
    case numbers
    case symbols
}

/// Stable identity for a key within a layout, used to diff rendering and track presses.
public struct KeyID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// What pressing a key means, independent of how it looks.
public enum KeyKind: Hashable, Sendable {
    /// Inserts text. The stored value is the unshifted form; shift is applied at commit time.
    case character(String)
    case shift
    case backspace
    case space
    case returnKey
    case layerSwitch(KeyboardLayer)
    case nextKeyboard

    public var isCharacter: Bool {
        if case .character = self { return true }
        return false
    }

    public var character: String? {
        if case let .character(value) = self { return value }
        return nil
    }
}

/// A single key in a row: what it does, how wide it is, and its long-press alternates.
public struct KeySpec: Hashable, Sendable, Identifiable {
    public let id: KeyID
    public let kind: KeyKind
    /// Width in layout units; a standard letter key is one unit and a full row is ten.
    public let widthUnits: CGFloat
    /// Long-press alternates, ordered from nearest to farthest from the key.
    public let alternates: [String]
    /// Typed by a short downward flick (digits on the top letter row, common symbols below).
    public let secondary: String?

    public init(id: KeyID, kind: KeyKind, widthUnits: CGFloat = 1, alternates: [String] = [], secondary: String? = nil) {
        self.id = id
        self.kind = kind
        self.widthUnits = widthUnits
        self.alternates = alternates
        self.secondary = secondary
    }

    static func character(
        _ value: String,
        on layer: KeyboardLayer,
        width: CGFloat = 1,
        alternates: [String] = [],
        secondary: String? = nil
    ) -> KeySpec {
        KeySpec(
            id: KeyID(rawValue: "\(layer.rawValue).char.\(value)"),
            kind: .character(value),
            widthUnits: width,
            alternates: alternates,
            secondary: secondary
        )
    }

    static func function(_ kind: KeyKind, name: String, on layer: KeyboardLayer, width: CGFloat) -> KeySpec {
        KeySpec(id: KeyID(rawValue: "\(layer.rawValue).\(name)"), kind: kind, widthUnits: width)
    }
}

/// One horizontal row of keys. `insetUnits` is empty space split evenly on both sides, used
/// for the staggered middle letter row.
public struct KeyRow: Hashable, Sendable {
    public let keys: [KeySpec]
    public let insetUnits: CGFloat

    public init(keys: [KeySpec], insetUnits: CGFloat = 0) {
        self.keys = keys
        self.insetUnits = insetUnits
    }

    var totalUnits: CGFloat {
        keys.reduce(insetUnits) { $0 + $1.widthUnits }
    }
}

public struct KeyboardLayout: Hashable, Sendable {
    public let layer: KeyboardLayer
    public let rows: [KeyRow]

    public init(layer: KeyboardLayer, rows: [KeyRow]) {
        self.layer = layer
        self.rows = rows
    }
}
