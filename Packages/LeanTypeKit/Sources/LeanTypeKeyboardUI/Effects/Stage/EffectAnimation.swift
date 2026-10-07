import UIKit

/// Small builders for the Core Animation effects use. Everything runs on the render server;
/// the app's main thread only sets the animation up.
@MainActor
enum EffectAnimation {
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.5)
    static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)

    static func basic(_ keyPath: String, from: Any?, to: Any?) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    static func keyframes(_ keyPath: String, _ values: [Any], times: [NSNumber]? = nil) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        return animation
    }

    /// Runs `animations` together on `layer`, then calls `completion` (usually to recycle it).
    static func play(
        _ animations: [CAAnimation],
        on layer: CALayer,
        duration: CFTimeInterval,
        delay: CFTimeInterval = 0,
        timing: CAMediaTimingFunction = easeOut,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = timing
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        if delay > 0 {
            group.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion?() }
        }
        layer.add(group, forKey: "effect")
        CATransaction.commit()
    }
}
