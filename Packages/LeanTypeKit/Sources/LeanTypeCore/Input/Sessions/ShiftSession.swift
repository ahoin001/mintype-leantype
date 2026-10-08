import CoreGraphics

/// Shift: toggles on touch-down (double tap locks caps) and stays held while other fingers type.
///
/// A sideways flick is a delete scrub for the rest of the touch, same as delete. The finger
/// may cross Z, X, and C; those letters are not typed and the path is not a word. Left, toward
/// the edge, deletes. Right, back toward the letters, restores. Before that lock, rising onto
/// a letter above shift still types that one capital.
@MainActor
final class ShiftSession: InteractionSession {
    /// A flick must be this much more sideways than vertical before it deletes. Rising onto
    /// the letter above is still a capital.
    static let horizontalBias: CGFloat = 1.25

    private unowned let context: any SessionContext
    private let key: KeyFrame
    private var finger: CGPoint
    private var slideTarget: KeyFrame?
    private var phase = Phase.shifting
    private var isFinished = false

    private enum Phase {
        case shifting
        case sliding
        case scrubbing(DeletionScrub)
    }

    init(key: KeyFrame, track: TouchTrack, context: any SessionContext) {
        self.key = key
        self.finger = track.start.location
        self.context = context
        context.emit(.keyDown(.modifier, at: track.start.location))
        context.perform(.shiftPressBegan)
    }

    var presentation: SessionPresentation {
        guard !isFinished else { return .none }
        switch phase {
        case let .scrubbing(scrub):
            return SessionPresentation(
                pressedKey: key.id,
                jewel: GestureMark(contact: finger, action: .scrub(scrub.mark(on: key.id)))
            )
        case .sliding:
            if let slideTarget {
                return SessionPresentation(pressedKey: slideTarget.id, callout: context.previewCallout(for: slideTarget))
            }
            return SessionPresentation(pressedKey: key.id)
        case .shifting:
            return SessionPresentation(pressedKey: key.id)
        }
    }

    func moved(_ track: TouchTrack) {
        guard !isFinished else { return }
        finger = track.current.location
        switch phase {
        case var .scrubbing(scrub):
            scrub.update(to: track.current.location.x, context: context)
            phase = .scrubbing(scrub)
        case .sliding:
            slideTarget = characterKey(at: track.current.location)
        case .shifting:
            let point = track.current.location
            if let characterKey = characterKey(at: point), !isOnShiftRow(point) {
                slideTarget = characterKey
                phase = .sliding
                return
            }
            guard locksScrub(track) else { return }
            context.perform(.shiftPressCancelled)
            phase = .scrubbing(DeletionScrub(
                anchorX: point.x,
                applied: 0,
                restoredWhole: false,
                inward: 1
            ))
        }
    }

    func ended(_: TouchTrack) {
        guard !isFinished else { return }
        switch phase {
        case .scrubbing:
            break
        case .sliding:
            if let character = slideTarget?.key.kind.character {
                context.perform(.insert(character))
            }
            context.perform(.shiftPressEnded)
        case .shifting:
            context.perform(.shiftPressEnded)
        }
        isFinished = true
    }

    func cancelled() {
        guard !isFinished else { return }
        if case .scrubbing = phase {
            // The press was already given back when the flick became a delete.
        } else {
            context.perform(.shiftPressEnded)
        }
        isFinished = true
    }

    func otherTouchBegan(on _: KeyFrame) {}

    // MARK: - Deciding

    private func characterKey(at point: CGPoint) -> KeyFrame? {
        context.geometry.key(at: point).flatMap { $0.key.kind.isCharacter ? $0 : nil }
    }

    /// The row shift sits on. Z is on it; A is the row above, so a rise onto A is still a capital.
    private func isOnShiftRow(_ point: CGPoint) -> Bool {
        context.geometry.key(at: point)?.row == key.row
    }

    private func locksScrub(_ track: TouchTrack) -> Bool {
        let dx = track.translation.dx
        let dy = track.translation.dy
        return abs(dx) >= BackspaceSession.activationDistance
            && abs(dx) > abs(dy) * Self.horizontalBias
            && isOnShiftRow(track.current.location)
    }
}
