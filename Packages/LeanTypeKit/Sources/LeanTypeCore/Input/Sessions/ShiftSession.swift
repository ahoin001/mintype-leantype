import CoreGraphics

/// Shift: toggles on touch-down (double tap locks caps), stays held while other fingers type,
/// and supports sliding from shift onto a letter to type a single capital.
@MainActor
final class ShiftSession: InteractionSession {
    private unowned let context: any SessionContext
    private let key: KeyFrame
    private var slideTarget: KeyFrame?
    private var hasLeftKey = false
    private var isFinished = false

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
        let point = track.current.location
        if !hasLeftKey {
            hasLeftKey = !key.hitFrame.contains(point)
        }
        guard hasLeftKey else { return }
        slideTarget = context.geometry.key(at: point).flatMap { $0.key.kind.isCharacter ? $0 : nil }
    }

    func ended(_: TouchTrack) {
        guard !isFinished else { return }
        if let character = slideTarget?.key.kind.character {
            context.perform(.insert(character))
        }
        context.perform(.shiftPressEnded)
        isFinished = true
    }

    func cancelled() {
        guard !isFinished else { return }
        context.perform(.shiftPressEnded)
        isFinished = true
    }

    func otherTouchBegan() {}
}
