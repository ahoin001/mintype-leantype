import LeanTypeCore
import UIKit

/// An ambient glow that rises behind the keys as typing finds its rhythm, warming toward a
/// prism blend at high flow. One gradient layer, updated only when the flow step changes.
@MainActor
final class FlowGlowEffect: KeyboardEffect {
    static let minimumLevel = EffectsLevel.reduced
    /// Flow above which the glow blends into the prism (full effects only).
    static let prismFlow = 0.7

    private var glow: CAGradientLayer?

    func handle(_ event: KeyboardEvent, in context: EffectContext) {
        guard case .flowChanged = event else { return }
        update(context, animated: true)
    }

    func contextDidChange(_ context: EffectContext) {
        update(context, animated: false)
    }

    func stop(in _: EffectContext) {
        glow?.removeFromSuperlayer()
        glow = nil
    }

    // MARK: - Private

    private func update(_ context: EffectContext, animated: Bool) {
        let flow = context.flow.value
        guard flow > 0 || glow != nil else { return }
        let glow = glow ?? makeGlow(context)
        glow.frame = context.stage.backdrop.bounds

        let accent = context.palette.accent
        let top: UIColor
        let bottom: UIColor
        if flow >= Self.prismFlow, context.level == .full {
            top = context.palette.shifted(by: 0.18 * CGFloat(flow))
            bottom = context.palette.shifted(by: -0.12 * CGFloat(flow))
        } else {
            top = accent
            bottom = accent
        }
        let peak = (context.palette.isDark ? 0.3 : 0.22) * min(context.intensity, 1.2)
        let opacity = Float(pow(flow, 1.4) * peak)

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.6 : 0)
        CATransaction.setDisableActions(!animated)
        glow.colors = [top.withAlphaComponent(0).cgColor, top.withAlphaComponent(0.5).cgColor, bottom.cgColor]
        glow.opacity = opacity
        CATransaction.commit()
    }

    private func makeGlow(_ context: EffectContext) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.locations = [0, 0.55, 1]
        layer.opacity = 0
        context.stage.backdrop.addSublayer(layer)
        glow = layer
        return layer
    }
}
