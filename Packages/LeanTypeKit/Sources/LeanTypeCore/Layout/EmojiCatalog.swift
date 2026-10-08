import Foundation

/// One page of the emoji keyboard. A small everyday set, not the whole Unicode list.
public enum EmojiCategory: String, Hashable, Sendable, CaseIterable {
    case smileys
    case gestures
    case symbols
    case life

    /// The face drawn on the page's key.
    public var symbol: String {
        switch self {
        case .smileys: "😀"
        case .gestures: "👋"
        case .symbols: "❤️"
        case .life: "🐶"
        }
    }

    public var spokenName: String {
        switch self {
        case .smileys: "smileys"
        case .gestures: "gestures"
        case .symbols: "hearts"
        case .life: "more emoji"
        }
    }
}

/// The emoji a page shows, ten per row across three rows.
public enum EmojiCatalog {
    public static let rowCount = 3
    public static let perRow = 10

    public static func symbols(on page: EmojiCategory) -> [String] {
        switch page {
        case .smileys: smileys
        case .gestures: gestures
        case .symbols: symbols
        case .life: life
        }
    }

    public static func contains(_ text: String) -> Bool {
        known.contains(text)
    }

    private static let smileys = [
        "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇",
        "🙂", "😉", "😍", "😘", "😗", "😚", "😋", "😛", "😜", "🤪",
        "🤨", "🧐", "🤓", "😎", "🤩", "🥳", "😏", "😒", "😞", "😔",
    ]

    private static let gestures = [
        "👋", "🤚", "✋", "🖖", "👌", "🤌", "🤏", "✌️", "🤞", "🫰",
        "🤟", "🤘", "🤙", "👈", "👉", "👆", "👇", "☝️", "👍", "👎",
        "✊", "👊", "🤛", "🤜", "👏", "🙌", "👐", "🤲", "🤝", "🙏",
    ]

    private static let symbols = [
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔",
        "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟", "♥️",
        "⭐", "🌟", "✨", "🔥", "💯", "💫", "⚡", "☀️", "🌈", "❄️",
    ]

    private static let life = [
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯",
        "🍎", "🍕", "🍔", "🍟", "🌮", "🍩", "🍪", "🎂", "☕", "🍺",
        "🚗", "✈️", "🏠", "🎁", "🎉", "⚽", "🏀", "🎵", "📷", "💡",
    ]

    private static let known: Set<String> = Set(
        EmojiCategory.allCases.flatMap { symbols(on: $0) }
    )
}
