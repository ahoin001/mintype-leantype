import Foundation

/// Tap typing on a letter or symbol key: highlight on touch-down, follow the finger across
/// keys, commit on lift (or immediately when another finger lands), open the alternates row
/// on long press, and type the key's secondary character on a quick downward flick.
///
/// A flick is decided when the finger lifts, from the whole gesture. Movement is never locked
/// into "this is a flick" early, so a swipe that starts downward can still become a stroke.
@MainActor
final class CharacterTapSession: InteractionSession {
    static let longPressDelay: TimeInterval = 0.42
    /// Extra room around the current key before sliding retargets to a neighbor, so small
    /// wobbles at a key edge don't flicker between keys.
    static let retargetSlop: CGFloat = 4
    /// A downward move at least this long, mostly vertical, and quick, is a flick.
    static let flickDistance: CGFloat = 14
    static let flickMaxDuration: TimeInterval = 0.3
    static let flickVerticality: CGFloat = 1.3

    private enum Phase {
        case tracking
        case alternates(layout: CalloutLayout, options: [String], selected: Int)
        case finished
    }

    private unowned let context: any SessionContext
    private let origin: KeyFrame
    private var ticket: InputComposer.Ticket
    private var target: KeyFrame?
    /// Where the finger landed on the current target, for autocorrect.
    private var touchPoint: CGPoint
    private var phase = Phase.tracking
    private var latest: TouchTrack
    private var longPress: (any Cancellable)?

    init(key: KeyFrame, track: TouchTrack, context: any SessionContext, ticket: InputComposer.Ticket? = nil) {
        self.context = context
        origin = key
        target = key
        touchPoint = track.start.location
        latest = track
        self.ticket = ticket ?? context.composer.reserve()
        context.emit(.keyDown(.character, at: track.start.location))
        scheduleLongPress()
    }

    var presentation: SessionPresentation {
        switch phase {
        case .finished:
            return .none
        case .tracking:
            guard let target else { return .none }
            if let secondary = flickSecondary(for: latest) {
                return SessionPresentation(pressedKey: origin.id, callout: context.previewCallout(for: origin, showing: secondary))
            }
            return SessionPresentation(pressedKey: target.id, callout: context.previewCallout(for: target))
        case let .alternates(layout, options, selected):
            guard let target else { return .none }
            let callout = CalloutState(
                keyID: target.id,
                layout: layout,
                content: .alternates(options.map(context.displayText(for:)), selectedIndex: selected)
            )
            return SessionPresentation(pressedKey: target.id, callout: callout)
        }
    }

    /// Whether a swipe can still take this touch over (nothing decided yet).
    var canRelinquish: Bool {
        if case .tracking = phase { return true }
        return false
    }

    /// Ends this session without committing and hands its composer slot to the caller, which
    /// keeps the touch's place in the typing order.
    func relinquish() -> InputComposer.Ticket {
        finish()
        return ticket
    }

    func moved(_ track: TouchTrack) {
        latest = track
        switch phase {
        case .tracking:
            retarget(to: track.current.location)
        case let .alternates(layout, options, _):
            phase = .alternates(layout: layout, options: options, selected: layout.optionIndex(atX: track.current.location.x))
        case .finished:
            break
        }
    }

    func ended(_ track: TouchTrack) {
        latest = track
        switch phase {
        case .tracking:
            commitTracking(track)
        case let .alternates(_, options, selected):
            context.composer.commit(ticket, [.insert(options[selected])])
        case .finished:
            return
        }
        finish()
    }

    func cancelled() {
        if case .finished = phase { return }
        context.composer.cancel(ticket)
        finish()
    }

    func otherTouchBegan(on _: KeyFrame) {
        switch phase {
        case .tracking:
            commitTracking(latest)
        case .alternates, .finished:
            return
        }
        finish()
    }

    // MARK: - Private

    private func flickSecondary(for track: TouchTrack) -> String? {
        guard context.settings.flickForSecondaryEnabled,
              target?.id == origin.id,
              let secondary = origin.key.secondary
        else { return nil }
        let move = track.translation
        let elapsed = track.current.timestamp - track.start.timestamp
        guard move.dy >= Self.flickDistance,
              move.dy >= abs(move.dx) * Self.flickVerticality,
              elapsed <= Self.flickMaxDuration
        else { return nil }
        return secondary
    }

    private func retarget(to point: CGPoint) {
        if let target, target.hitFrame.insetBy(dx: -Self.retargetSlop, dy: -Self.retargetSlop).contains(point) {
            return
        }
        let next = context.geometry.key(at: point).flatMap { $0.key.kind.isCharacter ? $0 : nil }
        guard next?.id != target?.id else { return }
        target = next
        touchPoint = point
        scheduleLongPress()
    }

    /// A flick only wins if the finger is still on the key it started on. Leaving the key, or
    /// travelling sideways, is a swipe or a retarget, decided by the caller before lift.
    private func commitTracking(_ track: TouchTrack) {
        if let secondary = flickSecondary(for: track) {
            context.composer.commit(ticket, [.insert(secondary)])
        } else {
            commitTarget()
        }
    }

    private func commitTarget() {
        if let character = target?.key.kind.character {
            context.composer.commit(ticket, [.tapCharacter(character, at: touchPoint)])
        } else {
            context.composer.cancel(ticket)
        }
    }

    private func scheduleLongPress() {
        longPress?.cancel()
        longPress = nil
        guard let target, !target.key.alternates.isEmpty else { return }
        longPress = context.schedule(after: Self.longPressDelay) { [weak self] in
            self?.presentAlternates()
        }
    }

    private func presentAlternates() {
        guard case .tracking = phase, let target else { return }
        let options = target.key.alternates
        let layout = CalloutGeometry.layout(
            anchor: target.visualFrame,
            optionCount: options.count,
            metrics: context.geometry.metrics,
            bounds: context.calloutBounds
        )
        phase = .alternates(layout: layout, options: options, selected: 0)
        context.emit(.alternatesPresented)
    }

    private func finish() {
        longPress?.cancel()
        longPress = nil
        phase = .finished
    }
}
