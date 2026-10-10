import CoreGraphics

/// Which thumb started a touch. Fixed at touch-down; crossing the middle does not retag it.
enum ThumbSide: Int, Hashable, Sendable {
    case left = 0
    case right = 1
}

/// Space, return, or punctuation. Each one closes a tap-open word and then types itself.
enum WordDelimiter: Hashable, Sendable {
    case space
    case returnKey
    case punctuation
}

/// Letters and strokes of one word, in the order they happened.
///
/// A tap is the letter itself. A stroke is one thumb's path. The matcher reads this timeline
/// and never sees the raw touch stream.
struct Timeline: Equatable, Sendable {
    enum Item: Equatable, Sendable {
        case tap(letter: String, time: Double)
        case stroke(thumb: ThumbSide)
    }

    var items: [Item] = []

    var hasStroke: Bool {
        items.contains { if case .stroke = $0 { true } else { false } }
    }

    var strokeCount: Int {
        items.reduce(into: 0) { count, item in
            if case .stroke = item { count += 1 }
        }
    }

    var tapLetters: String {
        items.reduce(into: "") { text, item in
            if case let .tap(letter, _) = item { text += letter }
        }
    }
}
