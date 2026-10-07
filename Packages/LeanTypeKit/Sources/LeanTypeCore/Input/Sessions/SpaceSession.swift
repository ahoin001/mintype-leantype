import Foundation

/// The space bar: a tap types a space; a horizontal drag (or a long press) turns the keyboard
/// into a trackpad that moves the cursor one character per step, faster with faster swipes.
@MainActor
final class SpaceSession: InteractionSession {
    static let activationDistance: CGFloat = 10
    static let longPressDelay: TimeInterval = 0.5
    static let baseStep: CGFloat = 9
    /// Speeds below this move one character per `baseStep`; above it steps shrink.
    static let accelerationOnset: CGFloat = 250
    static let accelerationRange: CGFloat = 700
    static let maxBoost: CGFloat = 1.6

    private enum Phase {
        case pressed
        case trackpad
        case finished
    }

    private unowned let context: any SessionContext
    private let key: KeyFrame
    private let ticket: InputComposer.Ticket
    private var phase = Phase.pressed
    private var longPress: (any Cancellable)?
    private var lastX: CGFloat?
    private var residual: CGFloat = 0

    init(key: KeyFrame, context: any SessionContext) {
        self.key = key
        self.context = context
        ticket = context.composer.reserve()
        context.emit(.keyDown(.modifier))
        longPress = context.schedule(after: Self.longPressDelay) { [weak self] in
            self?.enterTrackpad()
        }
    }

    var presentation: SessionPresentation {
        switch phase {
        case .pressed: SessionPresentation(pressedKey: key.id)
        case .trackpad: SessionPresentation(pressedKey: key.id, isTrackpadActive: true)
        case .finished: .none
        }
    }

    /// Points of travel per character at a given finger speed (points per second).
    static func stepLength(forSpeed speed: CGFloat) -> CGFloat {
        let boost = min(max((speed - accelerationOnset) / accelerationRange, 0), maxBoost)
        return baseStep / (1 + boost)
    }

    func moved(_ track: TouchTrack) {
        switch phase {
        case .pressed:
            guard abs(track.translation.dx) >= Self.activationDistance else { return }
            enterTrackpad()
            lastX = track.current.location.x
        case .trackpad:
            moveCursor(with: track)
        case .finished:
            break
        }
    }

    func ended(_: TouchTrack) {
        if case .pressed = phase {
            context.composer.commit(ticket, [.space])
        }
        finish()
    }

    func cancelled() {
        if case .pressed = phase {
            context.composer.cancel(ticket)
        }
        finish()
    }

    func otherTouchBegan() {
        guard case .pressed = phase else { return }
        context.composer.commit(ticket, [.space])
        finish()
    }

    // MARK: - Private

    private func enterTrackpad() {
        guard case .pressed = phase else { return }
        longPress?.cancel()
        longPress = nil
        context.composer.cancel(ticket)
        phase = .trackpad
        context.emit(.trackpadEngaged)
    }

    private func moveCursor(with track: TouchTrack) {
        let x = track.current.location.x
        defer { lastX = x }
        guard let lastX else { return }

        residual += x - lastX
        let step = Self.stepLength(forSpeed: abs(track.velocity.dx))
        while abs(residual) >= step {
            let direction = residual < 0 ? -1 : 1
            guard context.perform(.moveCursor(direction)) else {
                // At the end of the text: drop accumulated travel so reversing responds at once.
                residual = 0
                return
            }
            context.emit(.cursorStep)
            residual -= CGFloat(direction) * step
        }
    }

    private func finish() {
        longPress?.cancel()
        longPress = nil
        phase = .finished
    }
}
