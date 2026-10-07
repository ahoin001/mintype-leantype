/// How much visual flair the keyboard can afford right now.
public enum EffectsLevel: Int, Hashable, Sendable, Comparable {
    /// No effects at all; pools are emptied.
    case off
    /// Gentle fades only: no particles, no travel, minimal layers.
    case reduced
    /// Everything the user's intensity allows.
    case full

    public static func < (lhs: EffectsLevel, rhs: EffectsLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The device's heat, mirroring `ProcessInfo.ThermalState` without depending on it.
public enum ThermalCondition: Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Everything that decides the effects level. Pure, so every rule is unit-testable.
public struct EffectsPolicy: Hashable, Sendable {
    public var intensity: EffectsSettings.Intensity
    public var thermal: ThermalCondition
    public var isLowPowerModeEnabled: Bool
    public var isReduceMotionEnabled: Bool
    /// Set by a memory warning; cleared the next time the keyboard appears.
    public var isUnderMemoryPressure: Bool

    public init(
        intensity: EffectsSettings.Intensity = .lively,
        thermal: ThermalCondition = .nominal,
        isLowPowerModeEnabled: Bool = false,
        isReduceMotionEnabled: Bool = false,
        isUnderMemoryPressure: Bool = false
    ) {
        self.intensity = intensity
        self.thermal = thermal
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isReduceMotionEnabled = isReduceMotionEnabled
        self.isUnderMemoryPressure = isUnderMemoryPressure
    }

    public var level: EffectsLevel {
        if intensity == .off || isUnderMemoryPressure || thermal == .critical {
            return .off
        }
        if thermal == .serious || isLowPowerModeEnabled || isReduceMotionEnabled {
            return .reduced
        }
        return .full
    }
}
