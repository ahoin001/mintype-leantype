import LeanTypeCore
import LeanTypeDesign
import UIKit

/// One pop on the backspace key when hold-to-delete steps up a gear. The key does not move,
/// and each deleted character stays haptic-only.
@MainActor
final class GearMarkEffect: KeyboardEffect {
    static let minimumLevel = EffectsLevel.full

    private var mark: CATextLayer?

    func handle(_ event: KeyboardEvent, in context: EffectContext) {
        guard case let .deleteEscalated(gear) = event, let key = context.stageFrame(of: .backspace) else { return }
        show(Self.title(for: gear), on: key, in: context)
    }

    func stop(in context: EffectContext) {
        guard let mark else { return }
        self.mark = nil
        context.pool.recycle(mark)
    }

    // MARK: - Private

    private func show(_ title: String, on key: CGRect, in context: EffectContext) {
        if let mark {
            self.mark = nil
            context.pool.recycle(mark)
        }
        guard let layer = context.pool.text() else { return }
        let font = fontFitting(title, in: key.width - 8)
        let color = context.palette.accent
        layer.string = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: color]
        )
        layer.bounds = CGRect(x: 0, y: 0, width: key.width, height: font.lineHeight + 2)
        layer.position = CGPoint(x: key.midX, y: key.midY)
        layer.opacity = 0
        context.stage.present(layer)
        mark = layer

        let pool = context.pool
        EffectAnimation.play(
            [
                EffectAnimation.keyframes("transform.scale", [0.86, 1.08, 1], times: [0, 0.45, 1]),
                EffectAnimation.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.18, 0.55, 1]),
            ],
            on: layer,
            duration: Motion.gearPop
        ) { [weak self] in
            guard self?.mark === layer else { return }
            self?.mark = nil
            pool.recycle(layer)
        }
    }

    private func fontFitting(_ title: String, in width: CGFloat) -> UIFont {
        var size: CGFloat = 13
        var font = Typography.rounded(size: size, weight: .bold)
        while size > 9, (title as NSString).size(withAttributes: [.font: font]).width > width {
            size -= 1
            font = Typography.rounded(size: size, weight: .bold)
        }
        return font
    }

    private static func title(for gear: DeleteGear) -> String {
        switch gear {
        case .character: "abc"
        case .word: "word"
        case .sentence: "sentence"
        }
    }
}
