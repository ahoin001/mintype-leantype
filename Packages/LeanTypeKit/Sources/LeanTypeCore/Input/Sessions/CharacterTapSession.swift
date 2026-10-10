import Foundation

/// Tap typing on a letter or symbol key: highlight on touch-down, follow the finger across
/// keys, commit on lift (or immediately when another finger lands), open the alternates row
/// on long press, and type the top row's digit on a quick upward flick.
///
/// A flick is decided when the finger lifts. Until then an upward move is not yet a
/// swipe, even after it leaves the key, so the digit can still win. Turning sideways gives
/// the path to the swipe.
@MainActor
final class CharacterTapSession: InteractionSession {
    static let longPressDelay: TimeInterval = GestureTiming.longPress
    /// Extra room around the current key before sliding retargets to a neighbor, so small
    /// wobbles at a key edge don't flicker between keys.
    static let retargetSlop: CGFloat = 4
    /// An upward move at least this long, mostly vertical, and quick, is a flick.
    static let flickDistance: CGFloat = 14
    static let flickMaxDuration: TimeInterval = 0.3
    /// Upward travel must be at least this many times the sideways travel.
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
    private var pinArm: (any Cancellable)?
    private var holdIsArmed = false
    /// When this returns false the accent row stays closed. A partner finger or an open beat sets it.
    var accentGate: (() -> Bool)?

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
            if let secondary = flickSecondary(for: latest) {
                return SessionPresentation(
                    pressedKey: origin.id,
                    callout: context.previewCallout(for: origin, showing: secondary, growsFromKey: true)
                )
            }
            guard let target else { return .none }
            return SessionPresentation(pressedKey: target.id, callout: context.previewCallout(for: target))
        case let .alternates(layout, options, selected):
            guard let target else { return .none }
            let callout = CalloutState(
                keyID: target.id,
                layout: layout,
                content: .alternates(options.map(context.displayText(for:)), selectedIndex: selected),
                growsFromKey: true
            )
            return SessionPresentation(pressedKey: target.id, callout: callout)
        }
    }

    /// Whether the other thumb can still take this letter into its word. The shortcut row is
    /// only a preview: until this finger lifts, the letter that was pressed can still join.
    var canRelinquish: Bool {
        switch phase {
        case .tracking, .alternates: true
        case .finished: false
        }
    }

    /// The shortcut row is up. Sliding along it chooses an accent; it is not the start of a swipe.
    var isShowingAlternates: Bool {
        switch phase {
        case .alternates: true
        case .tracking, .finished: false
        }
    }

    /// Drops the accent timer. The row, if it is already up, stays until the finger lifts.
    func disarmAccent() {
        longPress?.cancel()
        longPress = nil
        pinArm?.cancel()
        pinArm = nil
        endHold()
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
              target == nil || target?.id == origin.id,
              let secondary = origin.key.secondary
        else { return nil }
        guard Self.isUpwardFlick(track, on: origin, enabled: true) else { return nil }
        return secondary
    }

    /// The lift commits a digit: far enough up, mostly vertical, and still inside the flick's
    /// own time limit. `enabled` is checked by the caller for the setting; this only checks
    /// the gesture, so a held-off swipe and the commit agree.
    static func isUpwardFlick(_ track: TouchTrack, on key: KeyFrame, enabled: Bool) -> Bool {
        guard enabled, key.key.secondary != nil else { return false }
        let move = track.translation
        let elapsed = track.current.timestamp - track.start.timestamp
        guard elapsed <= flickMaxDuration else { return false }
        guard move.dy <= -flickDistance else { return false }
        return -move.dy >= abs(move.dx) * flickVerticality
    }

    /// True while the finger is heading up and swipe should leave it alone, including after
    /// it has left the key. A sideways turn, or time past the flick, ends the hold.
    static func holdsOffSwipe(_ track: TouchTrack, on key: KeyFrame, enabled: Bool) -> Bool {
        guard enabled, key.key.secondary != nil else { return false }
        let move = track.translation
        let elapsed = track.current.timestamp - track.start.timestamp
        guard elapsed <= flickMaxDuration, move.dy < 0 else { return false }
        return -move.dy >= abs(move.dx) * flickVerticality
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

    /// A flick wins on lift when the gesture stayed an upward digit flick. Leaving the key
    /// does not cancel it; turning sideways does, because swipe has already taken the finger.
    private func commitTracking(_ track: TouchTrack) {
        if let secondary = flickSecondary(for: track) {
            context.composer.commit(ticket, [.insert(secondary)])
        } else {
            commitTarget(time: track.current.timestamp)
        }
    }

    private func commitTarget(time: Double) {
        if let character = target?.key.kind.character {
            context.composer.commit(ticket, [.tapCharacter(character, at: touchPoint, time: time)])
        } else {
            context.composer.cancel(ticket)
        }
    }

    private func scheduleLongPress() {
        longPress?.cancel()
        longPress = nil
        guard let target, !alternateRow(for: target).isEmpty else {
            endHold()
            return
        }
        pinArm = context.schedule(after: GestureComposer.dwellDuration) { [weak self] in
            self?.armPin()
        }
        longPress = context.schedule(after: Self.longPressDelay) { [weak self] in
            self?.presentAlternates()
        }
    }

    private func armPin() {
        guard case .tracking = phase, let target else { return }
        context.emit(.holdArmed(target.visualFrame))
        holdIsArmed = true
    }

    private func endHold() {
        guard holdIsArmed else { return }
        holdIsArmed = false
        context.emit(.holdEnded)
    }

    private func presentAlternates() {
        guard accentGate?() ?? true else { return }
        guard case .tracking = phase, let target else { return }
        let options = alternateRow(for: target)
        guard !options.isEmpty else { return }
        let available = context.calloutBounds.width - 2 * context.geometry.metrics.sideInset
        let widths = CalloutGeometry.cellWidths(
            for: options,
            keyWidth: target.visualFrame.width,
            available: available
        )
        let layout = CalloutGeometry.layout(
            anchor: target.visualFrame,
            optionCount: options.count,
            metrics: context.geometry.metrics,
            bounds: context.calloutBounds,
            cellWidths: widths
        )
        phase = .alternates(layout: layout, options: options, selected: 0)
        context.emit(.alternatesPresented)
    }

    /// Built-in accents, or the row the user saved for this key. A period row that is only
    /// the period itself is not offered: a tap already types it.
    private func alternateRow(for key: KeyFrame) -> [String] {
        let character = key.key.kind.character ?? ""
        let row = KeyShortcuts.row(
            for: character,
            builtIn: key.key.alternates,
            overrides: context.settings.keyShortcuts
        )
        if character == KeyShortcuts.period, row == [KeyShortcuts.period] { return [] }
        return row
    }

    private func finish() {
        longPress?.cancel()
        longPress = nil
        pinArm?.cancel()
        pinArm = nil
        endHold()
        phase = .finished
    }
}
