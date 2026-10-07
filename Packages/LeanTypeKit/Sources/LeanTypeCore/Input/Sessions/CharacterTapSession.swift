import Foundation

/// Tap typing on a letter or symbol key: highlight on touch-down, follow the finger across
/// keys, commit on lift (or immediately when another finger lands), and open the alternates
/// row on long press.
@MainActor
final class CharacterTapSession: InteractionSession {
    static let longPressDelay: TimeInterval = 0.42
    /// Extra room around the current key before sliding retargets to a neighbor, so small
    /// wobbles at a key edge don't flicker between keys.
    static let retargetSlop: CGFloat = 4

    private enum Phase {
        case tracking
        case alternates(layout: CalloutLayout, options: [String], selected: Int)
        case finished
    }

    private unowned let context: any SessionContext
    private let ticket: InputComposer.Ticket
    private var target: KeyFrame?
    private var phase = Phase.tracking
    private var longPress: (any Cancellable)?

    init(key: KeyFrame, context: any SessionContext) {
        self.context = context
        target = key
        ticket = context.composer.reserve()
        context.emit(.keyDown(.character))
        scheduleLongPress()
    }

    var presentation: SessionPresentation {
        switch phase {
        case .finished:
            return .none
        case .tracking:
            guard let target else { return .none }
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

    func moved(_ track: TouchTrack) {
        switch phase {
        case .tracking:
            retarget(to: track.current.location)
        case let .alternates(layout, options, _):
            phase = .alternates(layout: layout, options: options, selected: layout.optionIndex(atX: track.current.location.x))
        case .finished:
            break
        }
    }

    func ended(_: TouchTrack) {
        switch phase {
        case .tracking:
            commitTarget()
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

    func otherTouchBegan() {
        guard case .tracking = phase else { return }
        commitTarget()
        finish()
    }

    // MARK: - Private

    private func retarget(to point: CGPoint) {
        if let target, target.hitFrame.insetBy(dx: -Self.retargetSlop, dy: -Self.retargetSlop).contains(point) {
            return
        }
        let next = context.geometry.key(at: point).flatMap { $0.key.kind.isCharacter ? $0 : nil }
        guard next?.id != target?.id else { return }
        target = next
        scheduleLongPress()
    }

    private func commitTarget() {
        if let character = target?.key.kind.character {
            context.composer.commit(ticket, [.insert(character)])
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
