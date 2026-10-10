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
    /// Sideways travel that is a swipe, not a downward flick. Physical, so it stays in points.
    static let sidewaysDistance: CGFloat = 16
    /// Travel in any direction that turns a tap into a stroke, even straight down.
    static let strokeDistance: CGFloat = 36
    /// How far past the key's hit frame a roll must go before it is a stroke. A thumb that
    /// only crosses the border is still a tap.
    static let frameSlop: CGFloat = 8
    /// A letter held this long, while another finger is drawing, is a rest and not a letter.
    static let restDuration: Double = 0.5

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
    /// Fixed when this finger becomes a stroke, so the trail keeps that thumb's color.
    private var drawingThumb: Int?

    init(key: KeyFrame, track: TouchTrack, coordinator: SwipeCoordinator, context: any SessionContext) {
        self.context = context
        self.coordinator = coordinator
        origin = key
        latest = track
        let tap = CharacterTapSession(key: key, track: track, context: context)
        phase = .tapping(tap)
        tap.accentGate = { [weak self] in
            guard let self else { return true }
            if self.context.isInsideComposingWord { return false }
            return !self.coordinator.blocksAccent(for: self)
        }
        coordinator.fingerDown()
        if Self.canStroke(on: key, context: context) {
            coordinator.registerUndecided(self)
            if coordinator.hasLetterFingerDown(besides: self), let character = key.key.kind.character {
                let midline = LetterLayout(geometry: context.geometry)?.handMidline ?? (context.geometry.size.width / 2)
                ThumbTerritory.observe(character, onLeft: track.start.location.x < midline)
            }
            if coordinator.blocksAccent(for: self) {
                tap.disarmAccent()
            }
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
            SessionPresentation(pressedKey: hoveredKey, isStroke: true, strokeThumb: drawingThumb)
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
            if hasBecomeStroke(track), let thumb = coordinator.chainThumb(preferring: thumbIndex(of: track.start.location)) {
                coordinator.promoteHold(
                    track.id,
                    track: track,
                    keyWidth: origin.visualFrame.width,
                    thumb: thumb
                )
                drawingThumb = thumb
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
            coordinator.liftHold(track.id, at: track.current.timestamp)
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
            coordinator.noteFingerCancelled()
            tap.cancelled()
            if !coordinator.hasLetterFingerDown(besides: self) {
                coordinator.releaseParkedTaps()
            }
        case .holding:
            coordinator.dropHold(latest.id)
        case .stroking:
            // This finger already drew. Keep it, and keep the other thumb's stroke.
            coordinator.ended(latest)
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
            tap.disarmAccent()
            return
        }
        coordinator.unregisterUndecided(self)
        coordinator.releaseParkedTaps()
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
        let accent = tap.isShowingAlternates
        let ticket = tap.relinquish()
        context.composer.cancel(ticket)
        coordinator.unregisterUndecided(self)
        holdForCurrentGesture(keepsRest: accent)
    }

    // MARK: - Private

    /// A short upward flick on a digit key stays a flick. Anything sideways, off the key
    /// once that flick window has passed, or long enough to be a word becomes a stroke.
    private func shouldUpgrade(_ tap: CharacterTapSession, track: TouchTrack) -> Bool {
        guard tap.canRelinquish, !tap.isShowingAlternates, Self.canStroke(on: origin, context: context) else { return false }
        return hasBecomeStroke(track)
    }

    private func hasBecomeStroke(_ track: TouchTrack) -> Bool {
        let holdsFlick = CharacterTapSession.holdsOffSwipe(
            track,
            on: origin,
            enabled: context.settings.flickForSecondaryEnabled
        )
        return GestureSegmenter.isStroke(
            GestureSegmenter.Probe(
                translation: track.translation,
                location: track.current.location,
                hitFrame: origin.hitFrame,
                holdsUpwardFlick: holdsFlick
            ),
            sidewaysThreshold: TapTravel.threshold
        )
    }

    /// Keeps this finger's letter in the open beat without adding a point to the polyline.
    /// An accent popup is a deliberate hold. A long rest beside another stroke is not.
    private func holdForCurrentGesture(keepsRest: Bool = false) {
        guard let character = origin.key.kind.character else { return }
        let center = CGPoint(x: origin.visualFrame.midX, y: origin.visualFrame.midY)
        coordinator.hold(latest.id, keepsRest: keepsRest, StrokeObservation(
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
        let thumbSide = thumbIndex(of: track.start.location)
        guard let thumb = coordinator.chainThumb(preferring: thumbSide) else {
            endTap(tap, track: track)
            return
        }
        // A tap-open word stays open so this stroke joins it. Anything else waiting
        // on the old idle hold commits before the new stroke starts.
        if coordinator.isIdleHold, coordinator.session.phase != .tapOpen {
            coordinator.finishNow()
        }
        if coordinator.isCollecting {
            let ticket = tap.relinquish()
            context.composer.cancel(ticket)
            coordinator.join(track, keyWidth: origin.visualFrame.width, thumb: thumb)
        } else {
            coordinator.begin(track, ticket: tap.relinquish(), keyWidth: origin.visualFrame.width, thumb: thumb)
            coordinator.enlistUndecidedPartners()
        }
        drawingThumb = thumb
        phase = .stroking
        noteArrival(track, includeStart: true)
    }

    /// Left of the Q–P midline is one thumb. The other side is the other thumb.
    private func thumbIndex(of location: CGPoint) -> Int {
        let midline = LetterLayout(geometry: context.geometry)?.handMidline ?? (context.geometry.size.width / 2)
        return location.x < midline ? 0 : 1
    }

    /// Space, return, and these marks close a tap-open word instead of joining it.
    private static func isWordDelimiter(_ character: String) -> Bool {
        guard character.count == 1, let mark = character.first else { return false }
        return TextBoundary.hoppingPunctuation.contains(mark) || mark == "'"
    }

    private func endTap(_ tap: CharacterTapSession, track: TouchTrack) {
        coordinator.unregisterUndecided(self)
        if let character = origin.key.kind.character, Self.isWordDelimiter(character) {
            coordinator.noteDelimiterLift()
            _ = context.commitTapOpenWord()
            tap.ended(track)
            return
        }
        if tap.canRelinquish, let character = origin.key.kind.character,
           coordinator.isCollecting || coordinator.hasLetterFingerDown(besides: self) {
            let ticket = tap.relinquish()
            let center = CGPoint(x: origin.visualFrame.midX, y: origin.visualFrame.midY)
            let observation = StrokeObservation(
                time: track.start.timestamp,
                point: center,
                directionX: 0,
                directionY: 0,
                letter: character.lowercased(),
                isTap: true
            )
            if coordinator.isCollecting {
                context.composer.cancel(ticket)
                coordinator.noteTap(observation)
            } else {
                coordinator.parkTap(observation, character: character, ticket: ticket)
            }
        } else {
            TapTravel.note(travel: hypot(track.translation.dx, track.translation.dy))
            coordinator.releaseParkedTaps()
            if let character = origin.key.kind.character {
                coordinator.noteSoloTap(letter: character.lowercased(), time: track.start.timestamp)
            } else {
                coordinator.noteFingerCancelled()
            }
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
