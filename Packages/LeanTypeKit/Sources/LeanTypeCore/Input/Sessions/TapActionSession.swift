import CoreGraphics

/// A key with a single tap action (return, next keyboard). Commits on lift if the finger is
/// still roughly over the key, or immediately on rollover.
@MainActor
final class TapActionSession: InteractionSession {
    static let releaseSlop: CGFloat = 20

    private unowned let context: any SessionContext
    private let key: KeyFrame
    private let intent: KeyboardIntent
    private let ticket: InputComposer.Ticket
    private var isInside = true
    private var isFinished = false

    init(key: KeyFrame, intent: KeyboardIntent, context: any SessionContext) {
        self.key = key
        self.intent = intent
        self.context = context
        ticket = context.composer.reserve()
        context.emit(.keyDown(.modifier))
    }

    var presentation: SessionPresentation {
        guard !isFinished, isInside else { return .none }
        return SessionPresentation(pressedKey: key.id)
    }

    func moved(_ track: TouchTrack) {
        isInside = key.hitFrame.insetBy(dx: -Self.releaseSlop, dy: -Self.releaseSlop).contains(track.current.location)
    }

    func ended(_: TouchTrack) {
        guard !isFinished else { return }
        commitIfAllowed()
    }

    func cancelled() {
        guard !isFinished else { return }
        context.composer.cancel(ticket)
        isFinished = true
    }

    func otherTouchBegan() {
        guard !isFinished else { return }
        commitIfAllowed()
    }

    private func commitIfAllowed() {
        let allowed = isInside && (intent != .returnKey || context.isReturnKeyEnabled)
        if allowed {
            context.composer.commit(ticket, [intent])
        } else {
            context.composer.cancel(ticket)
        }
        isFinished = true
    }
}
