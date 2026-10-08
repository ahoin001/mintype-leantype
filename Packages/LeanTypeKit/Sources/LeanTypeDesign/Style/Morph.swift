import CoreGraphics
import Foundation

/// How a rectangle changes into the next one.
///
/// The shape is decided here, as samples a driver can play on the render server. Callers pick
/// a kind; they do not invent their own curves. Reduce Motion passes `travels: false`, which
/// moves every edge together and skips the squeeze and the overshoot.
public enum Morph {
    /// The edge in the direction of travel arrives first; the other edge follows.
    case stretch
    /// Pinches through the middle, then rests on the destination. A landing or a correction.
    case settle
    /// Grows out of the start and passes the destination before resting on it.
    case expand
    /// Shrinks back. Starts slower than it finishes, with no overshoot.
    case contract

    public struct Sample: Equatable, Sendable {
        public var time: CGFloat
        public var frame: CGRect
    }

    /// One morph, ready to play. `contentReveal` is the fraction of `duration` before contents
    /// should appear. The shape leads; the label follows.
    public struct Plan: Equatable, Sendable {
        public var samples: [Sample]
        public var duration: TimeInterval
        public var contentReveal: CGFloat
    }

    public static func plan(
        from: CGRect,
        to: CGRect,
        kind: Morph,
        duration: TimeInterval,
        travels: Bool
    ) -> Plan {
        let times = sampleTimes(for: kind, travels: travels)
        let samples = times.map { time in
            Sample(time: time, frame: frame(from: from, to: to, kind: kind, progress: time, travels: travels))
        }
        let reveal = kind == .expand && travels ? CGFloat(Motion.contentDelay / Motion.modeChange) : 0
        return Plan(samples: samples, duration: duration, contentReveal: min(max(reveal, 0), 0.9))
    }

    /// The rectangle at `progress` (0...1) along this morph.
    public static func frame(
        from: CGRect,
        to: CGRect,
        kind: Morph,
        progress: CGFloat,
        travels: Bool
    ) -> CGRect {
        let t = min(max(progress, 0), 1)
        guard travels else { return lerp(from, to, t) }
        switch kind {
        case .stretch:
            return stretched(from, to, t)
        case .settle:
            return pinched(lerp(from, to, easeOut(t)), amount: sin(t * .pi) * 0.07)
        case .expand:
            let overshot = scaled(to, by: 1.045)
            if t <= 0.75 {
                return lerp(from, overshot, easeOut(t / 0.75))
            }
            return lerp(overshot, to, (t - 0.75) / 0.25)
        case .contract:
            return lerp(from, to, t * t)
        }
    }

    // MARK: - Private

    private static func sampleTimes(for kind: Morph, travels: Bool) -> [CGFloat] {
        guard travels else { return [0, 1] }
        switch kind {
        case .stretch: [0, 0.45, 1]
        case .settle: [0, 0.5, 1]
        case .expand: [0, 0.75, 1]
        case .contract: [0, 0.5, 1]
        }
    }

    /// Leading edge uses a faster clock than the trailing edge, so the rectangle stretches
    /// and then catches up.
    private static func stretched(_ from: CGRect, _ to: CGRect, _ progress: CGFloat) -> CGRect {
        let lead = easeOut(min(1, progress / 0.62))
        let trail = easeOut(max(0, (progress - 0.28) / 0.72))
        let rightward = to.midX >= from.midX
        let minX = from.minX + (to.minX - from.minX) * (rightward ? trail : lead)
        let maxX = from.maxX + (to.maxX - from.maxX) * (rightward ? lead : trail)
        let vertical = max(lead, trail)
        let minY = from.minY + (to.minY - from.minY) * vertical
        let maxY = from.maxY + (to.maxY - from.maxY) * vertical
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }

    private static func lerp(_ from: CGRect, _ to: CGRect, _ progress: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * progress,
            y: from.minY + (to.minY - from.minY) * progress,
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress
        )
    }

    private static func scaled(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        let growX = rect.width * (factor - 1) / 2
        let growY = rect.height * (factor - 1) / 2
        return rect.insetBy(dx: -growX, dy: -growY)
    }

    private static func pinched(_ rect: CGRect, amount: CGFloat) -> CGRect {
        rect.insetBy(dx: rect.width * amount, dy: rect.height * amount * 0.35)
    }

    private static func easeOut(_ progress: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return 1 - (1 - t) * (1 - t)
    }
}
