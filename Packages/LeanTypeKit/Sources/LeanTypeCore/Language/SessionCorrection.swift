import CoreGraphics
import Foundation

/// How an alternative differs from the word that landed. Strip order may nudge these.
/// Beam weights do not.
public enum AlternativeKind: Hashable, Sendable {
    case neighbor
    case order
    case omission
    case boundary
    case completion
}

enum AlternativeClassifier {
    static func kind(of alternative: String, comparedWith word: String, aimed: String) -> AlternativeKind {
        let alt = alternative.lowercased().filter(\.isLetter)
        let shown = word.lowercased().filter(\.isLetter)
        let trace = aimed.lowercased().filter(\.isLetter)
        if alt.count > shown.count, alt.hasPrefix(shown) || shown.hasPrefix(trace) && alt.count > trace.count {
            return .completion
        }
        if alt.contains(" ") || shown.contains(" ") { return .boundary }
        if editDistance(alt, shown) == 1, abs(alt.count - shown.count) == 1 { return .omission }
        if sameLetters(alt, shown), alt != shown { return .order }
        return .neighbor
    }

    private static func sameLetters(_ left: String, _ right: String) -> Bool {
        left.sorted() == right.sorted()
    }

    private static func editDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var next = [i + 1]
            for (j, cb) in b.enumerated() {
                let cost = ca == cb ? 0 : 1
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + cost))
            }
            row = next
        }
        return row[b.count]
    }
}

/// Per-user pick counts. They scale strip order between 0.7 and 1.4 and never enter the beam.
@MainActor
final class AlternativeBias {
    private var counts: [AlternativeKind: Int] = [:]

    func note(_ kind: AlternativeKind) {
        counts[kind, default: 0] += 1
    }

    func multiplier(for kind: AlternativeKind) -> Double {
        let picked = counts[kind] ?? 0
        let total = max(1, counts.values.reduce(0, +))
        let share = Double(picked) / Double(total)
        return min(1.4, max(0.7, 0.7 + share * 0.7))
    }
}

/// The last few gestures, so a quick retry does not return the same wrong word.
@MainActor
final class RetryMemory {
    struct Decision {
        var aimed: String
        var path: [CGPoint]
        var chosen: String
        var at: TimeInterval
        var retries = 0
    }

    static let window: TimeInterval = 4
    static let pathDistance: CGFloat = 0.6
    /// Enough to beat `ReadingPolicy.exactLead` on this candidate only.
    static let penalty = 1.2

    private var recent: [Decision] = []

    func note(aimed: String, path: [CGPoint], chosen: String, at time: TimeInterval) {
        recent.append(Decision(aimed: aimed, path: path, chosen: chosen, at: time))
        if recent.count > 3 { recent.removeFirst(recent.count - 3) }
    }

    /// Penalizes a word the user just rejected. A second retry of the same word returns it
    /// so the caller can persist a refusal. The chosen replacement is boosted.
    func applying(
        to result: DecodeResult,
        aimed: String,
        path: [CGPoint],
        keyWidth: CGFloat,
        at time: TimeInterval
    ) -> (result: DecodeResult, refused: String?) {
        guard let match = recent.last(where: { time - $0.at <= Self.window && retry($0, aimed: aimed, path: path, keyWidth: keyWidth) })
        else { return (result, nil) }
        var readings = result.readings
        guard let index = readings.firstIndex(where: { $0.word.compare(match.chosen, options: .caseInsensitive) == .orderedSame })
        else { return (result, nil) }
        readings[index] = DecodeResult.Reading(word: readings[index].word, score: readings[index].score - Self.penalty)
        if let picked = recent.last(where: { $0.aimed == aimed && $0.chosen.compare(match.chosen, options: .caseInsensitive) != .orderedSame }) {
            if let boost = readings.firstIndex(where: { $0.word.compare(picked.chosen, options: .caseInsensitive) == .orderedSame }) {
                readings[boost] = DecodeResult.Reading(word: readings[boost].word, score: readings[boost].score + Self.penalty)
            }
        }
        readings.sort { $0.score > $1.score }
        let refused = match.retries >= 1 ? match.chosen : nil
        if let slot = recent.lastIndex(where: { $0.chosen == match.chosen && $0.aimed == match.aimed }) {
            recent[slot].retries += 1
        }
        return (DecodeResult(readings: readings, boundaryConfidence: result.boundaryConfidence), refused)
    }

    private func retry(_ decision: Decision, aimed: String, path: [CGPoint], keyWidth: CGFloat) -> Bool {
        if AlternativeClassifier.editDistancePublic(aimed.lowercased(), decision.aimed.lowercased()) <= 1 { return true }
        guard path.count >= 2, decision.path.count >= 2, keyWidth > 0 else { return false }
        let limit = Self.pathDistance * keyWidth
        let sample = path[path.count / 2]
        let other = decision.path[decision.path.count / 2]
        return hypot(sample.x - other.x, sample.y - other.y) <= limit
    }
}

extension AlternativeClassifier {
    static func editDistancePublic(_ left: String, _ right: String) -> Int {
        editDistance(left.filter(\.isLetter), right.filter(\.isLetter))
    }
}

/// Aimed keys to the word the user chose. Curves stay in `StrokeMemory`.
@MainActor
final class AimMemory {
    static let capacity = 300

    private struct Entry {
        var aimed: String
        var word: String
    }

    private var entries: [Entry] = []

    func note(aimed: String, word: String) {
        let aimed = aimed.lowercased().filter(\.isLetter)
        guard aimed.count >= 2, !word.isEmpty else { return }
        entries.removeAll { $0.aimed == aimed }
        entries.append(Entry(aimed: aimed, word: word))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func applying(to result: DecodeResult, aimed: String) -> DecodeResult {
        let aimed = aimed.lowercased().filter(\.isLetter)
        guard let match = entries.last(where: { close($0.aimed, aimed) }) else { return result }
        var readings = result.readings
        if let index = readings.firstIndex(where: { $0.word.compare(match.word, options: .caseInsensitive) == .orderedSame }) {
            let picked = readings.remove(at: index)
            readings.insert(picked, at: 0)
        } else if !readings.contains(where: { $0.word.compare(match.word, options: .caseInsensitive) == .orderedSame }) {
            let score = (readings.first?.score ?? 0) + 0.01
            readings.insert(DecodeResult.Reading(word: match.word, score: score), at: 0)
        }
        return DecodeResult(readings: readings, boundaryConfidence: result.boundaryConfidence)
    }

    private func close(_ stored: String, _ aimed: String) -> Bool {
        if stored == aimed { return true }
        return AlternativeClassifier.editDistancePublic(stored, aimed) <= 1
    }
}

/// Recent overrides. Two inside the window widen the unsure band and raise the lead
/// required to replace typed letters. Neither constant drops below its default.
@MainActor
final class TrustMeter {
    struct Sample {
        var at: TimeInterval
        var overridden: Bool
    }

    private var samples: [Sample] = []

    var unsureMargin: Double {
        strained ? 0.6 : DecodeResult.confidenceMargin
    }

    /// Never below `ReadingPolicy.exactLead`.
    var replacementLead: Double {
        strained ? 1.5 : ReadingPolicy.exactLead
    }

    func note(overridden: Bool, at time: TimeInterval) {
        samples.append(Sample(at: time, overridden: overridden))
        samples.removeAll { time - $0.at > 30 }
        if samples.count > 10 { samples.removeFirst(samples.count - 10) }
    }

    private var strained: Bool {
        guard let last = samples.last else { return false }
        let recent = samples.filter { last.at - $0.at <= 3 && $0.overridden }
        return recent.count >= 2
    }
}
