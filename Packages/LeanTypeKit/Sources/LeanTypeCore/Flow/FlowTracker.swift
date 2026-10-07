import Foundation

/// How "in the zone" the user is, from 0 (idle) to 1 (steady, confident typing).
public struct FlowLevel: Hashable, Sendable, Comparable {
    /// Levels are published in steps so observers update a handful of times, not per key.
    public static let stepCount = 10

    public let value: Double

    public init(_ value: Double) {
        self.value = min(max(value, 0), 1)
    }

    public static let zero = FlowLevel(0)

    /// `value` rounded to the nearest publishing step.
    public var step: Int { Int((value * Double(Self.stepCount)).rounded()) }

    public static func < (lhs: FlowLevel, rhs: FlowLevel) -> Bool { lhs.value < rhs.value }
}

/// A pure, time-based model of typing rhythm. It only sees *when* things happen (keystrokes,
/// word ends, deletions), never what was typed.
///
/// Momentum rises with each keystroke that lands in a comfortable rhythm, drops on deletions
/// and corrections, and decays exponentially while idle. Words finished without touching
/// backspace build a streak; every `milestoneInterval` words is a milestone, rate-limited so
/// celebrations stay special.
public struct FlowTracker: Sendable {
    /// Inter-key gaps inside this window count as rhythm; slower keystrokes only hold steady.
    static let rhythmWindow: ClosedRange<TimeInterval> = 0.04...0.6
    /// Fraction of the remaining headroom gained per in-rhythm keystroke.
    static let gain = 0.045
    /// Idle time constant for decay, in seconds.
    static let decayTimeConstant: TimeInterval = 2.5
    static let deletionRetention = 0.8
    static let correctionRetention = 0.92
    public static let milestoneInterval = 25
    static let milestoneCooldown: TimeInterval = 20

    public private(set) var level = FlowLevel.zero
    /// Words finished in a row without a deletion.
    public private(set) var streak = 0

    private var momentum = 0.0
    private var lastActivity: TimeInterval?
    private var lastMilestoneTime: TimeInterval?

    public init() {}

    /// The level after decaying to `now`, without recording activity.
    public func level(at now: TimeInterval) -> FlowLevel {
        FlowLevel(decayed(to: now))
    }

    /// A character key committed. Returns the new level.
    @discardableResult
    public mutating func noteKeystroke(at now: TimeInterval) -> FlowLevel {
        let gap = lastActivity.map { now - $0 }
        momentum = decayed(to: now)
        if let gap, Self.rhythmWindow.contains(gap) {
            // Steadier (shorter) gaps inside the window earn a little more.
            let steadiness = 1 - (gap - Self.rhythmWindow.lowerBound) / Self.rhythmWindow.upperBound
            momentum += Self.gain * (0.6 + 0.4 * steadiness) * (1 - momentum)
        }
        return touch(now)
    }

    /// A word was finished. Returns the milestone reached, if any.
    public mutating func noteWordCompleted(at now: TimeInterval) -> Int? {
        momentum = decayed(to: now)
        touch(now)
        streak += 1
        guard streak.isMultiple(of: Self.milestoneInterval) else { return nil }
        if let lastMilestoneTime, now - lastMilestoneTime < Self.milestoneCooldown { return nil }
        lastMilestoneTime = now
        return streak
    }

    @discardableResult
    public mutating func noteDeletion(at now: TimeInterval) -> FlowLevel {
        momentum = decayed(to: now) * Self.deletionRetention
        streak = 0
        return touch(now)
    }

    @discardableResult
    public mutating func noteCorrection(at now: TimeInterval) -> FlowLevel {
        momentum = decayed(to: now) * Self.correctionRetention
        return touch(now)
    }

    /// Updates `level` for idle decay up to `now` without counting as activity, so the next
    /// keystroke's rhythm is still measured from the last real one.
    @discardableResult
    public mutating func settle(at now: TimeInterval) -> FlowLevel {
        level = FlowLevel(decayed(to: now))
        return level
    }

    public mutating func reset() {
        self = FlowTracker()
    }

    // MARK: - Private

    @discardableResult
    private mutating func touch(_ now: TimeInterval) -> FlowLevel {
        lastActivity = now
        level = FlowLevel(momentum)
        return level
    }

    private func decayed(to now: TimeInterval) -> Double {
        guard let lastActivity else { return momentum }
        let idle = max(now - lastActivity - Self.rhythmWindow.upperBound, 0)
        guard idle > 0 else { return momentum }
        return momentum * exp(-idle / Self.decayTimeConstant)
    }
}
