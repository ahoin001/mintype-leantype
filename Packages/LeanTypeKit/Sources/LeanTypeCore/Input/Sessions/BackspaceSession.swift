import Foundation

/// Backspace, Nintype-style:
/// - Tap: delete the previous word (or one character, per settings).
/// - Hold: repeat that deletion, accelerating.
/// - Scrub left: delete one character per step. Scrub back right: restore them one by one.
/// - Swipe right without scrubbing first: restore the whole previous deletion (undo a word).
@MainActor
final class BackspaceSession: InteractionSession {
    static let activationDistance: CGFloat = 10
    static let scrubStep: CGFloat = 11
    static let holdDelay: TimeInterval = 0.45
    static let characterRepeat = RepeatTiming(initial: 0.1, minimum: 0.045, acceleration: 0.9)
    static let wordRepeat = RepeatTiming(initial: 0.28, minimum: 0.12, acceleration: 0.88)

    struct RepeatTiming {
        let initial: TimeInterval
        let minimum: TimeInterval
        let acceleration: Double
    }

    private enum Phase {
        case pressed
        case holding(interval: TimeInterval)
        case scrubbing(anchorX: CGFloat, applied: Int, restoredWhole: Bool)
        case finished
    }

    private unowned let context: any SessionContext
    private let key: KeyFrame
    private var phase = Phase.pressed
    private var timer: (any Cancellable)?

    init(key: KeyFrame, context: any SessionContext) {
        self.key = key
        self.context = context
        context.emit(.keyDown(.delete))
        timer = context.schedule(after: Self.holdDelay) { [weak self] in
            self?.beginHolding()
        }
    }

    var presentation: SessionPresentation {
        if case .finished = phase { return .none }
        return SessionPresentation(pressedKey: key.id)
    }

    private var tapIntent: KeyboardIntent {
        context.settings.backspaceTapAction == .deleteWord ? .deleteWord : .deleteCharacter
    }

    private var repeatTiming: RepeatTiming {
        context.settings.backspaceTapAction == .deleteWord ? Self.wordRepeat : Self.characterRepeat
    }

    func moved(_ track: TouchTrack) {
        switch phase {
        case .pressed:
            guard abs(track.translation.dx) >= Self.activationDistance else { return }
            stopTimer()
            phase = .scrubbing(anchorX: track.current.location.x, applied: 0, restoredWhole: false)
        case let .scrubbing(anchorX, applied, restoredWhole):
            scrub(to: track.current.location.x, anchorX: anchorX, applied: applied, restoredWhole: restoredWhole)
        case .holding, .finished:
            break
        }
    }

    func ended(_: TouchTrack) {
        if case .pressed = phase {
            context.perform(tapIntent)
        }
        finish()
    }

    func cancelled() {
        finish()
    }

    func otherTouchBegan() {}

    // MARK: - Hold to repeat

    private func beginHolding() {
        guard case .pressed = phase else { return }
        repeatDelete(interval: repeatTiming.initial)
    }

    private func repeatDelete(interval: TimeInterval) {
        guard context.perform(tapIntent) else {
            finish()
            return
        }
        context.emit(.deleteStep)
        phase = .holding(interval: interval)
        let next = max(interval * repeatTiming.acceleration, repeatTiming.minimum)
        timer = context.schedule(after: interval) { [weak self] in
            guard let self, case .holding = phase else { return }
            repeatDelete(interval: next)
        }
    }

    // MARK: - Scrubbing

    private func scrub(to x: CGFloat, anchorX: CGFloat, applied: Int, restoredWhole: Bool) {
        var anchorX = anchorX
        var applied = applied
        var restoredWhole = restoredWhole
        let target = Int(((anchorX - x) / Self.scrubStep).rounded(.towardZero))

        while applied < target {
            guard context.perform(.deleteCharacter) else {
                anchorX = x + CGFloat(applied) * Self.scrubStep
                break
            }
            applied += 1
            context.emit(.deleteStep)
        }

        while applied > max(target, 0) {
            guard context.perform(.restoreCharacter) else {
                applied = 0
                anchorX = x
                break
            }
            applied -= 1
            context.emit(.deleteStep)
        }

        if target < 0, applied == 0, !restoredWhole {
            restoredWhole = true
            if context.perform(.restoreLastDeletion) {
                context.emit(.deleteStep)
            }
        }

        phase = .scrubbing(anchorX: anchorX, applied: applied, restoredWhole: restoredWhole)
    }

    // MARK: - Lifecycle

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func finish() {
        stopTimer()
        phase = .finished
    }
}
