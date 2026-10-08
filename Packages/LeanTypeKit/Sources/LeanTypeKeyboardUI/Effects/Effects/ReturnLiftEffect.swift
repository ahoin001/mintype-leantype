import LeanTypeCore
import LeanTypeDesign
import UIKit

/// A copy of the return glyph lifts off the key and fades. The key itself stays put.
@MainActor
final class ReturnLiftEffect: KeyboardEffect {
    static let minimumLevel = EffectsLevel.full

    private var glyph: CATextLayer?

    func handle(_ event: KeyboardEvent, in context: EffectContext) {
        guard case let .returnSent(title, frame) = event, frame.width > 1 else { return }
        lift(title, from: context.stage.rect(fromKeyArea: frame), in: context)
    }

    func stop(in context: EffectContext) {
        guard let glyph else { return }
        self.glyph = nil
        context.pool.recycle(glyph)
    }

    // MARK: - Private

    private func lift(_ title: String, from key: CGRect, in context: EffectContext) {
        if let glyph {
            self.glyph = nil
            context.pool.recycle(glyph)
        }
        guard let layer = context.pool.text() else { return }
        let compact = context.geometry?.metrics.isCompact ?? false
        let font = Typography.keyFont(.function, compact: compact)
        layer.string = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: context.palette.ink]
        )
        layer.bounds = CGRect(x: 0, y: 0, width: key.width, height: key.height)
        layer.position = CGPoint(x: key.midX, y: key.midY)
        layer.opacity = 1
        context.stage.present(layer)
        glyph = layer

        let away = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -Motion.returnLiftDistance, 0))
        let pool = context.pool
        EffectAnimation.play(
            [
                EffectAnimation.basic("transform", from: NSValue(caTransform3D: CATransform3DIdentity), to: away),
                EffectAnimation.basic("opacity", from: 1, to: 0),
            ],
            on: layer,
            duration: Motion.returnLift,
            timing: EffectAnimation.easeOut
        ) { [weak self] in
            guard self?.glyph === layer else { return }
            self?.glyph = nil
            pool.recycle(layer)
        }
    }
}
