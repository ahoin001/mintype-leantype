import LeanTypeCore
import UIKit
#if os(iOS)
import CoreHaptics
#endif

/// Turns keyboard events into key clicks and haptics, fired on the same frame as the visual
/// change. Haptics in a keyboard extension require Full Access; the host decides whether
/// they're enabled.
@MainActor
public final class FeedbackCoordinator: KeyboardEventObserver {
    public var hapticsEnabled: Bool {
        didSet { if hapticsEnabled { prepare() } }
    }

    public var clicksEnabled: Bool

    private lazy var keyImpact = UIImpactFeedbackGenerator(style: .light)
    private lazy var modeImpact = UIImpactFeedbackGenerator(style: .medium)
    private lazy var softImpact = UIImpactFeedbackGenerator(style: .soft)
    private lazy var selection = UISelectionFeedbackGenerator()
    private lazy var swipeSuccess = UINotificationFeedbackGenerator()
    #if os(iOS)
    private var rumbleEngine: CHHapticEngine?
    private var rumble: CHHapticAdvancedPatternPlayer?
    #endif

    public init(hapticsEnabled: Bool, clicksEnabled: Bool) {
        self.hapticsEnabled = hapticsEnabled
        self.clicksEnabled = clicksEnabled
    }

    /// Warms up the Taptic Engine so the first key press has no latency.
    public func prepare() {
        guard hapticsEnabled else { return }
        keyImpact.prepare()
        selection.prepare()
        swipeSuccess.prepare()
    }

    public func handle(_ event: KeyboardEvent) {
        switch event {
        case .keyDown:
            if clicksEnabled {
                UIDevice.current.playInputClick()
            }
            impact(keyImpact, intensity: 0.5)
        case .cursorStep, .deleteStep, .swipePreviewChanged:
            guard hapticsEnabled else { return }
            selection.selectionChanged()
            selection.prepare()
        case .trackpadEngaged, .capsLockEngaged, .deleteEscalated:
            impact(modeImpact, intensity: 0.7)
        case .alternatesPresented:
            impact(keyImpact, intensity: 0.8)
        case .holdArmed:
            impact(keyImpact, intensity: 0.5)
        case .wordDeleted, .deletionRestored:
            impact(softImpact, intensity: 0.6)
        case .correctionReverted:
            impact(softImpact, intensity: 0.4)
        case .flowMilestone:
            impact(softImpact, intensity: 1)
        case .strokePulse:
            playStrokePulse()
        case .wordCommitted(.swipe):
            stopRumble()
            guard hapticsEnabled else { return }
            swipeSuccess.notificationOccurred(.success)
            swipeSuccess.prepare()
        case let .commitFelt(sure):
            impact(softImpact, intensity: sure ? 0.65 : 0.3)
        case .chipChosen:
            impact(keyImpact, intensity: 0.35)
        case .sentenceEnded, .trackpadEnded, .wordCommitted, .swipeGestureCommitted, .correctionApplied, .flowChanged, .holdEnded, .returnSent, .spectacleLetters:
            break
        }
    }

    /// A rolling rumble while a stroke is down. A selection tick stands in when Core Haptics
    /// cannot start, which is the usual case without Full Access.
    private func playStrokePulse() {
        guard hapticsEnabled else { return }
        #if os(iOS)
        if startRumble() { return }
        #endif
        selection.selectionChanged()
        selection.prepare()
    }

    private func stopRumble() {
        #if os(iOS)
        try? rumble?.stop(atTime: CHHapticTimeImmediate)
        rumble = nil
        #endif
    }

    #if os(iOS)
    @discardableResult
    private func startRumble() -> Bool {
        if rumble != nil { return true }
        if rumbleEngine == nil {
            guard let engine = try? CHHapticEngine() else { return false }
            rumbleEngine = engine
            try? engine.start()
        }
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35)],
            relativeTime: 0,
            duration: 0.6
        )
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let player = try? rumbleEngine?.makeAdvancedPlayer(with: pattern)
        else { return false }
        rumble = player
        try? player.start(atTime: 0)
        return true
    }
    #endif

    private func impact(_ generator: UIImpactFeedbackGenerator, intensity: CGFloat) {
        guard hapticsEnabled else { return }
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }
}
