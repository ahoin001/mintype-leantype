import Foundation

public protocol Cancellable {
    func cancel()
}

/// Time source and delayed work for gesture timers (long press, key repeat). Injected so tests
/// can drive time deterministically.
@MainActor
public protocol Scheduler: AnyObject {
    /// Seconds on the same clock as `UITouch.timestamp`.
    var now: TimeInterval { get }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable
}

@MainActor
public final class MainQueueScheduler: Scheduler {
    public init() {}

    public var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any Cancellable {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
}

extension DispatchWorkItem: Cancellable {}
