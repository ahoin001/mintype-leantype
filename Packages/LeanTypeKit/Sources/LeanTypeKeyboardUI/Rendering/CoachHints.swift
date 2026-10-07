import LeanTypeCore

/// One-time lines for the dock: the first one-finger swipe, the first two-thumb word, and
/// the first undone correction. Seen ids are stored in the App Group when Full Access allows
/// it; otherwise they last for this keyboard session.
@MainActor
final class CoachHints {
    struct Hint: Equatable {
        let id: String
        let text: String
    }

    static let swipe = "swipe"
    static let twoThumb = "twoThumb"
    static let correctionUndone = "correctionUndone"

    private var seen: Set<String>
    private var offered: Set<String> = []
    private let store: CoachHintStore

    init(store: CoachHintStore = CoachHintStore()) {
        self.store = store
        seen = store.load()
    }

    func consider(_ event: KeyboardEvent) -> Hint? {
        let hint: Hint? = switch event {
        case let .swipeGestureCommitted(strokes) where strokes >= 2:
            Hint(id: Self.twoThumb, text: "Both thumbs can share one word")
        case .swipeGestureCommitted:
            Hint(id: Self.swipe, text: "Slide through a word, then lift")
        case .correctionReverted:
            Hint(id: Self.correctionUndone, text: "LeanType will remember that")
        default:
            nil
        }
        guard let hint, !seen.contains(hint.id), offered.insert(hint.id).inserted else { return nil }
        return hint
    }

    func markPresented(_ id: String) {
        guard seen.insert(id).inserted else { return }
        store.save(seen)
    }
}
