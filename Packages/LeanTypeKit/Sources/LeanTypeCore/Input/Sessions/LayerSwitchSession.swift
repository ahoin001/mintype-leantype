import CoreGraphics

/// The 123 / ABC / #+= keys. The layer switches on touch-down so the finger can slide straight
/// onto a symbol; releasing on one types it and returns to the original layer.
@MainActor
final class LayerSwitchSession: InteractionSession {
    private unowned let context: any SessionContext
    private let origin: KeyFrame
    private let originLayer: KeyboardLayer
    private let startPoint: CGPoint
    private let ticket: InputComposer.Ticket
    private var slideTarget: KeyFrame?
    private var hasLeftKey = false
    private var isFinished = false

    init(key: KeyFrame, target: KeyboardLayer, track: TouchTrack, context: any SessionContext) {
        self.context = context
        origin = key
        originLayer = context.currentLayer
        startPoint = track.start.location
        ticket = context.composer.reserve()
        context.emit(.keyDown(.modifier))
        context.perform(.switchLayer(target))
    }

    var presentation: SessionPresentation {
        guard !isFinished else { return .none }
        if let slideTarget {
            return SessionPresentation(pressedKey: slideTarget.id, callout: context.previewCallout(for: slideTarget))
        }
        // The switch key under the finger now belongs to the new layer, with a new identity.
        let current = context.geometry.key(at: startPoint)
        return SessionPresentation(pressedKey: current?.id)
    }

    func moved(_ track: TouchTrack) {
        guard !isFinished else { return }
        let point = track.current.location
        if !hasLeftKey {
            hasLeftKey = !origin.hitFrame.contains(point)
        }
        guard hasLeftKey else { return }
        slideTarget = context.geometry.key(at: point).flatMap { frame in
            switch frame.key.kind {
            case .character, .space: frame
            default: nil
            }
        }
    }

    func ended(_: TouchTrack) {
        guard !isFinished else { return }
        switch slideTarget?.key.kind {
        case let .character(character):
            context.composer.commit(ticket, [.insert(character), .switchLayer(originLayer)])
        case .space:
            context.composer.commit(ticket, [.space])
        default:
            context.composer.cancel(ticket)
        }
        isFinished = true
    }

    func cancelled() {
        guard !isFinished else { return }
        context.composer.cancel(ticket)
        isFinished = true
    }

    func otherTouchBegan() {
        guard !isFinished, slideTarget == nil else { return }
        context.composer.cancel(ticket)
        isFinished = true
    }
}
