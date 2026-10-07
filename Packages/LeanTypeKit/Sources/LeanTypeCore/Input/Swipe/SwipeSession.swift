import Foundation

/// Swipe typing on top of tap typing: every finger on a letter starts as a tap and becomes a
/// stroke once it travels far enough.
///
/// Two thumbs land together without typing. The gesture starts when one of them travels, and
/// every thumb still down joins it. A thumb that lifts without leaving its key, once a swipe
/// is underway, types that letter after the word.
struct SwipeTypingMode: TypingMode {
    let coordinator: SwipeCoordinator

    func makeSession(for key: KeyFrame, track: TouchTrack, context: any SessionContext) -> any InteractionSession {
        SwipeSession(key: key, track: track, coordinator: coordinator, context: context)
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
    private var latest: TouchTrack
    private var hoveredKey: KeyID?

    init(key: KeyFrame, track: TouchTrack, coordinator: SwipeCoordinator, context: any SessionContext) {
        self.context = context
        self.coordinator = coordinator
        origin = key
        latest = track
        phase = .tapping(CharacterTapSession(key: key, track: track, context: context))
        if Self.canStroke(on: key, context: context) {
            coordinator.registerUndecided(self)
        }
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
        latest = track
        switch phase {
        case let .tapping(tap):
            if shouldUpgrade(tap, track: track) {
                beginStroke(from: tap, track: track)
            } else {
                tap.moved(track)
            }
        case .stroking:
            coordinator.moved(track)
            noteArrival(track)
        case .finished:
            break
        }
    }

    func ended(_ track: TouchTrack) {
        latest = track
        switch phase {
        case let .tapping(tap):
            endTap(tap, track: track)
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
            coordinator.unregisterUndecided(self)
            tap.cancelled()
        case .stroking:
            coordinator.reset()
        case .finished:
            return
        }
        phase = .finished
    }

    func otherTouchBegan(on key: KeyFrame) {
        guard case let .tapping(tap) = phase else { return }
        // The other thumb may be starting the same word. Wait to see who travels.
        if tap.canRelinquish,
           Self.canStroke(on: origin, context: context),
           Self.canStroke(on: key, context: context) {
            return
        }
        coordinator.unregisterUndecided(self)
        tap.otherTouchBegan(on: key)
        phase = .finished
    }

    /// The gesture started under another thumb. This finger, still down, becomes a stroke of it.
    func joinCurrentGesture() {
        guard case let .tapping(tap) = phase, tap.canRelinquish else { return }
        let ticket = tap.relinquish()
        context.composer.cancel(ticket)
        coordinator.unregisterUndecided(self)
        coordinator.join(latest)
        phase = .stroking
        noteArrival(latest, includeStart: true)
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

    private func beginStroke(from tap: CharacterTapSession, track: TouchTrack) {
        coordinator.unregisterUndecided(self)
        if coordinator.isCollecting {
            let ticket = tap.relinquish()
            context.composer.cancel(ticket)
            coordinator.join(track)
        } else {
            coordinator.begin(track, ticket: tap.relinquish())
            coordinator.enlistUndecidedPartners()
        }
        phase = .stroking
        noteArrival(track, includeStart: true)
    }

    private func endTap(_ tap: CharacterTapSession, track: TouchTrack) {
        coordinator.unregisterUndecided(self)
        if coordinator.isCollecting, tap.canRelinquish {
            commitTrailingTap(tap, track: track)
        } else {
            tap.ended(track)
        }
    }

    /// This letter was a tap beside a swipe, so it has to sort after the word. Its original
    /// ticket may be older than the gesture's, which would type the letter first.
    private func commitTrailingTap(_ tap: CharacterTapSession, track: TouchTrack) {
        let ticket = tap.relinquish()
        context.composer.cancel(ticket)
        let later = context.composer.reserve()
        if let character = origin.key.kind.character {
            context.composer.commit(later, [.tapCharacter(character, at: track.start.location, time: track.start.timestamp)])
        } else {
            context.composer.cancel(later)
        }
    }

    private func noteArrival(_ track: TouchTrack, includeStart: Bool = false) {
        if includeStart {
            record(track.start.location, at: track.start.timestamp, id: track.id)
        }
        record(track.current.location, at: track.current.timestamp, id: track.id)
    }

    private func record(_ location: CGPoint, at time: Double, id: TouchID) {
        guard let frame = context.geometry.key(at: location), let letter = frame.key.kind.character else {
            if context.geometry.key(at: location) == nil { hoveredKey = nil }
            return
        }
        hoveredKey = frame.id
        let center = CGPoint(x: frame.visualFrame.midX, y: frame.visualFrame.midY)
        coordinator.arrive(id, letter: letter, at: center, time: time)
    }
}
