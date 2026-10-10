import Foundation

/// A session's rolling inter-key interval. Cold start keeps today's constants. After a few
/// gaps, the leash, dwell, and cross-hand window move with the typist and stay clamped.
struct TypingRhythm: Sendable {
    /// Leash and dwell before any gaps have been seen.
    static let coldLeash: Double = 0.34
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

    var dwell: Double {
        guard samples >= 4 else { return Self.coldDwell }
        return min(0.28, max(0.09, interval * 0.85))
    }

    var evidenceTuning: EvidenceTuning {
        var tuning = EvidenceTuning.standard
        tuning.dwellDuration = dwell
        return tuning
    }

    /// Letter gaps, counted as words of five. Nil until a few gaps have been seen.
    var wordsPerMinute: Int? {
        guard samples >= 4, interval > 0.05 else { return nil }
        return Int((12 / interval).rounded())
    }

    var costs: AlignmentCosts {
        AlignmentCosts.standard
    }
}
