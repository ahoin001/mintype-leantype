import CoreGraphics

/// Shift: toggles on touch-down (double tap locks caps), stays held while other fingers type,
/// and supports sliding from shift onto a letter to type a single capital.
///
/// A sideways flick deletes and restores the way delete does, so the left thumb can correct
/// without reaching across. Left erases letters as the finger moves. Back to the right puts
/// them back. A short slide right, lifted before it reaches a letter, restores the last
/// deletion. Reaching a letter still types that capital.
@MainActor
final class ShiftSession: InteractionSession {
    /// A flick must be this much more sideways than vertical before it deletes. Reaching a
    /// letter is an upward or landing move, and that still types the capital.
    static let horizontalBias: CGFloat = 1.25

    private unowned let context: any SessionContext
    private let key: KeyFrame
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
        self.context = context
        context.emit(.keyDown(.modifier, at: track.start.location))
        context.perform(.shiftPressBegan)
    }

    var presentation: SessionPresentation {
        guard !isFinished else { return .none }
        if let slideTarget {
            return SessionPresentation(pressedKey: slideTarget.id, callout: context.previewCallout(for: slideTarget))
        }
        return SessionPresentation(pressedKey: key.id)
    }

    func moved(_ track: TouchTrack) {
        guard !isFinished else { return }
        switch phase {
        case var .scrubbing(scrub):
            scrub.update(to: track.current.location.x, context: context)
            phase = .scrubbing(scrub)
        case .sliding:
            slideTarget = characterKey(at: track.current.location)
        case .shifting:
            if let characterKey = characterKey(at: track.current.location), !key.hitFrame.contains(track.current.location) {
                slideTarget = characterKey
                phase = .sliding
                return
            }
            guard isLeftwardDelete(track) else { return }
            context.perform(.shiftPressCancelled)
            phase = .scrubbing(DeletionScrub(anchorX: track.current.location.x, applied: 0, restoredWhole: false))
        }
    }

    func ended(_ track: TouchTrack) {
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
            if isRightwardRestore(track), context.perform(.restoreLastDeletion) {
                context.perform(.shiftPressCancelled)
                context.emit(.deleteStep)
            } else {
                context.perform(.shiftPressEnded)
            }
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

    private func isSideways(_ track: TouchTrack) -> Bool {
        abs(track.translation.dx) > abs(track.translation.dy) * Self.horizontalBias
    }

    private func isLeftwardDelete(_ track: TouchTrack) -> Bool {
        track.translation.dx <= -BackspaceSession.activationDistance && isSideways(track)
    }

    /// A rightward flick that never landed on a letter. Lifting there restores the last deletion.
    private func isRightwardRestore(_ track: TouchTrack) -> Bool {
        track.translation.dx >= BackspaceSession.activationDistance
            && isSideways(track)
            && characterKey(at: track.current.location) == nil
    }
}
