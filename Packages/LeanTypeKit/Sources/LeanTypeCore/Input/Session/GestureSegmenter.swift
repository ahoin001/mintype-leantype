import CoreGraphics

/// Decides whether one finger's travel is still a tap or has become a stroke.
///
/// Distances match the tuned swipe thresholds: 16 pt sideways, 8 pt past the hit frame,
/// 36 pt in any direction. The long-travel check uses squared length so the hot path
/// never takes a square root.
enum GestureSegmenter {
    static let sidewaysDistance: CGFloat = 16
    static let strokeDistance: CGFloat = 36
    static let frameSlop: CGFloat = 8
    static var strokeDistanceSquared: CGFloat { strokeDistance * strokeDistance }

    struct Probe: Equatable, Sendable {
        var translation: CGVector
        var location: CGPoint
        var hitFrame: CGRect
        /// An upward digit flick still owns this finger. It is not a stroke yet.
        var holdsUpwardFlick: Bool
    }

    static func isStroke(_ probe: Probe, sidewaysThreshold: CGFloat = sidewaysDistance) -> Bool {
        if abs(probe.translation.dx) >= sidewaysThreshold { return true }
        if probe.holdsUpwardFlick { return false }
        let room = probe.hitFrame.insetBy(dx: -frameSlop, dy: -frameSlop)
        if !room.contains(probe.location) { return true }
        let dx = probe.translation.dx
        let dy = probe.translation.dy
        return dx * dx + dy * dy >= strokeDistanceSquared
    }
}
