import Foundation

/// A session's rolling inter-key interval. Cold start keeps today's constants. After a few
/// gaps, the leash, dwell, and cross-hand window move with the typist and stay clamped.
struct TypingRhythm: Sendable {
    /// Leash, swap window, and dwell before any gaps have been seen.
    static let coldLeash: Double = 0.34
    static let coldSwapWindow: Double = 0.07
    static let coldDwell: Double = 0.18

    private var interval = coldLeash
    private var samples = 0

    /// Records one gap between successive letters. Ignores pauses and double-taps.
    mutating func note(gap: Double) {
        guard gap > 0.03, gap < 1.2 else { return }
        if samples == 0 {
            interval = gap
        } else {
            interval = interval * 0.82 + gap * 0.18
        }
        samples += 1
    }

    var leash: Double {
        guard samples >= 4 else { return Self.coldLeash }
        return min(0.55, max(0.16, interval * 1.7))
    }

    var swapWindow: Double {
        guard samples >= 4 else { return Self.coldSwapWindow }
        return min(0.12, max(0.04, interval * 0.45))
    }

    var dwell: Double {
        guard samples >= 4 else { return Self.coldDwell }
        return min(0.28, max(0.09, interval * 0.85))
    }

    var evidenceTuning: EvidenceTuning {
        var tuning = EvidenceTuning.standard
        tuning.dwellDuration = dwell
        return tuning
    }

    var costs: AlignmentCosts {
        var costs = AlignmentCosts.standard
        costs.swapWindow = swapWindow
        return costs
    }
}
