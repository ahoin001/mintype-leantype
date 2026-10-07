import LeanTypeCore
import UIKit

/// While the space bar is a trackpad, a small comet rides it: every cursor step nudges the
/// head along and stretches a tail behind it, so the cursor's motion is felt on the keyboard.
@MainActor
final class CometEffect: KeyboardEffect {
    static let minimumLevel = EffectsLevel.full
    static let headRadius: CGFloat = 4.5
    static let characterStride: CGFloat = 7
    static let wordStride: CGFloat = 22

    private var head: CAShapeLayer?
    private var tail: CAShapeLayer?
    private var bar: CGRect = .zero
    private var x: CGFloat = 0

    func handle(_ event: KeyboardEvent, in context: EffectContext) {
        switch event {
        case let .trackpadEngaged(barFrame):
            begin(on: context.stage.rect(fromKeyArea: barFrame), in: context)
        case let .cursorStep(direction, byWord):
            step(direction, byWord: byWord)
        case .trackpadEnded:
            stop(in: context)
        default:
            break
        }
    }

    func stop(in context: EffectContext) {
        for layer in [head, tail].compactMap({ $0 }) {
            let pool = context.pool
            EffectAnimation.play([EffectAnimation.basic("opacity", from: layer.opacity, to: 0)], on: layer, duration: 0.18) {
                pool.recycle(layer)
            }
        }
        head = nil
        tail = nil
    }

    // MARK: - Private

    private func begin(on barFrame: CGRect, in context: EffectContext) {
        stop(in: context)
        guard let head = context.pool.shape(), let tail = context.pool.shape() else { return }
        bar = barFrame.insetBy(dx: 14, dy: 0)
        x = bar.midX

        let radius = Self.headRadius * max(context.intensity, 0.8)
        head.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)).cgPath
        head.fillColor = context.palette.accent.cgColor
        head.strokeColor = nil
        head.position = CGPoint(x: x, y: bar.midY)
        tail.fillColor = context.palette.accent.withAlphaComponent(0.35).cgColor
        tail.strokeColor = nil
        tail.position = .zero
        tail.path = nil
        context.stage.present(tail)
        context.stage.present(head)
        EffectAnimation.play(
            [EffectAnimation.basic("opacity", from: 0, to: 1), EffectAnimation.basic("transform.scale", from: 0.2, to: 1)],
            on: head,
            duration: 0.22
        )
        self.head = head
        self.tail = tail
    }

    private func step(_ direction: Int, byWord: Bool) {
        guard let head, let tail else { return }
        let stride = (byWord ? Self.wordStride : Self.characterStride) * CGFloat(direction.signum())
        let previous = x
        x += stride
        // Wrap around the bar so long drags keep moving rather than pinning at an edge.
        if x > bar.maxX { x = bar.minX + (x - bar.maxX) }
        if x < bar.minX { x = bar.maxX - (bar.minX - x) }
        let wrapped = abs(x - previous) > abs(stride) * 1.5

        head.position = CGPoint(x: x, y: bar.midY)
        guard !wrapped else { return }
        let animation = EffectAnimation.basic("position", from: NSValue(cgPoint: CGPoint(x: previous, y: bar.midY)), to: NSValue(cgPoint: head.position))
        animation.duration = 0.09
        animation.timingFunction = EffectAnimation.easeOut
        head.add(animation, forKey: "move")

        let length = abs(stride) * (byWord ? 2.2 : 3.2)
        let tailRect = CGRect(
            x: direction > 0 ? x - length : x,
            y: bar.midY - Self.headRadius * 0.8,
            width: length,
            height: Self.headRadius * 1.6
        )
        tail.path = UIBezierPath(roundedRect: tailRect, cornerRadius: Self.headRadius).cgPath
        tail.add(EffectAnimation.basic("opacity", from: 1, to: 0).with(duration: 0.28), forKey: "fade")
        tail.opacity = 0
    }
}

extension CAAnimation {
    func with(duration: CFTimeInterval) -> Self {
        self.duration = duration
        return self
    }
}
