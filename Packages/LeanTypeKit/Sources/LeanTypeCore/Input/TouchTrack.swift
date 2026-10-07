import CoreGraphics

/// Identity of one finger for the lifetime of its touch.
public struct TouchID: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public enum TouchPhase: Hashable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

/// One UIKit-free touch observation. `timestamp` uses the same clock as `UITouch.timestamp`
/// (system uptime in seconds).
public struct TouchSample: Hashable, Sendable {
    public let id: TouchID
    public let location: CGPoint
    public let timestamp: Double
    public let phase: TouchPhase

    public init(id: TouchID, location: CGPoint, timestamp: Double, phase: TouchPhase) {
        self.id = id
        self.location = location
        self.timestamp = timestamp
        self.phase = phase
    }
}

/// The path of one finger so far: where it started, where it is, and how fast it's moving.
public struct TouchTrack: Sendable {
    /// Weight given to the newest instantaneous velocity; the rest carries over, smoothing out
    /// jitter from coalesced touch samples.
    private static let velocitySmoothing: CGFloat = 0.6

    public let id: TouchID
    public let start: TouchSample
    public private(set) var current: TouchSample
    /// Smoothed velocity in points per second.
    public private(set) var velocity: CGVector = .zero

    public init(start: TouchSample) {
        id = start.id
        self.start = start
        current = start
    }

    public var translation: CGVector {
        CGVector(dx: current.location.x - start.location.x, dy: current.location.y - start.location.y)
    }

    public var speed: CGFloat {
        (velocity.dx * velocity.dx + velocity.dy * velocity.dy).squareRoot()
    }

    mutating func append(_ sample: TouchSample) {
        let elapsed = sample.timestamp - current.timestamp
        if elapsed > 0 {
            let instant = CGVector(
                dx: (sample.location.x - current.location.x) / elapsed,
                dy: (sample.location.y - current.location.y) / elapsed
            )
            let weight = Self.velocitySmoothing
            velocity = CGVector(
                dx: instant.dx * weight + velocity.dx * (1 - weight),
                dy: instant.dy * weight + velocity.dy * (1 - weight)
            )
        }
        current = sample
    }
}
