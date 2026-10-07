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

/// The path of one finger during a swipe, in a bounded buffer: past `capacity` points it
/// drops every other point, keeping the overall shape at half the resolution.
struct StrokeBuffer {
    static let capacity = 256
    /// Samples closer than this to the previous one add nothing to the shape.
    static let minimumSpacing: CGFloat = 1.5

    private(set) var points: [StrokePoint] = []

    init(start: StrokePoint) {
        points.reserveCapacity(Self.capacity)
        points.append(start)
    }

    var start: StrokePoint { points[0] }
    var end: StrokePoint { points[points.count - 1] }

    mutating func append(_ point: StrokePoint) {
        let last = end.location
        let dx = point.location.x - last.x
        let dy = point.location.y - last.y
        guard dx * dx + dy * dy >= Self.minimumSpacing * Self.minimumSpacing else { return }
        if points.count == Self.capacity {
            points = points.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        }
        points.append(point)
    }

    /// Records the final location even if it's close to the last sample.
    mutating func finish(at point: StrokePoint) {
        if end.location != point.location {
            if points.count == Self.capacity { points.removeLast() }
            points.append(point)
        }
    }
}

/// A complete swipe, ready to decode: a polyline in key-area coordinates.
///
/// For one finger it's the finger's path. For several fingers (Nintype-style two-thumb
/// sliding) it's the salient points of every stroke (starts, turns, pauses, ends) merged in
/// time order, which is the order the letters were meant.
public struct SwipeGesture: Hashable, Sendable {
    public let path: [CGPoint]
    public let strokeCount: Int

    public init(path: [CGPoint], strokeCount: Int) {
        self.path = path
        self.strokeCount = strokeCount
    }

    public var isMultiStroke: Bool { strokeCount > 1 }
}
