import LeanTypeCore
import UIKit

/// Watches the device (heat, Low Power Mode, Reduce Motion, memory warnings) and decides how
/// much flair the keyboard can afford, via the pure `EffectsPolicy`.
@MainActor
final class EffectsGovernor {
    var onChange: ((EffectsLevel) -> Void)?

    private(set) var policy: EffectsPolicy
    private let observers = NotificationTokens()

    init(intensity: EffectsSettings.Intensity) {
        policy = EffectsPolicy(intensity: intensity)
        refreshSystemState()
        let names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
        ]
        for name in names {
            observers.observe(name) { [weak self] in self?.refreshSystemState() }
        }
    }

    var level: EffectsLevel { policy.level }

    func setIntensity(_ intensity: EffectsSettings.Intensity) {
        update { $0.intensity = intensity }
    }

    /// Effects stay off until the keyboard next appears.
    func noteMemoryPressure() {
        update { $0.isUnderMemoryPressure = true }
    }

    func keyboardWillAppear() {
        update { $0.isUnderMemoryPressure = false }
        refreshSystemState()
    }

    private func refreshSystemState() {
        let info = ProcessInfo.processInfo
        update {
            $0.thermal = ThermalCondition(info.thermalState)
            $0.isLowPowerModeEnabled = info.isLowPowerModeEnabled
            $0.isReduceMotionEnabled = UIAccessibility.isReduceMotionEnabled
        }
    }

    private func update(_ change: (inout EffectsPolicy) -> Void) {
        let previous = policy.level
        change(&policy)
        if policy.level != previous {
            onChange?(policy.level)
        }
    }
}

/// Notification observations that end when their owner goes away.
final class NotificationTokens: @unchecked Sendable {
    // @unchecked: tokens are only appended on the main actor and read again in deinit, when
    // no other reference exists.
    private var tokens: [any NSObjectProtocol] = []

    @MainActor
    func observe(_ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}

private extension ThermalCondition {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}
