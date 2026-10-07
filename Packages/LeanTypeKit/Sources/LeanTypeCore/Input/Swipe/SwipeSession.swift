import Foundation

/// Swipe typing on top of tap typing: every finger on a letter starts as a tap and becomes a
/// stroke once it travels far enough. A finger that lands while a gesture is in progress joins
/// it as another stroke, which is how two-thumb sliding works.
struct SwipeTypingMode: TypingMode {
    let coordinator: SwipeCoordinator

    func makeSession(for key: KeyFrame, track: TouchTrack, context: any SessionContext) -> any InteractionSession {
        if coordinator.isCollecting, SwipeSession.canStroke(on: key, context: context) {
            return SwipeSession(joining: key, track: track, coordinator: coordinator, context: context)
        }
        return SwipeSession(key: key, track: track, coordinator: coordinator, context: context)
    }
}

@MainActor
final class SwipeSession: InteractionSession {
    /// Sideways travel that is a swipe, not a downward flick.
    static let sidewaysDistance: CGFloat = 16
    /// Travel in any direction that turns a tap into a stroke, even straight down.
    static let strokeDistance: CGFloat = 36

    private enum Phase {
        case tapping(CharacterTapSession)
        case stroking
        case finished
    }

    private unowned let context: any SessionContext
    private let coordinator: SwipeCoordinator
    private let origin: KeyFrame
    private var phase: Phase
    private var hoveredKey: KeyID?

    init(key: KeyFrame, track: TouchTrack, coordinator: SwipeCoordinator, context: any SessionContext) {
        self.context = context
        self.coordinator = coordinator
        origin = key
        phase = .tapping(CharacterTapSession(key: key, track: track, context: context))
    }

    init(joining key: KeyFrame, track: TouchTrack, coordinator: SwipeCoordinator, context: any SessionContext) {
        self.context = context
        self.coordinator = coordinator
        origin = key
        phase = .stroking
        hoveredKey = key.id
        context.emit(.keyDown(.character, at: track.start.location))
        coordinator.join(track)
    }

    static func canStroke(on key: KeyFrame, context: any SessionContext) -> Bool {
        guard context.currentLayer == .letters, let character = key.key.kind.character,
              character.count == 1, let first = character.first
        else { return false }
        return first.isASCII && first.isLetter
    }

    var presentation: SessionPresentation {
        switch phase {
        case let .tapping(tap):
            tap.presentation
        case .stroking:
            SessionPresentation(pressedKey: hoveredKey, isStroke: true)
        case .finished:
            .none
        }
    }

    func moved(_ track: TouchTrack) {
        switch phase {
        case let .tapping(tap):
            if shouldUpgrade(tap, track: track) {
                coordinator.begin(track, ticket: tap.relinquish())
                phase = .stroking
                hover(track)
            } else {
                tap.moved(track)
            }
        case .stroking:
            coordinator.moved(track)
            hover(track)
        case .finished:
            break
        }
    }

    func ended(_ track: TouchTrack) {
        switch phase {
        case let .tapping(tap):
            tap.ended(track)
        case .stroking:
            coordinator.ended(track)
        case .finished:
            return
        }
        phase = .finished
    }

    func cancelled() {
        switch phase {
        case let .tapping(tap):
            tap.cancelled()
        case .stroking:
            coordinator.reset()
        case .finished:
            return
        }
        phase = .finished
    }

    func otherTouchBegan() {
        if case let .tapping(tap) = phase {
            tap.otherTouchBegan()
        }
    }

    // MARK: - Private

    /// A short downward dip on the starting key stays a flick. Anything sideways, off the key,
    /// or long enough to be a word becomes a stroke immediately.
    private func shouldUpgrade(_ tap: CharacterTapSession, track: TouchTrack) -> Bool {
        guard tap.canRelinquish, Self.canStroke(on: origin, context: context) else { return false }
        let move = track.translation
        if abs(move.dx) >= Self.sidewaysDistance { return true }
        if !origin.hitFrame.contains(track.current.location) { return true }
        return hypot(move.dx, move.dy) >= Self.strokeDistance
    }

    private func hover(_ track: TouchTrack) {
        hoveredKey = context.geometry.key(at: track.current.location).flatMap { $0.key.kind.isCharacter ? $0.id : nil }
    }
}
