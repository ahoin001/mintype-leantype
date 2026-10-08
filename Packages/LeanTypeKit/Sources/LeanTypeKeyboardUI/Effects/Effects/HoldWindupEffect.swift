import LeanTypeCore
import LeanTypeDesign
import UIKit

/// A thin ring that draws itself around a key while a hold row is arming. It stays invisible
/// for the first moments, so a tap never flashes it, and it fades as the balloon grows out.
@MainActor
final class HoldWindupEffect: KeyboardEffect {
    static let minimumLevel = EffectsLevel.full

    private var ring: CAShapeLayer?
    /// A ring already fading out. Kept so a new hold, or `stop`, cannot recycle it twice.
    private var fading: CAShapeLayer?

    func handle(_ event: KeyboardEvent, in context: EffectContext) {
        switch event {
        case let .holdArmed(frame):
            arm(around: frame, in: context)
        case .alternatesPresented, .holdEnded:
            dismiss(in: context)
        default:
            break
        }
    }

    func stop(in context: EffectContext) {
        if let ring {
            context.pool.recycle(ring)
            self.ring = nil
        }
        if let fading {
            context.pool.recycle(fading)
            self.fading = nil
        }
    }

    // MARK: - Private

    private func arm(around frame: CGRect, in context: EffectContext) {
        dismiss(in: context)
        guard let ring = context.pool.shape() else { return }
        let rect = context.stage.rect(fromKeyArea: frame).insetBy(dx: -3, dy: -3)
        ring.frame = rect
        ring.path = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: rect.size),
            cornerRadius: min(styleRadius(for: rect), rect.height / 2)
        ).cgPath
        ring.fillColor = nil
        ring.strokeColor = context.palette.accent.cgColor
        ring.lineWidth = 1.5
        ring.strokeStart = 0
        ring.strokeEnd = 1
        ring.opacity = 0
        context.stage.present(ring)

        let duration = GestureTiming.longPress
        // A tap lifts before the ring is allowed to appear.
        let appear = 0.16 / duration
        let shown = 0.28 / duration
        let opacity = EffectAnimation.keyframes(
            "opacity",
            [0, 0, 1, 1],
            times: [
                NSNumber(value: 0),
                NSNumber(value: appear),
                NSNumber(value: shown),
                NSNumber(value: 1),
            ]
        )
        EffectAnimation.play(
            [opacity, EffectAnimation.basic("strokeEnd", from: 0, to: 1)],
            on: ring,
            duration: duration,
            timing: CAMediaTimingFunction(name: .linear)
        )
        self.ring = ring
    }

    private func dismiss(in context: EffectContext) {
        guard let ring else { return }
        let layer = ring
        self.ring = nil
        fading = layer
        let pool = context.pool
        let presented = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = 0
        EffectAnimation.play(
            [EffectAnimation.basic("opacity", from: presented, to: 0)],
            on: layer,
            duration: Motion.calloutPresent
        ) { [weak self] in
            guard self?.fading === layer else { return }
            self?.fading = nil
            pool.recycle(layer)
        }
    }

    private func styleRadius(for rect: CGRect) -> CGFloat {
        rect.height > 40 ? 12 : 10
    }
}
