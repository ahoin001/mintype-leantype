import Foundation

/// The space bar: a tap types a space; a horizontal drag (or a long press) turns the keyboard
/// into a trackpad that moves the cursor one character per step, faster with faster swipes.
///
/// In trackpad mode a fast fling jumps whole words, a second finger switches to word steps
/// for as long as it rests on the keyboard, and parking the finger at either edge of the
/// keyboard keeps the cursor gliding.
@MainActor
final class SpaceSession: InteractionSession {
    static let activationDistance: CGFloat = 10
    static let longPressDelay: TimeInterval = 0.5
    static let baseStep: CGFloat = 9
    /// Speeds below this move one character per `baseStep`; above it steps shrink.
    static let accelerationOnset: CGFloat = 250
    static let accelerationRange: CGFloat = 700
    static let maxBoost: CGFloat = 1.6
    /// Above this finger speed (points per second), steps jump whole words.
    static let flingSpeed: CGFloat = 1500
    static let wordStep: CGFloat = 26
    /// Distance from the keyboard's side edges that starts gliding.
    static let edgeZone: CGFloat = 22
    static let edgeRepeat: (character: TimeInterval, word: TimeInterval) = (0.07, 0.2)
    /// A downward flick opens these, nearest the finger first.
    static let punctuationMarks = [".", ",", "?", "!", "'"]

    private enum Phase {
        case pressed
        case trackpad
        case punctuation(layout: CalloutLayout, selected: Int)
        case finished
    }

    private unowned let context: any SessionContext
    private let key: KeyFrame
    private let ticket: InputComposer.Ticket
    private var phase = Phase.pressed
    private var longPress: (any Cancellable)?
    private var lastX: CGFloat?
    private var residual: CGFloat = 0
    private var extraFingers: Set<TouchID> = []
    private var edgeDirection = 0
    private var edgeTimer: (any Cancellable)?

    init(key: KeyFrame, track: TouchTrack, context: any SessionContext) {
        self.key = key
        self.context = context
        ticket = context.composer.reserve()
        context.emit(.keyDown(.modifier, at: track.start.location))
        longPress = context.schedule(after: Self.longPressDelay) { [weak self] in
            self?.enterTrackpad()
        }
    }

    var presentation: SessionPresentation {
        switch phase {
        case .pressed: SessionPresentation(pressedKey: key.id)
        case .trackpad: SessionPresentation(pressedKey: key.id, isTrackpadActive: true)
        case let .punctuation(layout, selected):
            SessionPresentation(
                pressedKey: key.id,
                callout: CalloutState(
                    keyID: key.id,
                    layout: layout,
                    content: .alternates(Self.punctuationMarks, selectedIndex: selected)
                )
            )
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
            let move = track.translation
            if abs(move.dx) >= Self.activationDistance {
                enterTrackpad()
                lastX = track.current.location.x
                return
            }
            if move.dy >= CharacterTapSession.flickDistance,
               move.dy >= abs(move.dx) * CharacterTapSession.flickVerticality {
                enterPunctuation(at: track)
            }
        case .trackpad:
            moveCursor(with: track)
            updateEdgeGlide(at: track.current.location.x)
        case let .punctuation(layout, _):
            phase = .punctuation(layout: layout, selected: layout.optionIndex(atX: track.current.location.x))
        case .finished:
            break
        }
    }

    func ended(_ track: TouchTrack) {
        switch phase {
        case .pressed:
            context.composer.commit(ticket, [.space])
        case let .punctuation(_, selected):
            context.composer.commit(ticket, [.insert(Self.punctuationMarks[selected])])
        case .trackpad, .finished:
            break
        }
        finish()
    }

    func cancelled() {
        if case .pressed = phase {
            context.composer.cancel(ticket)
        }
        finish()
    }

    func otherTouchBegan(on _: KeyFrame) {
        switch phase {
        case .pressed:
            context.composer.commit(ticket, [.space])
        case let .punctuation(_, selected):
            context.composer.commit(ticket, [.insert(Self.punctuationMarks[selected])])
        case .trackpad, .finished:
            return
        }
        finish()
    }

    func absorbTouch(_ track: TouchTrack) -> Bool {
        switch phase {
        case .trackpad:
            break
        case .pressed:
            guard key.hitFrame.contains(track.start.location) else { return false }
            enterTrackpad()
        case .punctuation, .finished:
            return false
        }
        extraFingers.insert(track.id)
        return true
    }

    func absorbedTouchEnded(_ track: TouchTrack) {
        extraFingers.remove(track.id)
    }

    // MARK: - Private

    private var stepsByWord: Bool { !extraFingers.isEmpty }

    private func enterPunctuation(at track: TouchTrack) {
        guard case .pressed = phase else { return }
        longPress?.cancel()
        longPress = nil
        let letter = context.geometry.keys.first { $0.key.kind == .character("m") }?.visualFrame
        let width = letter?.width ?? key.visualFrame.height
        let anchor = CGRect(
            x: track.current.location.x - width / 2,
            y: key.visualFrame.minY,
            width: width,
            height: key.visualFrame.height
        )
        let layout = CalloutGeometry.layout(
            anchor: anchor,
            optionCount: Self.punctuationMarks.count,
            metrics: context.geometry.metrics,
            bounds: context.calloutBounds
        )
        phase = .punctuation(layout: layout, selected: layout.optionIndex(atX: track.current.location.x))
        context.emit(.alternatesPresented)
    }

    private func enterTrackpad() {
        guard case .pressed = phase else { return }
        longPress?.cancel()
        longPress = nil
        context.composer.cancel(ticket)
        phase = .trackpad
        context.emit(.trackpadEngaged(bar: key.visualFrame))
    }

    private func moveCursor(with track: TouchTrack) {
        let x = track.current.location.x
        defer { lastX = x }
        guard let lastX else { return }

        let byWord = stepsByWord || abs(track.velocity.dx) >= Self.flingSpeed
        let step = byWord ? Self.wordStep : Self.stepLength(forSpeed: abs(track.velocity.dx))
        residual += x - lastX
        while abs(residual) >= step {
            let direction = residual < 0 ? -1 : 1
            guard self.step(direction, byWord: byWord) else {
                // At the end of the text: drop accumulated travel so reversing responds at once.
                residual = 0
                return
            }
            residual -= CGFloat(direction) * step
        }
    }

    @discardableResult
    private func step(_ direction: Int, byWord: Bool) -> Bool {
        let moved = context.perform(byWord ? .moveCursorByWord(direction) : .moveCursor(direction))
        if moved {
            context.emit(.cursorStep(direction: direction, byWord: byWord))
        }
        return moved
    }

    private func updateEdgeGlide(at x: CGFloat) {
        let width = context.geometry.size.width
        let direction = x <= Self.edgeZone ? -1 : (x >= width - Self.edgeZone ? 1 : 0)
        guard direction != edgeDirection else { return }
        edgeDirection = direction
        edgeTimer?.cancel()
        edgeTimer = nil
        if direction != 0 {
            scheduleEdgeStep()
        }
    }

    private func scheduleEdgeStep() {
        let interval = stepsByWord ? Self.edgeRepeat.word : Self.edgeRepeat.character
        edgeTimer = context.schedule(after: interval) { [weak self] in
            guard let self, case .trackpad = phase, edgeDirection != 0 else { return }
            if step(edgeDirection, byWord: stepsByWord) {
                scheduleEdgeStep()
            }
        }
    }

    private func finish() {
        longPress?.cancel()
        longPress = nil
        edgeTimer?.cancel()
        edgeTimer = nil
        if case .trackpad = phase {
            context.emit(.trackpadEnded)
        }
        phase = .finished
    }
}
