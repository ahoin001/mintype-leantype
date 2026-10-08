import Foundation

/// Swipe typing on top of tap typing: every finger on a letter starts as a tap and becomes a
/// stroke once it travels far enough.
///
/// Two thumbs land together without typing. The gesture starts when one of them travels.
/// An upward flick on a top-row digit is not that travel: while it is still heading up it
/// stays a flick even after the finger leaves the key. A thumb that never leaves its key is one letter in
/// that word, at the moment it landed, and the word is committed when the last finger lifts.
/// A thumb that later travels becomes another stroke. A tap with no swipe in progress types
/// as it always has.
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
        case holding
        case stroking
        case finished
    }

    private unowned let context: any SessionContext
    private let coordinator: SwipeCoordinator
    private let origin: KeyFrame
    private var phase: Phase
    private var latest: TouchTrack
    private var hoveredKey: KeyID?
    /// The last letter this finger actually aimed at, and that key's center. A new letter
    /// counts only once the finger is past the midpoint toward it, so riding a key boundary
    /// does not alternate.
    private var aimedLetter: String?
    private var aimedCenter: CGPoint?

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
        case .holding:
            SessionPresentation(pressedKey: origin.id, isStroke: false)
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
        case .holding:
            if hasBecomeStroke(track) {
                coordinator.promoteHold(track.id, track: track)
                phase = .stroking
                noteArrival(track, includeStart: true)
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
        case .holding:
            coordinator.liftHold(track.id)
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
        case .holding:
            coordinator.dropHold(latest.id)
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

    /// The gesture started under another thumb. A finger that has already traveled joins as a
    /// stroke. One that is still on its key is a single letter in the same word.
    func joinCurrentGesture() {
        guard case let .tapping(tap) = phase, tap.canRelinquish else { return }
        // A slide along the shortcut row is choosing an accent, not drawing a stroke.
        // The other thumb's word still gets the letter that was pressed.
        if !tap.isShowingAlternates, hasBecomeStroke(latest) {
            beginStroke(from: tap, track: latest)
            return
        }
        let ticket = tap.relinquish()
        context.composer.cancel(ticket)
        coordinator.unregisterUndecided(self)
        holdForCurrentGesture()
    }

    // MARK: - Private

    /// A short upward flick on a digit key stays a flick. Anything sideways, off the key
    /// once that flick window has passed, or long enough to be a word becomes a stroke.
    private func shouldUpgrade(_ tap: CharacterTapSession, track: TouchTrack) -> Bool {
        guard tap.canRelinquish, !tap.isShowingAlternates, Self.canStroke(on: origin, context: context) else { return false }
        return hasBecomeStroke(track)
    }

    private func hasBecomeStroke(_ track: TouchTrack) -> Bool {
        let move = track.translation
        if abs(move.dx) >= Self.sidewaysDistance { return true }
        if CharacterTapSession.holdsOffSwipe(
            track,
            on: origin,
            enabled: context.settings.flickForSecondaryEnabled
        ) {
            return false
        }
        if !origin.hitFrame.contains(track.current.location) { return true }
        return hypot(move.dx, move.dy) >= Self.strokeDistance
    }

    /// Keeps this finger's letter in the open beat without adding a point to the polyline.
    private func holdForCurrentGesture() {
        guard let character = origin.key.kind.character else { return }
        let center = CGPoint(x: origin.visualFrame.midX, y: origin.visualFrame.midY)
        coordinator.hold(latest.id, StrokeObservation(
            time: latest.start.timestamp,
            point: center,
            directionX: 0,
            directionY: 0,
            letter: character.lowercased(),
            isTap: true
        ))
        phase = .holding
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
        if coordinator.isCollecting, tap.canRelinquish, let character = origin.key.kind.character {
            let ticket = tap.relinquish()
            context.composer.cancel(ticket)
            let center = CGPoint(x: origin.visualFrame.midX, y: origin.visualFrame.midY)
            coordinator.noteTap(StrokeObservation(
                time: track.start.timestamp,
                point: center,
                directionX: 0,
                directionY: 0,
                letter: character.lowercased(),
                isTap: true
            ))
        } else {
            tap.ended(track)
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
        if letter != aimedLetter {
            if let aimedCenter {
                let towardNew = hypot(location.x - center.x, location.y - center.y)
                let towardOld = hypot(location.x - aimedCenter.x, location.y - aimedCenter.y)
                guard towardNew < towardOld else { return }
            }
            aimedLetter = letter
            aimedCenter = center
        }
        coordinator.arrive(id, letter: letter, at: center, touch: location, time: time)
    }
}
