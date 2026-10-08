import Foundation

/// Backspace, Nintype-style:
/// - Tap: undo the latest autocorrection or swiped word if the cursor is right after it;
///   otherwise delete the previous word (or one character, per settings).
/// - Hold: repeat that deletion, accelerating, and shift up a gear (characters, words,
///   sentences) the longer it's held.
/// - Scrub left: delete one character per step. Scrub back right: restore them one by one.
/// - Swipe right without scrubbing first: restore the whole previous deletion (undo a word).
@MainActor
final class BackspaceSession: InteractionSession {
    static let activationDistance: CGFloat = 10
    static let scrubStep: CGFloat = 11
    static let holdDelay: TimeInterval = 0.45
    /// Time spent repeating in one gear before shifting up to the next.
    static let escalationDelay: TimeInterval = 1.5
    nonisolated static let characterRepeat = RepeatTiming(initial: 0.1, minimum: 0.045, acceleration: 0.9)
    nonisolated static let wordRepeat = RepeatTiming(initial: 0.28, minimum: 0.12, acceleration: 0.88)
    nonisolated static let sentenceRepeat = RepeatTiming(initial: 0.5, minimum: 0.35, acceleration: 0.92)

    struct RepeatTiming: Sendable {
        let initial: TimeInterval
        let minimum: TimeInterval
        let acceleration: Double
    }

    /// One gear of hold-to-delete.
    enum Gear: Int, Comparable {
        case character
        case word
        case sentence

        var intent: KeyboardIntent {
            switch self {
            case .character: .deleteCharacter
            case .word: .deleteWord
            case .sentence: .deleteSentence
            }
        }

        var timing: RepeatTiming {
            switch self {
            case .character: BackspaceSession.characterRepeat
            case .word: BackspaceSession.wordRepeat
            case .sentence: BackspaceSession.sentenceRepeat
            }
        }

        var next: Gear? { Gear(rawValue: rawValue + 1) }

        var reported: DeleteGear {
            switch self {
            case .character: .character
            case .word: .word
            case .sentence: .sentence
            }
        }

        static func < (lhs: Gear, rhs: Gear) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private enum Phase {
        case pressed
        case holding(gear: Gear, interval: TimeInterval, timeInGear: TimeInterval)
        case scrubbing(anchorX: CGFloat, applied: Int, restoredWhole: Bool)
        case finished
    }

    private unowned let context: any SessionContext
    private let key: KeyFrame
    private var phase = Phase.pressed
    private var timer: (any Cancellable)?

    init(key: KeyFrame, track: TouchTrack, context: any SessionContext) {
        self.key = key
        self.context = context
        context.emit(.keyDown(.delete, at: track.start.location))
        timer = context.schedule(after: Self.holdDelay) { [weak self] in
            self?.beginHolding()
        }
    }

    var presentation: SessionPresentation {
        if case .finished = phase { return .none }
        return SessionPresentation(pressedKey: key.id)
    }

    private var tapGear: Gear {
        context.settings.backspaceTapAction == .deleteWord ? .word : .character
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
        if case .pressed = phase, !context.perform(.undoRecentCommit) {
            context.perform(tapGear.intent)
        }
        finish()
    }

    func cancelled() {
        finish()
    }

    func otherTouchBegan(on _: KeyFrame) {}

    // MARK: - Hold to repeat

    private func beginHolding() {
        guard case .pressed = phase else { return }
        repeatDelete(gear: tapGear, interval: tapGear.timing.initial, timeInGear: 0)
    }

    private func repeatDelete(gear: Gear, interval: TimeInterval, timeInGear: TimeInterval) {
        guard context.perform(gear.intent) else {
            finish()
            return
        }
        context.emit(.deleteStep)
        phase = .holding(gear: gear, interval: interval, timeInGear: timeInGear)

        var gear = gear
        var timeInGear = timeInGear + interval
        var next = max(interval * gear.timing.acceleration, gear.timing.minimum)
        if timeInGear >= Self.escalationDelay, let higher = gear.next {
            gear = higher
            timeInGear = 0
            next = higher.timing.initial
            context.emit(.deleteEscalated(higher.reported))
        }
        timer = context.schedule(after: interval) { [weak self] in
            guard let self, case .holding = phase else { return }
            repeatDelete(gear: gear, interval: next, timeInGear: timeInGear)
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
