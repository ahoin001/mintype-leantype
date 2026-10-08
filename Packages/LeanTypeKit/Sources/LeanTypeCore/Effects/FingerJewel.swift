import CoreGraphics

/// Where a swipe's decoration sits so the fingertip does not hide it.
///
/// The contact stays unmarked. A ring clears the finger. The bead rides the trailing rim,
/// and the trail is drawn from that bead backward. The recorded path is not rewritten.
public struct FingerJewel: Equatable, Sendable {
    /// Resting ring radius, in points. Wide enough that a thumb does not swallow the ring.
    public static let baseRadius: CGFloat = 34
    /// How far the ring center may sit behind a moving finger, in points.
    public static let lag: CGFloat = 6

    public struct Sample: Equatable, Sendable {
        public var location: CGPoint
        public var time: Double

        public init(location: CGPoint, time: Double) {
            self.location = location
            self.time = time
        }
    }

    public var radius: CGFloat
    public var center: CGPoint
    /// On the rim. Behind the finger while it is moving.
    public var bead: CGPoint
    /// Unit direction of travel. Zero while the finger is still.
    public var direction: CGVector
    /// A moving finger has a trail. A still one keeps the bead on the ring and draws no path.
    public var drawsTrail: Bool

    /// Intensity is the effects multiplier (subtle 0.6, lively 1, party 1.35). The result
    /// stays large enough to clear a thumb.
    public static func radius(for intensity: CGFloat) -> CGFloat {
        let scaled = baseRadius * min(max(intensity, 0.55), 1.35)
        return min(max(scaled, 28), 48)
    }

    public static func glintLimit(intensity: CGFloat) -> Int {
        if intensity < 0.8 { return 7 }
        if intensity < 1.2 { return 12 }
        return 16
    }

    public static func sparkLimit(intensity: CGFloat) -> Int {
        if intensity < 0.8 { return 6 }
        if intensity < 1.2 { return 8 }
        return 11
    }

    /// The ring sits one radius above the contact, clear of the thumb. The bead rests on the
    /// rim in the direction of `action`. A still finger (a zero vector) keeps the bead on the
    /// ring and draws no trail.
    public static func placeAbove(contact: CGPoint, action: CGVector, intensity: CGFloat) -> FingerJewel {
        let radius = radius(for: intensity)
        let center = CGPoint(x: contact.x, y: contact.y - radius)
        let length = hypot(action.dx, action.dy)
        let moving = length > 0.01
        let direction = moving
            ? CGVector(dx: action.dx / length, dy: action.dy / length)
            : CGVector.zero
        let bead = moving
            ? CGPoint(x: center.x + direction.dx * radius, y: center.y + direction.dy * radius)
            : CGPoint(x: center.x, y: center.y - radius)
        return FingerJewel(radius: radius, center: center, bead: bead, direction: direction, drawsTrail: moving)
    }

    /// `velocity` is points per second. `previousCenter` is last frame's ring center.
    public static func place(
        contact: CGPoint,
        previousCenter: CGPoint?,
        velocity: CGVector,
        intensity: CGFloat
    ) -> FingerJewel {
        let speed = hypot(velocity.dx, velocity.dy)
        let moving = speed > 40
        let direction = moving
            ? CGVector(dx: velocity.dx / speed, dy: velocity.dy / speed)
            : CGVector.zero
        let radius = radius(for: intensity)
        let center = easedCenter(previous: previousCenter, contact: contact, direction: direction, moving: moving)
        let bead = moving
            ? CGPoint(x: center.x - direction.dx * radius, y: center.y - direction.dy * radius)
            : CGPoint(x: center.x, y: center.y + radius)
        return FingerJewel(radius: radius, center: center, bead: bead, direction: direction, drawsTrail: moving)
    }

    /// The path from the rim bead backward. Points the ring still covers, at the live end of
    /// the stroke, are dropped. Older points stay, even if the finger later circles back.
    public static func visibleTrail(
        samples: [Sample],
        center: CGPoint,
        radius: CGFloat,
        bead: CGPoint,
        drawsTrail: Bool
    ) -> [Sample] {
        guard drawsTrail else { return [] }
        var end = samples.count
        while end > 0 {
            let point = samples[end - 1].location
            if hypot(point.x - center.x, point.y - center.y) >= radius { break }
            end -= 1
        }
        var kept = Array(samples[..<end])
        let time = samples.last?.time ?? 0
        kept.append(Sample(location: bead, time: time))
        return kept
    }

    private static func easedCenter(
        previous: CGPoint?,
        contact: CGPoint,
        direction: CGVector,
        moving: Bool
    ) -> CGPoint {
        guard moving, let previous else { return contact }
        let behind = CGPoint(
            x: contact.x - direction.dx * lag,
            y: contact.y - direction.dy * lag
        )
        let eased = CGPoint(
            x: previous.x + (behind.x - previous.x) * 0.5,
            y: previous.y + (behind.y - previous.y) * 0.5
        )
        let dx = eased.x - contact.x
        let dy = eased.y - contact.y
        let distance = hypot(dx, dy)
        guard distance > lag, distance > 0 else { return eased }
        return CGPoint(x: contact.x + dx / distance * lag, y: contact.y + dy / distance * lag)
    }
}
