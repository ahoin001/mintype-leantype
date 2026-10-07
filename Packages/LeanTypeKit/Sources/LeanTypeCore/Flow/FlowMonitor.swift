import Foundation

/// Drives a `FlowTracker` from the engine's clock and turns its changes into events: a
/// `flowChanged` only when the published step moves, a `flowMilestone` for clean streaks, and
/// a slow idle check (one timer at a time, only while there's flow left to decay).
@MainActor
final class FlowMonitor {
    /// How often flow is re-checked while idle.
    static let settleInterval: TimeInterval = 2.5

    private let scheduler: any Scheduler
    private let emit: @MainActor (KeyboardEvent) -> Void
    private var tracker = FlowTracker()
    private var publishedStep = 0
    private var settleTimer: (any Cancellable)?

    var celebratesMilestones = true

    init(scheduler: any Scheduler, emit: @escaping @MainActor (KeyboardEvent) -> Void) {
        self.scheduler = scheduler
        self.emit = emit
    }

    var level: FlowLevel { tracker.level }

    func noteKeystroke() {
        publish(tracker.noteKeystroke(at: scheduler.now))
    }

    func noteWordCompleted() {
        let milestone = tracker.noteWordCompleted(at: scheduler.now)
        publish(tracker.level)
        if let milestone, celebratesMilestones {
            emit(.flowMilestone(milestone))
        }
    }

    func noteDeletion() {
        publish(tracker.noteDeletion(at: scheduler.now))
    }

    func noteCorrection() {
        publish(tracker.noteCorrection(at: scheduler.now))
    }

    func reset() {
        settleTimer?.cancel()
        settleTimer = nil
        tracker.reset()
        publish(tracker.level)
    }

    // MARK: - Private

    private func publish(_ level: FlowLevel) {
        if level.step != publishedStep {
            publishedStep = level.step
            emit(.flowChanged(level))
        }
        if level.step > 0, settleTimer == nil {
            settleTimer = scheduler.schedule(after: Self.settleInterval) { [weak self] in
                self?.settle()
            }
        }
    }

    private func settle() {
        settleTimer = nil
        publish(tracker.settle(at: scheduler.now))
    }
}
