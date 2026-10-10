import CoreGraphics
import Foundation

/// Left/right counts learned when two fingers are down at once, because that assignment is certain.
/// A seam key stays with the geometric side. The 60 ms gap rule is unchanged.
@MainActor
enum ThumbTerritory {
    private static var left: [UInt8: Int] = [:]
    private static var right: [UInt8: Int] = [:]

    static func observe(_ letter: String, onLeft: Bool) {
        guard let byte = letter.lowercased().utf8.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) else { return }
        if onLeft {
            left[byte, default: 0] += 1
        } else {
            right[byte, default: 0] += 1
        }
    }

    /// 0 is left, 1 is right. Nil when the key is a seam or still unlearned.
    static func side(of letter: String) -> Int? {
        guard let byte = letter.lowercased().utf8.first else { return nil }
        let l = left[byte] ?? 0
        let r = right[byte] ?? 0
        let total = l + r
        guard total >= 4 else { return nil }
        let share = Double(l) / Double(total)
        if share >= 0.75 { return 0 }
        if share <= 0.25 { return 1 }
        return nil
    }
}

/// The sideways distance that turns a tap into a stroke, learned from how far taps actually travel.
/// Default 16 pt. Clamped to 12–24. The offset log is not read on the touch path.
@MainActor
enum TapTravel {
    static let minimum: CGFloat = 12
    static let maximum: CGFloat = 24
    static let fallback: CGFloat = 16

    private static var samples: [CGFloat] = []

    static var threshold: CGFloat = fallback

    static func note(travel: CGFloat) {
        guard travel >= 0 else { return }
        samples.append(travel)
        if samples.count > 80 { samples.removeFirst(samples.count - 80) }
        guard samples.count >= 12 else { return }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.9).rounded()))
        threshold = min(maximum, max(minimum, sorted[index]))
    }
}
