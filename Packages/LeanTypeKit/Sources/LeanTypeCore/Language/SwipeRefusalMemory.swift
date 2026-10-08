import Foundation

/// First and last letter of a stroke. "there" and "three" share one, "the" does too,
/// and a clean "hello" does not.
struct SwipeBucket: Hashable, Sendable {
    var first: Character
    var last: Character

    static func make(_ trace: String) -> SwipeBucket? {
        let letters = trace.lowercased().filter(\.isLetter)
        guard let first = letters.first, let last = letters.last else { return nil }
        return SwipeBucket(first: first, last: last)
    }
}

/// A short memory of swipe guesses the user deleted on the spot. The next similar stroke
/// leads with a different reading. It is not saved, and it fades after a few later words.
@MainActor
final class SwipeRefusalMemory {
    /// How many later swipes still treat the deleted word as the wrong guess.
    static let lifetime = 6
    static let capacity = 12

    private struct Entry {
        var bucket: SwipeBucket
        var word: String
        var remaining: Int
    }

    private var entries: [Entry] = []

    /// `word` was the guess just deleted. `trace` is the letters the stroke aimed at.
    func note(word: String, trace: String) {
        let word = word.lowercased()
        guard !word.isEmpty, let bucket = SwipeBucket.make(trace) else { return }
        entries.removeAll { $0.bucket == bucket && $0.word == word }
        entries.append(Entry(bucket: bucket, word: word, remaining: Self.lifetime))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// The deleted word came back, so it is a fair guess again.
    func forget(word: String) {
        let word = word.lowercased()
        entries.removeAll { $0.word == word }
    }

    /// A later swipe landed. Refusals older than `lifetime` such swipes drop off.
    func noteSwipeLanded() {
        for index in entries.indices {
            entries[index].remaining -= 1
        }
        entries.removeAll { $0.remaining <= 0 }
    }

    /// If the leading word was just refused for this kind of stroke, the next reading leads
    /// instead. A stroke whose own best word is something else is left alone. When every
    /// reading was refused, the original order stays so the swipe still types a word.
    func applying(to result: DecodeResult, trace: String) -> DecodeResult {
        guard result.readings.count >= 2, let bucket = SwipeBucket.make(trace) else { return result }
        let refused = Set(entries.filter { $0.bucket == bucket && $0.remaining > 0 }.map(\.word))
        guard !refused.isEmpty,
              let index = result.readings.firstIndex(where: { !refused.contains($0.word.lowercased()) }),
              index != 0
        else { return result }
        var readings = result.readings
        let chosen = readings.remove(at: index)
        readings.insert(chosen, at: 0)
        return result.replacingReadings(readings)
    }
}
