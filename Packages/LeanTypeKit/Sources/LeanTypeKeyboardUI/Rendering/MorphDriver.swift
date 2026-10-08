import LeanTypeDesign
import UIKit

/// Plays a `Morph` plan on a layer. The model jumps to the destination so layout reads the
/// resting frame; the presentation walks the samples. A new move starts from wherever the
/// previous one was drawn, so a fast change interrupts instead of queueing.
@MainActor
enum MorphDriver {
    private static let animationKey = "morph"

    static func move(
        _ view: UIView,
        to target: CGRect,
        kind: Morph,
        duration: TimeInterval,
        travels: Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        move(view.layer, to: target, kind: kind, duration: duration, travels: travels, completion: completion)
    }

    static func move(
        _ layer: CALayer,
        to target: CGRect,
        kind: Morph,
        duration: TimeInterval,
        travels: Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let presented = layer.presentation()?.frame ?? layer.frame
        let plan = Morph.plan(from: presented, to: target, kind: kind, duration: duration, travels: travels)
        let poses = travels && plan.samples.contains { !nearly($0.frame, target) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: animationKey)
        layer.frame = target
        guard poses else {
            CATransaction.commit()
            completion?()
            return
        }

        layer.add(animation(for: plan), forKey: animationKey)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion?() }
        }
        CATransaction.commit()
    }

    /// Fades contents in after the shape has led. A zero delay shows them immediately.
    static func reveal(_ view: UIView, after delay: TimeInterval, travels: Bool) {
        view.layer.removeAllAnimations()
        view.alpha = 0
        UIView.animate(
            withDuration: 0.1,
            delay: travels ? delay : 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            view.alpha = 1
        }
    }

    // MARK: - Private

    private static func animation(for plan: Morph.Plan) -> CAAnimation {
        let times = plan.samples.map { NSNumber(value: Double($0.time)) }
        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = plan.samples.map { NSValue(cgPoint: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        position.keyTimes = times
        let bounds = CAKeyframeAnimation(keyPath: "bounds")
        bounds.values = plan.samples.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.frame.size)) }
        bounds.keyTimes = times

        let group = CAAnimationGroup()
        group.animations = [position, bounds]
        group.duration = plan.duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.fillMode = .both
        group.isRemovedOnCompletion = true
        return group
    }

    private static func nearly(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5
            && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }
}
