import LeanTypeCore
import UIKit

/// A soft ring that blooms from exactly where a letter was touched. In flow, each ripple
/// takes the next hue around the wheel, so steady typing paints a slow rainbow.
@MainActor
final class RippleEffect: KeyboardEffect {
    static let minimumLevel = EffectsLevel.full
    static let duration: CFTimeInterval = 0.34
    /// Flow above which ripples start shifting hue.
    static let prismFlow = 0.55

    private var hueStep: CGFloat = 0

    func handle(_ event: KeyboardEvent, in context: EffectContext) {
        guard case let .keyDown(.character, point) = event, let layer = context.pool.shape() else { return }

        let radius = min(context.keySize.width, context.keySize.height) * 0.62
        layer.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)).cgPath
        layer.position = context.stage.point(fromKeyArea: point)
        layer.bounds = .zero

        let color: UIColor
        if context.flow.value >= Self.prismFlow {
            hueStep = (hueStep + 0.07).truncatingRemainder(dividingBy: 1)
            color = context.palette.shifted(by: hueStep)
        } else {
            color = context.palette.accent
        }
        let strength = Float(min(context.intensity, 1.2)) * (0.45 + 0.35 * Float(context.flow.value))
        layer.fillColor = color.withAlphaComponent(0.16).cgColor
        layer.strokeColor = color.withAlphaComponent(0.7).cgColor
        layer.lineWidth = 1.5
        context.stage.present(layer)

        let pool = context.pool
        EffectAnimation.play(
            [
                EffectAnimation.basic("transform.scale", from: 0.3, to: 1 + 0.3 * context.intensity),
                EffectAnimation.basic("opacity", from: strength, to: 0),
                EffectAnimation.basic("lineWidth", from: 2.5, to: 0.5),
            ],
            on: layer,
            duration: Self.duration
        ) { pool.recycle(layer) }
    }

    func stop(in _: EffectContext) {
        hueStep = 0
    }
}
