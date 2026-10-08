import CoreGraphics

/// One observed point of a stroke.
public struct StrokePoint: Hashable, Sendable {
    public let location: CGPoint
    public let time: Double

    public init(location: CGPoint, time: Double) {
        self.location = location
        self.time = time
    }
}

/// A letter a thumb entered, at the moment it entered, in key-area coordinates.
struct KeyArrival: Hashable, Sendable {
    var letter: String
    var center: CGPoint
    var time: Double
}

/// The path of one finger during a swipe, in a bounded buffer: past `capacity` points it
/// drops every other point, keeping the overall shape at half the resolution.
///
/// Pulling back along the path shortens it. A reversal of about one key drops the tail the
/// finger has left behind, so the word being decoded shrinks before the finger lifts.
struct StrokeBuffer {
    static let capacity = 256
    /// Samples closer than this to the previous one add nothing to the shape.
    static let minimumSpacing: CGFloat = 1.5
    /// How far back along the stroke, in points, drops the tail the finger has left behind.
    static let retreatStep: CGFloat = 34
    /// A pull-back only undoes the letters just drawn. A later key that sits near an older
    /// part of a zigzag ("d" on the row already crossed in "traged") is a new letter.
    static let retreatLookback: CGFloat = 120

    private(set) var points: [StrokePoint] = []
    private(set) var arrivals: [KeyArrival] = []
    /// Distance spent reversing since the last forward sample.
    init(start: StrokePoint) {
        points.reserveCapacity(Self.capacity)
        points.append(start)
    }

    var start: StrokePoint { points[0] }
    var end: StrokePoint { points[points.count - 1] }

    mutating func append(_ point: StrokePoint) {
        let last = end.location
        let moveLength = hypot(point.location.x - last.x, point.location.y - last.y)
        guard moveLength >= Self.minimumSpacing else { return }

        // A turn toward the next letter leaves the path. A pull-back lands on the path
        // already drawn, a key-width behind the furthest point, and the stroke shortens.
        if let back = distanceBehindTip(of: point.location), back >= Self.retreatStep {
            rewind(to: point)
            return
        }
        push(point)
    }

    /// Records the final location. A small pullback keeps the word; a real reversal shortens it.
    mutating func finish(at point: StrokePoint) {
        append(point)
        if end.location != point.location {
            push(point)
        }
    }

    /// The first time this stroke enters `letter`. Repeating the current letter does nothing.
    mutating func arrive(_ letter: String, at center: CGPoint, time: Double) {
        guard arrivals.last?.letter != letter else { return }
        arrivals.append(KeyArrival(letter: letter, center: center, time: time))
    }

    // MARK: - Private

    /// How far this point sits behind the tip, when it has come back onto the stroke. Points
    /// that are merely turning off toward a new letter are not on that older path.
    private func distanceBehindTip(of location: CGPoint) -> CGFloat? {
        let total = arcLength
        guard total > Self.retreatStep, points.count >= 2 else { return nil }
        let prefixEnd = total - Self.retreatStep
        let windowStart = max(0, total - Self.retreatLookback)
        var traveled: CGFloat = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var bestAlong: CGFloat = 0
        for index in 1..<points.count {
            let start = points[index - 1].location
            let end = points[index].location
            let segment = hypot(end.x - start.x, end.y - start.y)
            let segmentEnd = traveled + segment
            let from = max(traveled, windowStart)
            let to = min(prefixEnd, segmentEnd)
            if from < to, segment > 0.001 {
                let dx = end.x - start.x
                let dy = end.y - start.y
                let raw = ((location.x - start.x) * dx + (location.y - start.y) * dy) / (segment * segment)
                let t = min(max(raw, (from - traveled) / segment), (to - traveled) / segment)
                let projected = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
                let distance = hypot(location.x - projected.x, location.y - projected.y)
                if distance < bestDistance {
                    bestDistance = distance
                    bestAlong = traveled + hypot(projected.x - start.x, projected.y - start.y)
                }
            }
            traveled = segmentEnd
            if traveled >= prefixEnd { break }
        }
        guard bestDistance <= Self.retreatStep * 0.5 else { return nil }
        return total - bestAlong
    }

    private var arcLength: CGFloat {
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += hypot(points[index].location.x - points[index - 1].location.x, points[index].location.y - points[index - 1].location.y)
        }
        return total
    }

    /// Drops the part of the stroke the finger has backed away from, so the shape match sees
    /// the shorter path. The letters already entered stay: a return through them is read later
    /// as the keys the thumb aimed at, not erased.
    private mutating func rewind(to finger: StrokePoint) {
        while points.count > 1 {
            let last = points[points.count - 1].location
            if hypot(last.x - finger.location.x, last.y - finger.location.y) <= Self.retreatStep { break }
            points.removeLast()
        }
        push(finger)
    }

    private mutating func push(_ point: StrokePoint) {
        if points.count == Self.capacity {
            points = points.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        }
        points.append(point)
    }
}

/// A complete swipe, ready to decode: a polyline in key-area coordinates.
///
/// The path is always a finger's real polyline, never the keys it happened to cross. Taps from
/// the other thumb are observations beside that path. `tracedLetters` is the letters the thumbs
/// aimed at — start, turns, pauses, lift, and stationary taps — with a bounced pair collapsed.
public struct SwipeGesture: Hashable, Sendable {
    public let path: [CGPoint]
    public let strokeCount: Int
    /// Each moving stroke's polyline, in stroke order. The longest one is also `path`.
    public let strokePaths: [[CGPoint]]
    /// Letters the thumbs aimed at, in arrival order, with a return trip already removed.
    /// Used when decoding finds nothing, so the gesture still types what was meant.
    public let tracedLetters: String
    /// Each letter a thumb aimed at, with the time and the direction of travel into it.
    public let observations: [StrokeObservation]
    /// A stroke ended on the apostrophe, so the contraction spelling should lead.
    public let prefersContraction: Bool

    public init(
        path: [CGPoint],
        strokeCount: Int,
        strokePaths: [[CGPoint]] = [],
        tracedLetters: String = "",
        observations: [StrokeObservation] = [],
        prefersContraction: Bool = false
    ) {
        self.path = path
        self.strokeCount = strokeCount
        self.strokePaths = strokePaths
        self.tracedLetters = tracedLetters
        self.observations = observations
        self.prefersContraction = prefersContraction
    }

    public var isMultiStroke: Bool { strokeCount > 1 }
}
