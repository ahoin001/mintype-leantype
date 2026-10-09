import LeanTypeCore
import LeanTypeDesign
import UIKit

/// A burst of sparkles when a sentence ends with a double-space period, and a bigger shower
/// with a little badge in the dock when a clean-typing streak hits a milestone.
///
/// One emitter is reused for every burst, and it only emits for a split second.
@MainActor
final class SparkleEffect: KeyboardEffect {
    static let minimumLevel = EffectsLevel.full
    static let burstDuration: TimeInterval = 0.08

    private var emitter: CAEmitterLayer?
    private var burstGeneration = 0

    func handle(_ event: KeyboardEvent, in context: EffectContext) {
        switch event {
        case .sentenceEnded:
            let dock = context.stage.dockFrame
            burst(at: CGPoint(x: dock.midX, y: dock.minY + 8), count: 70, speed: 70, in: context)
        case let .flowMilestone(streak):
            let dock = context.stage.dockFrame
            burst(at: CGPoint(x: dock.midX, y: dock.maxY), count: 420, speed: 190, in: context)
            showBadge("\(streak) clean words", in: context)
        default:
            break
        }
    }

    func contextDidChange(_ context: EffectContext) {
        emitter?.emitterCells = makeCells(context)
    }

    func stop(in _: EffectContext) {
        emitter?.birthRate = 0
        emitter?.removeFromSuperlayer()
        emitter = nil
    }

    // MARK: - Private

    private func burst(at point: CGPoint, count: Float, speed: CGFloat, in context: EffectContext) {
        let emitter = emitter ?? makeEmitter(context)
        emitter.emitterPosition = point
        emitter.emitterSize = CGSize(width: 24, height: 6)
        emitter.velocity = Float(speed / 100)
        emitter.birthRate = count * Float(context.intensity) / Float(Self.burstDuration * 100)
        // Start immediately rather than at the layer's own (possibly stale) local time.
        emitter.beginTime = emitter.convertTime(CACurrentMediaTime(), from: nil)

        burstGeneration += 1
        let generation = burstGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.burstGeneration == generation else { return }
                self.emitter?.birthRate = 0
            }
        }
    }

    private func makeEmitter(_ context: EffectContext) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .rectangle
        emitter.renderMode = .additive
        emitter.birthRate = 0
        emitter.emitterCells = makeCells(context)
        emitter.frame = context.stage.bounds
        context.stage.layer.addSublayer(emitter)
        self.emitter = emitter
        return emitter
    }

    private func makeCells(_ context: EffectContext) -> [CAEmitterCell] {
        context.palette.prism(count: 3).map { color in
            let cell = CAEmitterCell()
            cell.contents = ParticleSprite.dot
            cell.color = color
            cell.birthRate = 100
            cell.lifetime = 0.75
            cell.lifetimeRange = 0.25
            cell.velocity = 100
            cell.velocityRange = 60
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi * 2
            cell.yAcceleration = 160
            cell.scale = 0.32
            cell.scaleRange = 0.18
            cell.scaleSpeed = -0.3
            cell.alphaSpeed = -1.2
            cell.spin = 2
            cell.spinRange = 4
            return cell
        }
    }

    private func showBadge(_ text: String, in context: EffectContext) {
        guard let layer = context.pool.text() else { return }
        let font = Typography.rounded(size: 13, weight: .bold)
        let string = NSAttributedString(string: "✦ " + text, attributes: [.font: font, .foregroundColor: context.palette.accent])
        let size = string.size()
        let dock = context.stage.dockFrame
        layer.string = string
        layer.bounds = CGRect(x: 0, y: 0, width: size.width.rounded(.up) + 4, height: size.height.rounded(.up))
        layer.position = CGPoint(x: dock.midX, y: dock.midY)
        context.stage.present(layer)

        let pool = context.pool
        EffectAnimation.play(
            [
                EffectAnimation.keyframes("transform.scale", [0.6, 1.08, 1, 1, 0.9], times: [0, 0.12, 0.2, 0.85, 1]),
                EffectAnimation.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.1, 0.8, 1]),
            ],
            on: layer,
            duration: 1.6,
            timing: EffectAnimation.easeInOut
        ) { pool.recycle(layer) }
    }
}
