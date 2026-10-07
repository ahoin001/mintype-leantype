import LeanTypeCore
import UIKit

/// A halo that settles around the shift key when caps lock engages and stays while it's on.
@MainActor
final class CapsHaloEffect: KeyboardEffect {
    static let minimumLevel = EffectsLevel.reduced

    private var halo: CAShapeLayer?

    func handle(_ event: KeyboardEvent, in context: EffectContext) {
        guard case .capsLockEngaged = event, halo == nil,
              let frame = context.stageFrame(of: .shift), let layer = context.pool.shape()
        else { return }

        let ring = frame.insetBy(dx: -3, dy: -3)
        layer.frame = ring
        layer.path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: ring.size), cornerRadius: 11).cgPath
        layer.fillColor = nil
        layer.strokeColor = context.palette.accent.cgColor
        layer.lineWidth = 2
        layer.opacity = 0.75
        context.stage.present(layer)
        halo = layer

        let pulse = context.level == .full
            ? [EffectAnimation.keyframes("transform.scale", [1.35, 0.96, 1], times: [0, 0.6, 1])]
            : []
        EffectAnimation.play(pulse + [EffectAnimation.basic("opacity", from: 0, to: 0.75)], on: layer, duration: 0.36)
    }

    /// Caps lock turned off (or the shift key moved): let the halo go.
    func capsLockEnded(in context: EffectContext) {
        stop(in: context)
    }

    func contextDidChange(_ context: EffectContext) {
        guard let halo, let frame = context.stageFrame(of: .shift) else { return }
        halo.frame = frame.insetBy(dx: -3, dy: -3)
        halo.strokeColor = context.palette.accent.cgColor
    }

    func stop(in context: EffectContext) {
        guard let halo else { return }
        self.halo = nil
        let pool = context.pool
        EffectAnimation.play([EffectAnimation.basic("opacity", from: halo.opacity, to: 0)], on: halo, duration: 0.2) {
            pool.recycle(halo)
        }
    }
}
