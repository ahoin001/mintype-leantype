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
    /// Where the finger actually was, which can sit off the key center.
    var touch: CGPoint
    var time: Double

    init(letter: String, center: CGPoint, touch: CGPoint? = nil, time: Double) {
        self.letter = letter
        self.center = center
        self.touch = touch ?? center
        self.time = time
    }
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
    /// Tuned when a key was `referenceKeyWidth` wide. A live stroke scales this with its key.
    static let retreatStep: CGFloat = 34
    /// A pull-back only undoes the letters just drawn. A later key that sits near an older
    /// part of a zigzag ("d" on the row already crossed in "traged") is a new letter.
    static let retreatLookback: CGFloat = 120
    /// The key width these point thresholds were tuned against.
    static let referenceKeyWidth: CGFloat = 36

    private(set) var points: [StrokePoint] = []
    /// Letters currently part of the word. A one-key reversal hides the tail until the finger
    /// walks further back, which is a return trip and keeps every letter.
    var arrivals: [KeyArrival] {
        guard let finger = undoneFinger else { return entered }
        return withoutTail(beyond: finger)
    }
    /// Every letter this stroke has entered, in order.
    private var entered: [KeyArrival] = []
    /// Set while a short reversal is hiding the last letter.
    private var undoneFinger: CGPoint?
    /// The longest the stroke has been. A retreat is measured from here.
    private var peak: CGFloat = 0
    /// This stroke's key width. Retreat distances scale with it.
    private var keyWidth: CGFloat
    /// Which thumb drew this stroke. A later stroke with the same thumb extends that chain.
    var thumb: Int

    init(start: StrokePoint, keyWidth: CGFloat = referenceKeyWidth, thumb: Int = 0) {
        self.keyWidth = max(keyWidth, 1)
        self.thumb = thumb
        points.reserveCapacity(Self.capacity)
        points.append(start)
    }

    private var retreatStep: CGFloat { Self.retreatStep * keyWidth / Self.referenceKeyWidth }
    private var retreatLookback: CGFloat { Self.retreatLookback * keyWidth / Self.referenceKeyWidth }

    var start: StrokePoint { points[0] }
    var end: StrokePoint { points[points.count - 1] }

    mutating func append(_ point: StrokePoint) {
        let last = end.location
        let moveLength = hypot(point.location.x - last.x, point.location.y - last.y)
        guard moveLength >= Self.minimumSpacing else { return }

        // A turn toward the next letter leaves the path. A pull-back lands on the path
        // already drawn, a key-width behind the furthest point, and the stroke shortens.
        if let back = distanceBehindTip(of: point.location), back >= retreatStep {
            rewind(to: point)
            return
        }
        push(point)
        noteForwardReach()
    }

    /// Records the final location. A small pullback keeps the word; a real reversal shortens it.
    mutating func finish(at point: StrokePoint) {
        append(point)
        if end.location != point.location {
            push(point)
        }
    }

    /// The first time this stroke enters `letter`. Repeating the current letter does nothing.
    mutating func arrive(_ letter: String, at center: CGPoint, touch: CGPoint? = nil, time: Double) {
        guard entered.last?.letter != letter else { return }
        let arrival = KeyArrival(letter: letter, center: center, touch: touch ?? center, time: time)
        entered.append(arrival)
    }

    // MARK: - Private

    /// How far this point sits behind the tip, when it has come back onto the stroke. Points
    /// that are merely turning off toward a new letter are not on that older path.
    private func distanceBehindTip(of location: CGPoint) -> CGFloat? {
        let total = arcLength
        guard total > retreatStep, points.count >= 2 else { return nil }
        let prefixEnd = total - retreatStep
        let windowStart = max(0, total - retreatLookback)
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
        guard bestDistance <= retreatStep * 0.5 else { return nil }
        return total - bestAlong
    }

    private var arcLength: CGFloat {
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += hypot(points[index].location.x - points[index - 1].location.x, points[index].location.y - points[index - 1].location.y)
        }
        return total
    }

    /// Drops the part of the stroke the finger has backed away from, and the letters that
    /// sat on that tail. The first letter stays, and so does the letter at the turnaround.
    /// A pull-back shorter than one key never reaches here, so a bounce keeps its letter.
    private mutating func rewind(to finger: StrokePoint) {
        let before = points.count
        while points.count > 1 {
            let last = points[points.count - 1].location
            if hypot(last.x - finger.location.x, last.y - finger.location.y) <= retreatStep { break }
            points.removeLast()
        }
        if points.count < before {
            // About one key hides the last letter. Further than that, the finger is walking
            // back through the word, and the return-trip reading still needs every letter.
            let retreated = peak - arcLength
            undoneFinger = retreated <= retreatStep * 1.75 ? finger.location : nil
        }
        push(finger)
    }

    /// Forward motion commits the stroke's new reach. A letter hidden by a short reversal
    /// stays gone once the finger sets off past where it turned around.
    private mutating func noteForwardReach() {
        let reached = arcLength
        guard reached > peak else { return }
        if undoneFinger != nil {
            entered = arrivals
            undoneFinger = nil
        }
        peak = reached
    }

    /// Letters whose touch sits on the shortened stroke stay. The first letter and the
    /// letter nearest the finger stay even when their touch is a key center, not a sample.
    private func withoutTail(beyond finger: CGPoint) -> [KeyArrival] {
        guard let first = entered.first, entered.count > 1 else { return entered }
        let turnaround = entered.min {
            hypot($0.touch.x - finger.x, $0.touch.y - finger.y) < hypot($1.touch.x - finger.x, $1.touch.y - finger.y)
        }
        return entered.filter { arrival in
            arrival == first || arrival == turnaround || pathStillReaches(arrival.touch)
        }
    }

    private func pathStillReaches(_ touch: CGPoint) -> Bool {
        points.contains { hypot($0.location.x - touch.x, $0.location.y - touch.y) <= retreatStep * 0.55 }
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
    /// Crossed keys stay on `evidence` and are not part of this string.
    public let tracedLetters: String
    /// Each letter a thumb aimed at, with the time and the direction of travel into it.
    public let observations: [StrokeObservation]
    /// Anchors, crossings, and taps. The alignment decoder reads this; aimed letters stay
    /// on `observations` for the join rules.
    public let evidence: SwipeEvidence
    /// A stroke ended on the apostrophe, so the contraction spelling should lead.
    public let prefersContraction: Bool

    public init(
        path: [CGPoint],
        strokeCount: Int,
        strokePaths: [[CGPoint]] = [],
        tracedLetters: String = "",
        observations: [StrokeObservation] = [],
        evidence: SwipeEvidence = .empty,
        prefersContraction: Bool = false
    ) {
        self.path = path
        self.strokeCount = strokeCount
        self.strokePaths = strokePaths
        self.tracedLetters = tracedLetters
        self.observations = observations
        self.evidence = evidence
        self.prefersContraction = prefersContraction
    }

    public var isMultiStroke: Bool { strokeCount > 1 }
}
