import Foundation

/// Cross-process notifications between the app and the extension. Darwin notifications carry
/// no payload; receivers re-read the shared store.
public enum DarwinNotifications {
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Observes one Darwin notification for its lifetime and calls `handler` on the main actor.
public final class DarwinNotificationObserver: Sendable {
    private let name: String
    private let handler: @MainActor @Sendable () -> Void

    public init(name: String, handler: @escaping @MainActor @Sendable () -> Void) {
        self.name = name
        self.handler = handler

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let receiver = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue()
                receiver.deliver()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }

    private func deliver() {
        let handler = handler
        Task { @MainActor in handler() }
    }
}
