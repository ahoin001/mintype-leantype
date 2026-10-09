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
        droppingReturnTrip(collapsingSameRowReturns(arrivals.filter { !isApostrophe($0.letter) }))
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

    /// A run that goes out along one QWERTY row and comes back keeps its start, its far key,
    /// and its end. Keys retraced on the way home are the corridor, not extra letters.
    private static func collapsingSameRowReturns(_ arrivals: [KeyArrival]) -> [KeyArrival] {
        guard arrivals.count > 3 else { return arrivals }
        var result: [KeyArrival] = []
        result.reserveCapacity(arrivals.count)
        var index = 0
        while index < arrivals.count {
            let row = arrivals[index].center.y
            var end = index
            while end + 1 < arrivals.count, abs(arrivals[end + 1].center.y - row) < 8 {
                end += 1
            }
            let run = Array(arrivals[index...end])
            result.append(contentsOf: collapsedSameRowRun(run) ?? run)
            index = end + 1
        }
        return result
    }

    private static func collapsedSameRowRun(_ run: [KeyArrival]) -> [KeyArrival]? {
        guard run.count > 4 else { return nil }
        let origin = run[0].center.x
        var farIndex = 0
        var far: CGFloat = 0
        for (index, arrival) in run.enumerated() {
            let distance = abs(arrival.center.x - origin)
            if distance > far {
                far = distance
                farIndex = index
            }
        }
        guard farIndex > 0, farIndex < run.count - 1, far > 0 else { return nil }
        let end = abs(run[run.count - 1].center.x - origin)
        guard end < far * 0.7 else { return nil }
        let outbound = Set(run[..<farIndex].map(\.letter))
        let retraced = run[(farIndex + 1)..<run.index(before: run.endIndex)].filter { outbound.contains($0.letter) }
        guard retraced.count >= 2 else { return nil }
        return [run[0], run[farIndex], run[run.count - 1]]
    }

    private static func headingChange(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let first = atan2(b.y - a.y, b.x - a.x)
        let second = atan2(c.y - b.y, c.x - b.x)
        var delta = abs(second - first)
        if delta > .pi { delta = 2 * .pi - delta }
        return delta
    }
}
