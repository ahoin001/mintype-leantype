import Foundation

/// The chips a whole-word delete just rejected, for one drawing shape.
/// Nothing is written to disk. A word that stays, followed by another word, clears it.
struct RedrawMemory {
    private var bucket: SwipeBucket?
    private var skipped: Set<String> = []
    /// The previous commit was not deleted before the next word began.
    private var lastCommitSurvived = true

    /// A word landed. The chain clears only when the word before it was allowed to stay.
    mutating func noteLanded() {
        if lastCommitSurvived {
            bucket = nil
            skipped = []
        }
        lastCommitSurvived = true
    }

    /// The whole word was deleted. Every chip that was showing is skipped for this shape.
    mutating func noteRejection(chips: [String], trace: String) {
        guard let next = SwipeBucket.make(trace) else { return }
        if bucket != next {
            bucket = next
            skipped = []
        }
        skipped.formUnion(chips.map { $0.lowercased() })
        lastCommitSurvived = false
    }

    /// The first reading that was not on the strip leads. Skipped chips keep their order behind it.
    /// When every reading was shown, the order stays.
    func applying(to result: DecodeResult, trace: String) -> DecodeResult {
        guard let bucket, bucket == SwipeBucket.make(trace), !skipped.isEmpty else { return result }
        let kept = result.readings.filter { !skipped.contains($0.word.lowercased()) }
        guard !kept.isEmpty, kept.count != result.readings.count else { return result }
        let dropped = result.readings.filter { skipped.contains($0.word.lowercased()) }
        return result.replacingReadings(kept + dropped)
    }
}
