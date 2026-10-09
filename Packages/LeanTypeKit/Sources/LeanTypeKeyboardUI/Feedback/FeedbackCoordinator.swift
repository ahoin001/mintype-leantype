import LeanTypeCore
import UIKit

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
        case .wordDeleted, .deletionRestored:
            impact(softImpact, intensity: 0.6)
        case .correctionReverted:
            impact(softImpact, intensity: 0.4)
        case .flowMilestone:
            impact(softImpact, intensity: 1)
        case .wordCommitted(.swipe):
            break
        case let .commitFelt(sure):
            impact(softImpact, intensity: sure ? 0.65 : 0.3)
        case .chipChosen:
            impact(keyImpact, intensity: 0.35)
        case .sentenceEnded, .trackpadEnded, .wordCommitted, .swipeGestureCommitted, .correctionApplied, .flowChanged, .holdArmed, .holdEnded, .returnSent:
            break
        }
    }

    private func impact(_ generator: UIImpactFeedbackGenerator, intensity: CGFloat) {
        guard hapticsEnabled else { return }
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }
}
