import CoreGraphics

/// The letters one thumb meant, rather than every key it crossed while turning around.
enum StrokeLetters {
    /// A heading change at least this sharp, in radians, is the thumb turning around.
    /// About 126 degrees: a step back through the keys just left, not a corner on the way.
    static let reversalTurn: CGFloat = 2.2

    static func isApostrophe(_ letter: String) -> Bool {
        letter == "'"
    }

    /// The thumb lifted on the apostrophe, so the contraction spelling is the one it asked for.
    static func endsOnApostrophe(_ arrivals: [KeyArrival]) -> Bool {
        arrivals.last.map { isApostrophe($0.letter) } ?? false
    }

    /// Arrivals with the apostrophe removed and a return trip collapsed to its turnaround.
    static func aimedArrivals(_ arrivals: [KeyArrival]) -> [KeyArrival] {
        droppingReturnTrip(arrivals.filter { !isApostrophe($0.letter) })
    }

    /// Drops the keys a thumb only crossed while walking out and back through the same letters.
    /// The first letter, the place it turned around, and the last letter stay.
    static func droppingReturnTrip(_ arrivals: [KeyArrival]) -> [KeyArrival] {
        guard arrivals.count > 3 else { return arrivals }
        var drop = Set<Int>()
        for index in 1..<(arrivals.count - 1) {
            let turn = headingChange(
                arrivals[index - 1].center,
                arrivals[index].center,
                arrivals[index + 1].center
            )
            guard turn >= reversalTurn else { continue }
            var back = index - 1
            var forward = index + 1
            while back > 0, forward < arrivals.count - 1,
                  arrivals[back].letter == arrivals[forward].letter {
                drop.insert(back)
                drop.insert(forward)
                back -= 1
                forward += 1
            }
        }
        return arrivals.enumerated().compactMap { drop.contains($0.offset) ? nil : $0.element }
    }

    private static func headingChange(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let first = atan2(b.y - a.y, b.x - a.x)
        let second = atan2(c.y - b.y, c.x - b.x)
        var delta = abs(second - first)
        if delta > .pi { delta = 2 * .pi - delta }
        return delta
    }
}
