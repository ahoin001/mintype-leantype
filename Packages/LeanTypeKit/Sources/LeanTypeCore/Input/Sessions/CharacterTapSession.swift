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
    /// Travel on the period key that opens the mark row, without waiting for a long press.
    static let markSlideDistance: CGFloat = 10
    /// Period sits under the finger. Sliding chooses the rest.
    static let periodMarks = [".", ",", "?", "!"]

    private enum Phase {
        case tracking
        case alternates(layout: CalloutLayout, options: [String], selected: Int)
        case marks(layout: CalloutLayout, options: [String], selected: Int)
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
        case let .marks(layout, options, selected):
            let callout = CalloutState(
                keyID: origin.id,
                layout: layout,
                content: .alternates(options, selectedIndex: selected)
            )
            return SessionPresentation(pressedKey: origin.id, callout: callout)
        }
    }

    /// Whether the other thumb can still take this letter into its word. The shortcut row is
    /// only a preview: until this finger lifts, the letter that was pressed can still join.
    var canRelinquish: Bool {
        switch phase {
        case .tracking, .alternates: true
        case .marks, .finished: false
        }
    }

    /// The shortcut row is up. Sliding along it chooses an accent; it is not the start of a swipe.
    var isShowingAlternates: Bool {
        switch phase {
        case .alternates, .marks: true
        case .tracking, .finished: false
        }
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
            if shouldOpenPeriodMarks(track) {
                enterPeriodMarks(at: track)
            } else {
                retarget(to: track.current.location)
            }
        case let .alternates(layout, options, _):
            phase = .alternates(layout: layout, options: options, selected: layout.optionIndex(atX: track.current.location.x))
        case let .marks(layout, options, _):
            phase = .marks(layout: layout, options: options, selected: layout.optionIndex(atX: track.current.location.x))
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
        case let .marks(_, options, selected):
            commitMark(options[selected])
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
        case let .marks(_, options, selected):
            commitMark(options[selected])
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
            commitTarget(time: track.current.timestamp)
        }
    }

    private func shouldOpenPeriodMarks(_ track: TouchTrack) -> Bool {
        guard origin.key.kind.character == "." else { return false }
        return hypot(track.translation.dx, track.translation.dy) >= Self.markSlideDistance
    }

    /// The period key grows a row of marks as soon as the finger slides. No long-press wait.
    private func enterPeriodMarks(at track: TouchTrack) {
        guard case .tracking = phase else { return }
        longPress?.cancel()
        longPress = nil
        let layout = CalloutGeometry.layout(
            anchor: origin.visualFrame,
            optionCount: Self.periodMarks.count,
            metrics: context.geometry.metrics,
            bounds: context.calloutBounds
        )
        phase = .marks(
            layout: layout,
            options: Self.periodMarks,
            selected: layout.optionIndex(atX: track.current.location.x)
        )
        context.emit(.alternatesPresented)
    }

    private func commitMark(_ mark: String) {
        context.composer.commit(ticket, [.insert(mark)])
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
        guard let target, !alternateRow(for: target).isEmpty else { return }
        longPress = context.schedule(after: Self.longPressDelay) { [weak self] in
            self?.presentAlternates()
        }
    }

    private func presentAlternates() {
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

    /// Built-in accents, or the row the user saved for this letter.
    private func alternateRow(for key: KeyFrame) -> [String] {
        KeyShortcuts.row(
            for: key.key.kind.character ?? "",
            builtIn: key.key.alternates,
            overrides: context.settings.keyShortcuts
        )
    }

    private func finish() {
        longPress?.cancel()
        longPress = nil
        phase = .finished
    }
}
