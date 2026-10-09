import Foundation

public enum ShiftState: Hashable, Sendable {
    case off
    /// Capitalizes the next character, then turns off.
    case once
    case locked
}

/// Shift and caps-lock rules, including automatic capitalization.
@MainActor
final class ShiftController {
    static let doubleTapInterval: TimeInterval = 0.32

    private(set) var state = ShiftState.off
    /// Set when shift was turned on by auto-capitalization rather than the user.
    var isSentenceCapital: Bool { state == .once && isAutomatic }

    /// Set when shift was turned on by auto-capitalization rather than the user, so the next
    /// context change may turn it back off.
    private var isAutomatic = false
    /// A manual shift press overrides auto-capitalization until the text or cursor changes.
    private var isAutomaticSuppressed = false
    private var isHeld = false
    private var insertionsAtPress = 0
    /// End time of the last shift tap that didn't type anything, for double-tap detection.
    private var lastCleanTapEnd = -TimeInterval.infinity
    /// Shift as it was when the current press began, so a sideways delete can put it back.
    private var pressMemory: PressMemory?

    private struct PressMemory {
        var state: ShiftState
        var isAutomatic: Bool
        var isAutomaticSuppressed: Bool
        var lastCleanTapEnd: TimeInterval
    }

    /// Returns `true` when this press engaged caps lock.
    func pressBegan(at now: TimeInterval, insertionCount: Int) -> Bool {
        pressMemory = PressMemory(
            state: state,
            isAutomatic: isAutomatic,
            isAutomaticSuppressed: isAutomaticSuppressed,
            lastCleanTapEnd: lastCleanTapEnd
        )
        isHeld = true
        insertionsAtPress = insertionCount
        let isDoubleTap = now - lastCleanTapEnd < Self.doubleTapInterval
        isAutomatic = false
        isAutomaticSuppressed = true

        if isDoubleTap, state != .locked {
            state = .locked
            return true
        }
        state = state == .off ? .once : .off
        return false
    }

    func pressEnded(at now: TimeInterval, insertionCount: Int) {
        pressMemory = nil
        isHeld = false
        if insertionCount > insertionsAtPress {
            // Shift was held while typing: it applied to those keys and is now done.
            if state == .once { state = .off }
            lastCleanTapEnd = -.infinity
        } else {
            lastCleanTapEnd = now
        }
    }

    /// The finger slid sideways to delete. Shift goes back to how it was before the touch.
    func cancelPress() {
        guard let pressMemory else { return }
        state = pressMemory.state
        isAutomatic = pressMemory.isAutomatic
        isAutomaticSuppressed = pressMemory.isAutomaticSuppressed
        lastCleanTapEnd = pressMemory.lastCleanTapEnd
        isHeld = false
        self.pressMemory = nil
    }

    func consumeAfterInsertion() {
        guard !isHeld, state == .once else { return }
        state = .off
        isAutomatic = false
    }

    func applyAutomatic(_ shouldCapitalize: Bool) {
        guard !isHeld, !isAutomaticSuppressed, state != .locked else { return }
        if state == .once, !isAutomatic { return }
        state = shouldCapitalize ? .once : .off
        isAutomatic = shouldCapitalize
    }

    /// Call after any edit or cursor move so auto-capitalization can resume.
    func noteContextChanged() {
        isAutomaticSuppressed = false
    }

    func reset() {
        state = .off
        isAutomatic = false
        isAutomaticSuppressed = false
        isHeld = false
        lastCleanTapEnd = -.infinity
    }
}
